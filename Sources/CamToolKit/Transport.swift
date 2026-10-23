import Foundation

/// How JSON-RPC requests reach the device.
public enum Transport: Sendable, Equatable {
    /// JSON-RPC over HTTP (`/RPC2_Login`, `/RPC2`), as used by the device's web interface.
    /// Works on every firmware tested.
    case http(port: UInt16 = 80)
    /// DHIP-framed JSON-RPC over TCP. Experimental: the tested firmwares (2.800 to 3.140)
    /// do not answer this format on port 37777.
    case dhip(port: UInt16 = 37777)

    public var port: UInt16 {
        switch self {
        case .http(let port), .dhip(let port): port
        }
    }
}

protocol RPCChannel: AnyObject {
    /// Sends a full request and returns the reply carrying the same `id`.
    func send(_ payload: [String: JSONValue]) throws -> [String: JSONValue]
}

// MARK: - HTTP

final class HTTPChannel: RPCChannel {
    let base: URL
    let session: URLSession
    /// Endpoint used for every request instead of `/RPC2_Login` / `/RPC2` (e.g. `/OutsideCmd`).
    let fixedPath: String?

    init(host: String, port: UInt16, timeout: Double, fixedPath: String? = nil) throws {
        // A host typed by the user may not form a valid URL (spaces, etc.).
        guard let base = URL(string: "http://\(host):\(port)"), base.host() != nil else { throw SocketError.resolve(host) }
        self.base = base
        self.fixedPath = fixedPath
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        let path = fixedPath ?? (payload["method"] == "global.login" ? "RPC2_Login" : "RPC2")
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data, response: URLResponse
        do {
            (data, response) = try session.syncData(for: request)
        } catch let error as URLError {
            throw Self.simplified(error)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw HTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard case .object(let reply) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DHIP.Error.invalidJSON(tr("the reply is not a JSON object", fr: "la réponse n'est pas un objet JSON"))
        }
        return reply
    }

    /// Foundation's URLError prints poorly (a full dictionary dump): map it to the same
    /// errors as the DHIP transport.
    static func simplified(_ error: URLError) -> Error {
        switch error.code {
        case .timedOut: SocketError.timeout
        case .cannotConnectToHost: SocketError.posix(tr("connect", fr: "connexion"), ECONNREFUSED)
        case .cannotFindHost, .dnsLookupFailed: SocketError.resolve(error.failingURL?.host() ?? "?")
        case .networkConnectionLost: SocketError.closed
        default: SocketError.other(error.localizedDescription)
        }
    }
}

public struct HTTPError: Error, CustomStringConvertible {
    public var status: Int
    public var description: String { tr("HTTP status \(status)", fr: "réponse HTTP \(status)") }
}

extension URLSession {
    /// Blocking call: the Client is synchronous (see its documentation).
    func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        final class Box: @unchecked Sendable { var result: Result<(Data, URLResponse), Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        dataTask(with: request) { data, response, error in
            if let data, let response { box.result = .success((data, response)) }
            else { box.result = .failure(error ?? URLError(.badServerResponse)) }
            done.signal()
        }.resume()
        done.wait()
        return try box.result!.get()
    }
}

// MARK: - DHIP

final class DHIPChannel: RPCChannel {
    let socket: Socket

    init(host: String, port: UInt16, timeout: Double) throws {
        socket = try Socket.connectTCP(host: host, port: port, timeout: timeout)
    }

    func send(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        let id = payload["id"]?.intValue ?? 0
        let session = payload["session"]?.intValue.flatMap { UInt32(exactly: $0) } ?? 0
        try socket.sendAll(DHIP.encode(payload, sessionID: session, requestID: UInt32(truncatingIfNeeded: id)))
        while true {
            let header = try socket.receive(exactly: DHIP.headerLength)
            let length = try DHIP.parseHeader(header).length
            let packet = try DHIP.decode(header + socket.receive(exactly: length))
            // Skip unsolicited notifications (events, etc.) interleaved with replies.
            if packet.payload["id"]?.intValue == id { return packet.payload }
        }
    }
}
