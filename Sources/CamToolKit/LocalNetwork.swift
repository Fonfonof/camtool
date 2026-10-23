import Darwin
import Foundation

/// IPv4 addresses of this Mac, to tell whether a device is directly reachable.
public enum LocalNetwork {
    public struct Interface: Sendable, Equatable {
        public var name: String
        public var address: String
        public var netmask: String
    }

    public static func interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask
            else { continue }
            result.append(Interface(name: String(cString: entry.pointee.ifa_name),
                                    address: string(addr), netmask: string(mask)))
        }
        return result
    }

    /// True when `ip` sits in the subnet of one of this Mac's interfaces.
    public static func isOnLink(_ ip: String, interfaces: [Interface] = interfaces()) -> Bool {
        guard let target = IPv4(ip) else { return false }
        return interfaces.contains { iface in
            guard let address = IPv4(iface.address), let mask = IPv4(iface.netmask) else { return false }
            return target.isInSubnet(of: address, mask: mask)
        }
    }

    /// A free-looking address in the device's subnet for a temporary alias on this Mac:
    /// the highest host addresses first, skipping the device, its gateway and `taken`.
    public static func aliasAddress(for device: Device, taken: [String] = []) -> (address: String, netmask: String)? {
        guard let ip = IPv4(device.ip) else { return nil }
        let mask = IPv4(device.netmask).flatMap { $0.isNetmask && $0.value != 0 ? $0 : nil } ?? IPv4("255.255.255.0")!
        let network = ip.value & mask.value
        let broadcast = network | ~mask.value
        let excluded = Set(([device.ip, device.gateway] + taken).compactMap { IPv4($0)?.value })
        guard broadcast > network + 1 else { return nil }
        var candidate = broadcast - 1
        while candidate > network {
            if !excluded.contains(candidate) { return (IPv4(value: candidate).description, mask.description) }
            candidate -= 1
        }
        return nil
    }

    private static func string(_ sockaddr: UnsafeMutablePointer<sockaddr>) -> String {
        sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4(value: UInt32(bigEndian: $0.pointee.sin_addr.s_addr)).description }
    }
}

extension IPv4: CustomStringConvertible {
    public init(value: UInt32) {
        self.value = value
    }

    public var description: String {
        [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xff) }.joined(separator: ".")
    }
}
