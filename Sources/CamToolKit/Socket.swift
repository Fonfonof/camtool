import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case posix(String, Int32)
    case resolve(String)
    case timeout
    case closed
    case other(String)

    public var description: String {
        switch self {
        case .posix(let op, let code): tr("\(op): ", fr: "\(op) : ") + Self.reason(code)
        case .resolve(let host): tr("cannot resolve address: \(host)", fr: "adresse introuvable : \(host)")
        case .timeout: tr("timed out", fr: "délai dépassé")
        case .closed: tr("connection closed by the device", fr: "connexion fermée par l'appareil")
        case .other(let message): message
        }
    }

    static func last(_ op: String) -> SocketError { .posix(op, errno) }

    /// System message, translated to French for common cases (strerror is always in English).
    static func reason(_ code: Int32) -> String {
        let french: [Int32: String] = [
            ECONNREFUSED: "connexion refusée",
            ECONNRESET: "connexion réinitialisée par l'appareil",
            EHOSTUNREACH: "appareil injoignable",
            ENETUNREACH: "réseau injoignable",
            EADDRINUSE: "port déjà utilisé",
            EACCES: "permission refusée",
        ]
        return tr(String(cString: strerror(code)), fr: french[code] ?? String(cString: strerror(code)))
    }
}

/// Thin wrapper around a BSD socket descriptor (blocking, with timeouts).
final class Socket {
    let fd: Int32

    init(type: Int32) throws {
        fd = Darwin.socket(AF_INET, type, 0)
        guard fd >= 0 else { throw SocketError.last("socket") }
        try setOption(SOL_SOCKET, SO_NOSIGPIPE, Int32(1))
    }

    /// Takes ownership of an existing descriptor (e.g. from accept()).
    init(fd: Int32) {
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    func setOption<T: BitwiseCopyable>(_ level: Int32, _ name: Int32, _ value: T) throws {
        var value = value
        guard setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<T>.size)) == 0 else {
            throw SocketError.last("setsockopt")
        }
    }

    func setTimeout(_ seconds: Double) throws {
        let whole = max(0, seconds.rounded(.down))
        let tv = timeval(tv_sec: Int(whole), tv_usec: Int32((max(0, seconds) - whole) * 1_000_000))
        try setOption(SOL_SOCKET, SO_RCVTIMEO, tv)
        try setOption(SOL_SOCKET, SO_SNDTIMEO, tv)
    }

    static func ipv4(_ host: String, port: UInt16) throws -> sockaddr_in {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result, let sa = info.pointee.ai_addr else {
            throw SocketError.resolve(host)
        }
        defer { freeaddrinfo(result) }
        var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        addr.sin_port = port.bigEndian
        return addr
    }

    /// TCP connection with a timeout (non-blocking connect + poll).
    static func connectTCP(host: String, port: UInt16, timeout: Double) throws -> Socket {
        var addr = try ipv4(host, port: port)
        let sock = try Socket(type: SOCK_STREAM)
        let flags = fcntl(sock.fd, F_GETFL)
        _ = fcntl(sock.fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { throw SocketError.last(tr("connect", fr: "connexion")) }
            var pfd = pollfd(fd: sock.fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            if ready == 0 { throw SocketError.timeout }
            if ready < 0 { throw SocketError.last("poll") }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock.fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { throw SocketError.posix(tr("connect", fr: "connexion"), err) }
        }
        _ = fcntl(sock.fd, F_SETFL, flags)
        try sock.setTimeout(timeout)
        return sock
    }

    func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.send(fd, buf.baseAddress! + sent, buf.count - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? SocketError.timeout : SocketError.last(tr("send", fr: "envoi"))
                }
                sent += n
            }
        }
    }

    func receive(exactly count: Int) throws -> Data {
        var data = Data(count: count)
        var got = 0
        try data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            while got < count {
                let n = Darwin.recv(fd, buf.baseAddress! + got, count - got, 0)
                if n == 0 { throw SocketError.closed }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? SocketError.timeout : SocketError.last(tr("receive", fr: "réception"))
                }
                got += n
            }
        }
        return data
    }
}
