import CryptoKit
import Foundation

public struct RPCError: Error, CustomStringConvertible {
    public var method: String
    public var code: Int?
    public var message: String
    /// True when the failure comes from authentication (credentials refused, missing challenge…).
    public var isAuthentication: Bool

    init(method: String, error: JSONValue?, isAuthentication: Bool = false) {
        self.method = method
        code = error?["code"]?.intValue
        message = error?["message"]?.stringValue ?? ""
        self.isAuthentication = isAuthentication
    }

    /// From a full reply: some endpoints (e.g. `/OutsideCmd`) report `errCode` instead of `error`.
    init(method: String, reply: [String: JSONValue]) {
        self.init(method: method, error: reply["error"])
        code = code ?? reply["errCode"]?.intValue
    }

    init(method: String, message: String, isAuthentication: Bool) {
        self.method = method
        self.message = message
        self.isAuthentication = isAuthentication
    }

    public var description: String {
        [tr("\(method):", fr: "\(method) :"), code.map { tr("error \($0)", fr: "erreur \($0)") }, message.isEmpty ? nil : message]
            .compactMap { $0 }.joined(separator: " ")
    }
}

/// Authenticated JSON-RPC client (HTTP port 80 by default, see `Transport`).
///
/// Challenge-response login: the device sends a "realm" and a "random", and the
/// password is never sent in clear text. One attempt per login() call: CamTool never
/// retries on its own (no brute force, and no risk of triggering an account lockout).
///
/// Calls are blocking: from a GUI, make them off the main thread.
public final class Client {
    static let clientType = "Web3.0"
    static let noSession: JSONValue = .int(0)

    public let host: String
    public let transport: Transport
    public let timeout: Double
    /// Session id assigned by the device (integer over DHIP, string over HTTP).
    public private(set) var session: JSONValue = Client.noSession
    public private(set) var keepAliveInterval: Int?
    private var nextID = 0
    private var channel: RPCChannel?

    public init(host: String, transport: Transport = .http(), timeout: Double = 5) {
        self.host = host
        self.transport = transport
        self.timeout = timeout
    }

    deinit { close() }

    public var isLoggedIn: Bool { session != Self.noSession }

    public func connect() throws {
        switch transport {
        case .http(let port): channel = try HTTPChannel(host: host, port: port, timeout: timeout)
        case .dhip(let port): channel = try DHIPChannel(host: host, port: port, timeout: timeout)
        }
    }

    public func close() {
        guard channel != nil else { return }
        if isLoggedIn {
            _ = try? call("global.logout")
            session = Self.noSession
        }
        channel = nil
    }

    /// Sends a request and returns the raw reply (without throwing on RPC errors).
    public func request(_ method: String, params: JSONValue = nil) throws -> [String: JSONValue] {
        if channel == nil { try connect() }
        guard let channel else { throw SocketError.closed }
        nextID += 1
        return try channel.send(["method": .string(method), "params": params, "id": .int(nextID), "session": session])
    }

    /// RPC call; returns the reply's `params`, or `result` when there are none.
    @discardableResult
    public func call(_ method: String, params: JSONValue = nil) throws -> JSONValue {
        let reply = try request(method, params: params)
        if reply["result"] == .bool(false) || reply["error"] != nil {
            throw RPCError(method: method, error: reply["error"])
        }
        return reply["params"] ?? reply["result"] ?? .null
    }

    public func login(user: String, password: String) throws {
        let base: [String: JSONValue] = [
            "userName": .string(user), "password": "", "clientType": .string(Self.clientType), "loginType": "Direct",
        ]
        let challenge = try request("global.login", params: .object(base))
        session = challenge["session"] ?? Self.noSession
        if challenge["result"] == .bool(true) { return } // account without a password (should not exist)
        guard let realm = challenge["params"]?["realm"]?.stringValue,
              let random = challenge["params"]?["random"]?.stringValue
        else {
            session = Self.noSession
            throw RPCError(method: "global.login", error: challenge["error"], isAuthentication: true)
        }

        let encryption = challenge["params"]?["encryption"]?.stringValue ?? "Default"
        guard encryption == "Default" else {
            session = Self.noSession
            throw RPCError(method: "global.login", message: tr("unsupported encryption method: \(encryption)", fr: "méthode de chiffrement non prise en charge : \(encryption)"), isAuthentication: true)
        }

        var params = base
        params["password"] = .string(Self.loginHash(user: user, password: password, realm: realm, random: random))
        params["authorityType"] = .string(encryption)
        params["passwordType"] = "Default"
        let reply = try request("global.login", params: .object(params))
        guard reply["result"] == .bool(true) else {
            session = Self.noSession
            throw RPCError(method: "global.login", error: reply["error"], isAuthentication: true)
        }
        if let newSession = reply["session"], newSession != Self.noSession { session = newSession }
        keepAliveInterval = reply["params"]?["keepAliveInterval"]?.intValue
    }

    public func keepAlive() throws {
        try call("global.keepAlive", params: ["timeout": .int(keepAliveInterval ?? 60), "active": true])
    }

    // Read-only shortcuts

    public func systemInfo() throws -> [String: JSONValue] {
        var info = try call("magicBox.getSystemInfo").objectValue ?? [:]
        if let version = try call("magicBox.getSoftwareVersion")["version"]?.objectValue {
            info.merge(version) { _, new in new }
        }
        return info
    }

    public func config(_ name: String) throws -> JSONValue {
        try call("configManager.getConfig", params: ["name": .string(name)])["table"] ?? .null
    }

    /// Challenge response for encryption=Default.
    public static func loginHash(user: String, password: String, realm: String, random: String) -> String {
        md5("\(user):\(random):\(md5("\(user):\(realm):\(password)"))")
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }
}
