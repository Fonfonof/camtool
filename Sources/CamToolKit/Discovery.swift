import Darwin
import Foundation

/// Device discovery on the local network (DHDiscover.search).
///
/// Sends a DHIP request over multicast and broadcast, then listens for the
/// "client.notifyDevInfo" replies that devices send back on their own.
/// No authentication is required or bypassed: this is the information the
/// device publishes itself so that configuration tools can find it.
///
/// Only use on a network you administer or are authorized to work on.
public enum Discovery {
    public static let multicastGroup = "239.255.255.251"
    public static let port: UInt16 = 37810
    static let searchMethod = "DHDiscover.search"
    static let notifyMethod = "client.notifyDevInfo"

    public static func searchRequest() -> Data {
        DHIP.encode(["method": .string(searchMethod), "params": ["mac": "", "uni": 1]])
    }

    /// Returns the device described by a frame, or nil if the frame is not relevant.
    public static func parseResponse(_ data: Data, source: String) -> Device? {
        guard let packet = try? DHIP.decode(data),
              // Multicast also echoes back our own requests and those of other tools.
              packet.payload["method"]?.stringValue == notifyMethod,
              let info = packet.payload["params"]?["deviceInfo"]?.objectValue
        else { return nil }
        // On the firmwares observed, the MAC sits at the root of the frame, outside deviceInfo.
        return Device(info: info, source: source, mac: packet.payload["mac"]?.stringValue)
    }

    /// Sends the search request and calls `onDevice` for each device (deduplicated)
    /// as replies arrive. Blocks for `timeout` seconds.
    public static func discover(timeout: Double = 3, interface: String = "0.0.0.0", repeatCount: Int = 2,
                                onDevice: (Device) -> Void) throws {
        let sock = try openSocket(interface: interface)
        let request = searchRequest()
        var seen = Set<String>()
        let start = Date()
        var sends = 0
        var nextSend = 0.0
        var buffer = [UInt8](repeating: 0, count: 65535)

        while case let now = Date().timeIntervalSince(start), now < timeout {
            if sends < repeatCount, now >= nextSend {
                // UDP is unreliable: repeat the request so no device is missed.
                try send(request, on: sock, to: multicastGroup)
                try? send(request, on: sock, to: "255.255.255.255")
                sends += 1
                nextSend = now + timeout / Double(repeatCount + 1)
            }
            let wait = (sends < repeatCount ? min(nextSend, timeout) : timeout) - now
            var pfd = pollfd(fd: sock.fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(max(0.05, wait) * 1000)) > 0 else { continue }

            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(sock.fd, &buffer, buffer.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { continue }
            if let device = parseResponse(Data(buffer[0..<n]), source: ipString(from.sin_addr)),
               seen.insert(device.key).inserted {
                onDevice(device)
            }
        }
    }

    /// Async variant, for the GUI.
    public static func devices(timeout: Double = 3, interface: String = "0.0.0.0") -> AsyncThrowingStream<Device, Error> {
        AsyncThrowingStream { continuation in
            Thread {
                do {
                    try discover(timeout: timeout, interface: interface) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }.start()
        }
    }

    static func openSocket(interface: String) throws -> Socket {
        let sock = try Socket(type: SOCK_DGRAM)
        try sock.setOption(SOL_SOCKET, SO_REUSEADDR, Int32(1))
        // Lets us coexist with another tool already listening on 37810.
        try sock.setOption(SOL_SOCKET, SO_REUSEPORT, Int32(1))
        try sock.setOption(SOL_SOCKET, SO_BROADCAST, Int32(1))

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = port.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { throw SocketError.last(tr("bind to port \(port)", fr: "bind sur le port \(port)")) }

        var iface = in_addr()
        guard inet_pton(AF_INET, interface, &iface) == 1 else { throw SocketError.resolve(interface) }
        var group = in_addr()
        inet_pton(AF_INET, multicastGroup, &group)
        try sock.setOption(IPPROTO_IP, IP_MULTICAST_IF, iface)
        try sock.setOption(IPPROTO_IP, IP_MULTICAST_TTL, UInt8(1))
        try sock.setOption(IPPROTO_IP, IP_ADD_MEMBERSHIP, ip_mreq(imr_multiaddr: group, imr_interface: iface))
        return sock
    }

    static func ipString(_ addr: in_addr) -> String {
        var addr = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func send(_ data: Data, on sock: Socket, to host: String) throws {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let n = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock.fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard n >= 0 else { throw SocketError.last(tr("send to \(host)", fr: "envoi vers \(host)")) }
    }
}

public struct Device: Sendable, Hashable, Codable, Identifiable {
    public var ip: String
    public var mac: String
    public var model: String
    public var serial: String
    public var version: String
    public var vendor: String
    public var name: String
    public var httpPort: Int?
    public var tcpPort: Int?
    public var dhcp: Bool?
    public var netmask: String
    public var gateway: String
    public var source: String
    public var raw: [String: JSONValue]

    public var id: String { key }
    public var key: String { (mac.isEmpty ? (serial.isEmpty ? ip : serial) : mac).lowercased() }

    public init(info: [String: JSONValue], source: String, mac: String? = nil) {
        let ipv4 = info["IPv4Address"]
        ip = ipv4?["IPAddress"]?.stringValue ?? source
        self.mac = info["Mac"]?.stringValue ?? mac ?? ""
        model = info["DeviceType"]?.stringValue ?? ""
        serial = info["SerialNo"]?.stringValue ?? ""
        version = info["Version"]?.stringValue ?? ""
        vendor = info["Vendor"]?.stringValue ?? ""
        name = info["MachineName"]?.stringValue ?? ""
        httpPort = info["HttpPort"]?.intValue
        tcpPort = info["Port"]?.intValue
        dhcp = ipv4?["DhcpEnable"]?.boolValue
        netmask = ipv4?["SubnetMask"]?.stringValue ?? ""
        gateway = ipv4?["DefaultGateway"]?.stringValue ?? ""
        self.source = source
        raw = info
    }
}
