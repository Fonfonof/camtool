import CommonCrypto
import Darwin
import Foundation
import Security
import Testing
@testable import CamToolKit

private let realm = "Login to TEST", random = "123456789"

/// Simulated device, over HTTP or DHIP: global.login challenge-response, then a few methods.
private final class FakeDevice: @unchecked Sendable {
    let password: String
    let http: Bool
    let listener: Socket
    let port: UInt16
    /// Like real devices: integer session over DHIP, hex string over HTTP.
    let session: JSONValue
    /// Factory-new device simulation: RSA key pair for DevInit, and the account it received.
    let setupKey: SecKey?
    private var _initialized = false
    private var _receivedAccount: JSONValue?
    var receivedAccount: JSONValue? { lock.withLock { _receivedAccount } }
    private let lock = NSLock()
    private var _calls: [(path: String, payload: [String: JSONValue])] = []

    var calls: [[String: JSONValue]] { lock.withLock { _calls.map(\.payload) } }
    var paths: [String] { lock.withLock { _calls.map(\.path) } }
    var transport: Transport { http ? .http(port: port) : .dhip(port: port) }

    init(password: String, http: Bool, uninitialized: Bool = false) throws {
        self.password = password
        self.http = http
        setupKey = uninitialized ? try TestRSA.makeKey() : nil
        _initialized = !uninitialized
        session = http ? "0123456789abcdef0123456789abcdef" : 4242
        let sock = try Socket(type: SOCK_STREAM)
        try sock.setOption(SOL_SOCKET, SO_REUSEADDR, Int32(1))
        var addr = try Socket.ipv4("127.0.0.1", port: 0)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(sock.fd, 8)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock.fd, $0, &len) } }
        listener = sock
        port = UInt16(bigEndian: bound.sin_port)
        Thread { [self] in http ? serveHTTP() : serveDHIP() }.start()
    }

    func stop() { shutdown(listener.fd, SHUT_RDWR) }

    /// Logic shared by both transports: returns the frames to send back.
    private func handle(_ request: [String: JSONValue], path: String) -> [[String: JSONValue]] {
        lock.withLock { _calls.append((path, request)) }
        let id = request["id"] ?? nil
        let params = request["params"] ?? nil
        var reply: [String: JSONValue] = ["id": id, "session": session, "result": true]
        switch request["method"]?.stringValue {
        case "DevInit.getStatus":
            let initialized = lock.withLock { _initialized }
            return [["id": id, "result": true, "params": ["Init": initialized ? 2 : 1, "Find": "BC"]]]
        case "Security.getEncryptInfo":
            guard let setupKey else { return [["id": id, "result": false, "errCode": 285278253]] }
            return [["id": id, "result": true, "params": [
                "asymmetric": "RSA", "cipher": ["AES", "RPAC"], "pub": .string(TestRSA.publicKeyString(setupKey)),
            ]]]
        case "DevInit.account":
            guard let setupKey, let account = TestRSA.open(params, privateKey: setupKey) else {
                return [["id": id, "result": false, "errCode": 268632080]]
            }
            lock.withLock { _receivedAccount = account; _initialized = true }
            return [["id": id, "result": true]]
        case "global.login" where params["password"] == "":
            reply = ["id": id, "session": session, "result": false,
                     "error": ["code": 268632079, "message": "Component error: login challenge!"],
                     "params": ["encryption": "Default", "realm": .string(realm), "random": .string(random)]]
        case "global.login":
            let expected = Client.loginHash(user: params["userName"]?.stringValue ?? "", password: password, realm: realm, random: random)
            let ok = params["password"]?.stringValue == expected
            reply = ["id": id, "session": session, "result": .bool(ok), "params": ["keepAliveInterval": 60]]
            if !ok { reply["error"] = ["code": 268632085, "message": "Component error: password not valid!"] }
        case "magicBox.getSystemInfo":
            reply["params"] = ["deviceType": "IPC-TEST", "serialNumber": "SN1"]
            // Interleaved unsolicited notification that the client must skip (DHIP only).
            if !http { return [["method": "client.notifyEventStream", "params": [:]], reply] }
        case "magicBox.getSoftwareVersion":
            reply["params"] = ["version": ["Version": "2.800"]]
        case "configManager.getConfig" where params["name"] == "Network":
            reply["params"] = ["table": ["DefaultInterface": "eth0", "eth0": ["PhysicalAddress": "aa:bb:cc:dd:ee:ff"]]]
        case "configManager.getConfig":
            reply["params"] = ["table": [["Name": params["name"] ?? nil]]]
        default:
            break
        }
        return [reply]
    }

    private func serveDHIP() {
        let conn = Socket(fd: accept(listener.fd, nil, nil))
        while let header = try? conn.receive(exactly: DHIP.headerLength),
              let length = try? DHIP.parseHeader(header).length,
              let body = try? conn.receive(exactly: length),
              let request = try? DHIP.decode(header + body).payload
        {
            for payload in handle(request, path: "") {
                let frame = DHIP.encode(payload, sessionID: UInt32(payload["session"]?.intValue ?? 0), requestID: UInt32(payload["id"]?.intValue ?? 0))
                // Deliberately split into two sends to test frame reassembly.
                try? conn.sendAll(frame.prefix(10))
                try? conn.sendAll(frame.dropFirst(10))
            }
        }
    }

    private func serveHTTP() {
        while case let fd = accept(listener.fd, nil, nil), fd >= 0 {
            let conn = Socket(fd: fd)
            var head = Data()
            while !head.ends(with: Data("\r\n\r\n".utf8)), let byte = try? conn.receive(exactly: 1) { head += byte }
            let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let length = lines.lazy.compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            }.first ?? 0
            guard let body = try? conn.receive(exactly: length),
                  case .object(let request)? = try? JSONDecoder().decode(JSONValue.self, from: body),
                  let reply = handle(request, path: path).last,
                  let json = try? JSONEncoder().encode(reply)
            else { continue }
            try? conn.sendAll(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8) + json)
        }
    }
}

@Suite struct ClientTests {
    @Test func loginHashKnownValue() {
        // md5("admin:Login to TEST:admin") then md5("admin:123:<hash>"), uppercase
        #expect(Client.loginHash(user: "admin", password: "admin", realm: "Login to TEST", random: "123") == "DDDD141D33CB33E5B443750E6A206631")
    }

    @Test(arguments: [true, false])
    func loginAndCalls(http: Bool) throws {
        let device = try FakeDevice(password: "secret", http: http)
        defer { device.stop() }
        let client = Client(host: "127.0.0.1", transport: device.transport, timeout: 2)
        try client.login(user: "admin", password: "secret")
        #expect(client.session == device.session)
        #expect(client.keepAliveInterval == 60)
        #expect(try client.systemInfo() == ["deviceType": "IPC-TEST", "serialNumber": "SN1", "Version": "2.800"])
        #expect(try client.config("NTP") == [["Name": "NTP"]])
        #expect(throws: Never.self) { try client.verifyMAC("AA:BB:CC:DD:EE:FF") }
        #expect(throws: RPCError.self) { try client.verifyMAC("11:22:33:44:55:66") }
        try client.setConfig("Network", table: ["Hostname": "CAM"])
        client.close()

        let calls = device.calls
        #expect(!String(describing: calls).contains("secret")) // never a clear-text password
        #expect(calls.last?["method"] == "global.logout")
        let set = try #require(calls.first { $0["method"] == "configManager.setConfig" })
        #expect(set["params"] == ["name": "Network", "table": ["Hostname": "CAM"]])
        #expect(calls.dropFirst().allSatisfy { $0["session"] == device.session })
        if http {
            #expect(device.paths == ["/RPC2_Login", "/RPC2_Login"] + Array(repeating: "/RPC2", count: calls.count - 2))
        }
    }

    @Test(arguments: [true, false])
    func wrongPasswordSingleAttempt(http: Bool) throws {
        let device = try FakeDevice(password: "secret", http: http)
        defer { device.stop() }
        let client = Client(host: "127.0.0.1", transport: device.transport, timeout: 2)
        let error = try #require(throws: RPCError.self) { try client.login(user: "admin", password: "wrong") }
        #expect(error.isAuthentication)
        #expect(error.code == 268632085)
        #expect(!client.isLoggedIn)
        client.close()
        #expect(device.calls.map { $0["method"] } == ["global.login", "global.login"])
    }
}

private extension Data {
    func ends(with suffix: Data) -> Bool { count >= suffix.count && self.suffix(suffix.count) == suffix }
}

/// Test-side counterpart of DeviceSetup's encryption, playing the device.
enum TestRSA {
    static func makeKey() throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        return key
    }

    /// "N:<hex>,E:<hex>", as devices publish it.
    static func publicKeyString(_ privateKey: SecKey) -> String {
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        // RSAPublicKey ::= SEQUENCE { INTEGER n, INTEGER e }
        var bytes = [UInt8](der)[...]
        func readHeader() -> Int {
            bytes = bytes.dropFirst()
            var length = Int(bytes.removeFirst())
            if length & 0x80 != 0 {
                let count = length & 0x7f
                length = bytes.prefix(count).reduce(0) { $0 << 8 | Int($1) }
                bytes = bytes.dropFirst(count)
            }
            return length
        }
        _ = readHeader()
        let nLength = readHeader()
        let n = bytes.prefix(nLength)
        bytes = bytes.dropFirst(nLength)
        let eLength = readHeader()
        let e = bytes.prefix(eLength)
        let hex = { (d: ArraySlice<UInt8>) in d.drop { $0 == 0 }.map { String(format: "%02X", $0) }.joined() }
        return "N:\(hex(n)),E:\(hex(e))"
    }

    /// Decrypts `{cipher, salt, content}` the way a device would.
    static func open(_ params: JSONValue, privateKey: SecKey) -> JSONValue? {
        guard params["cipher"] == "AES-128",
              let salt = params["salt"]?.stringValue.flatMap(Data.init(hex:)),
              let content = params["content"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
              let key = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, salt as CFData, nil) as Data?
        else { return nil }
        var plain = Data(count: content.count)
        var written = 0
        let status = plain.withUnsafeMutableBytes { out in
            content.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil, inp.baseAddress, content.count, out.baseAddress, out.count, &written)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        while plain.last == 0 { plain.removeLast() }
        return try? JSONDecoder().decode(JSONValue.self, from: plain)
    }
}

@Suite struct DeviceSetupTests {
    @Test func statusFromDiscoveryInitValue() {
        #expect(InitStatus(initValue: 3738) == .initialized) // real value seen on an initialized camera
        #expect(InitStatus(initValue: 2) == .initialized)
        #expect(InitStatus(initValue: 1) == .uninitialized)
        #expect(InitStatus(initValue: 0) == .unknown)
        #expect(InitStatus(initValue: nil) == .unknown)
    }

    @Test func initializesFactoryNewDevice() throws {
        let device = try FakeDevice(password: "unused", http: true, uninitialized: true)
        defer { device.stop() }
        #expect(try DeviceSetup.status(host: "127.0.0.1", port: device.port, timeout: 2).initStatus == .uninitialized)
        try DeviceSetup.initialize(host: "127.0.0.1", port: device.port, timeout: 2, password: "Secret#2026", email: "me@example.com")
        #expect(device.receivedAccount == ["name": "admin", "pwd": "Secret#2026", "CellPhone": "", "Mail": "me@example.com"])
        #expect(device.paths.allSatisfy { $0 == "/OutsideCmd" })
        // The clear-text password never travels.
        #expect(!String(describing: device.calls).contains("Secret#2026"))
    }

    @Test func refusesInitializedDevice() throws {
        let device = try FakeDevice(password: "unused", http: true)
        defer { device.stop() }
        #expect(throws: RPCError.self) {
            try DeviceSetup.initialize(host: "127.0.0.1", port: device.port, timeout: 2, password: "Secret#2026")
        }
        #expect(!device.calls.contains { $0["method"] == "DevInit.account" })
    }

    @Test func passwordRules() {
        #expect(DeviceSetup.passwordProblems("Secret#2026").isEmpty)
        #expect(DeviceSetup.passwordProblems("abcdefgh1").isEmpty)
        #expect(!DeviceSetup.passwordProblems("short1").isEmpty)
        #expect(!DeviceSetup.passwordProblems("onlyletters").isEmpty)
        #expect(!DeviceSetup.passwordProblems("Pass;word1").isEmpty)
        #expect(!DeviceSetup.passwordProblems(String(repeating: "a1", count: 17)).isEmpty)
    }

    @Test func encryptsWithDeviceStylePublicKey() throws {
        // Same "N:<hex>,E:<hex>" format as Security.getEncryptInfo, from a freshly generated 2048-bit key.
        let pub = TestRSA.publicKeyString(try TestRSA.makeKey())
        #expect(pub.hasPrefix("N:") && pub.hasSuffix(",E:010001"))
        #expect(try DeviceSetup.rsaPKCS1Encrypt(Data("1234567890123456".utf8), publicKey: pub).count == 256)
    }

    @Test func rejectsInvalidHost() {
        #expect(throws: SocketError.self) { try Client(host: "bad host").connect() }
    }

    @Test func derIntegerEncoding() {
        #expect(DER.integer(Data([0x01, 0x00, 0x01])) == Data([0x02, 0x03, 0x01, 0x00, 0x01]))
        #expect(DER.integer(Data([0x00, 0x80])) == Data([0x02, 0x02, 0x00, 0x80]))
        #expect(DER.length(300) == Data([0x82, 0x01, 0x2C]))
    }
}

@Suite struct BatchReaddressTests {
    @Test func consecutiveAddressesSkipTakenOnes() throws {
        let plan = try BatchReaddress.addresses(count: 4, start: "192.168.1.150", mask: "255.255.255.0",
                                                gateway: "192.168.1.1", avoid: ["192.168.1.151", "192.168.1.153"])
        #expect(plan == ["192.168.1.150", "192.168.1.152", "192.168.1.154", "192.168.1.155"])
    }

    @Test func executionOrderAvoidsTransientConflicts() throws {
        // A: .111 → .110, B: .108 → .111, C: .110 → .112 — C must move first, then A, then B.
        let order = try #require(BatchReaddress.executionOrder(
            current: ["192.168.1.111", "192.168.1.108", "192.168.1.110"],
            targets: ["192.168.1.110", "192.168.1.111", "192.168.1.112"]))
        #expect(order == [2, 0, 1])
        // Devices keeping their own address are fine.
        #expect(BatchReaddress.executionOrder(current: ["10.0.0.1", "10.0.0.2"], targets: ["10.0.0.1", "10.0.0.2"]) == [0, 1])
        // A circular swap is impossible without a temporary address.
        #expect(BatchReaddress.executionOrder(current: ["10.0.0.1", "10.0.0.2"], targets: ["10.0.0.2", "10.0.0.1"]) == nil)
    }

    @Test func planErrors() {
        #expect(throws: BatchReaddress.PlanError.notEnoughAddresses(available: 1)) {
            try BatchReaddress.addresses(count: 2, start: "10.1.1.253", mask: "255.255.255.0", gateway: "10.1.1.254", avoid: [])
        }
        #expect(throws: BatchReaddress.PlanError.invalidStart) {
            try BatchReaddress.addresses(count: 1, start: "10.1.1.0", mask: "255.255.255.0", gateway: "", avoid: [])
        }
        #expect(throws: BatchReaddress.PlanError.invalidMask) {
            try BatchReaddress.addresses(count: 1, start: "10.1.1.5", mask: "255.0.255.0", gateway: "", avoid: [])
        }
        #expect(throws: BatchReaddress.PlanError.gatewayOutsideSubnet) {
            try BatchReaddress.addresses(count: 1, start: "10.1.1.5", mask: "255.255.255.0", gateway: "10.1.2.1", avoid: [])
        }
    }

    @Test func readdressesTheDeviceIdentifiedByMAC() throws {
        let device = try FakeDevice(password: "secret", http: true)
        defer { device.stop() }
        let plan: BatchReaddress.Plan = [
            "11:22:33:44:55:66": .init(ip: "192.168.1.151", mask: "255.255.255.0", gateway: "192.168.1.1"),
            "aa:bb:cc:dd:ee:ff": .init(ip: "192.168.1.150", mask: "255.255.255.0", gateway: "192.168.1.1", dns: ["1.1.1.1"]),
        ]
        let result = try BatchReaddress.readdressOne(host: "127.0.0.1", user: "admin", password: "secret", plan: plan, port: device.port, timeout: 2)
        #expect(result == .init(mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.1.150", confirmed: true))
        let set = try #require(device.calls.first { $0["method"] == "configManager.setConfig" })
        #expect(set["params"]?["table"]?["eth0"]?["IPAddress"] == "192.168.1.150")
        #expect(set["params"]?["table"]?["eth0"]?["DnsServers"] == ["1.1.1.1", "1.1.1.1"])
        #expect(set["params"]?["table"]?["eth0"]?["PhysicalAddress"] == "aa:bb:cc:dd:ee:ff")
    }

    @Test func refusesDeviceOutsideThePlan() throws {
        let device = try FakeDevice(password: "secret", http: true)
        defer { device.stop() }
        let plan: BatchReaddress.Plan = ["11:22:33:44:55:66": .init(ip: "192.168.1.151", mask: "255.255.255.0", gateway: "")]
        #expect(throws: RPCError.self) {
            try BatchReaddress.readdressOne(host: "127.0.0.1", user: "admin", password: "secret", plan: plan, port: device.port, timeout: 2)
        }
        #expect(!device.calls.contains { $0["method"] == "configManager.setConfig" })
    }
}
