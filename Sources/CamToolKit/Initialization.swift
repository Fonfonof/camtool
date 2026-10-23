import CommonCrypto
import Foundation
import Security

/// Whether a device still needs its first password.
public enum InitStatus: Sendable, Equatable {
    case uninitialized
    case initialized
    case unknown

    /// The two low bits of the `Init` value: 1 = uninitialized, 2 = initialized (0 = legacy device).
    init(initValue: Int?) {
        switch (initValue ?? 0) & 0b11 {
        case 1: self = .uninitialized
        case 2: self = .initialized
        default: self = .unknown
        }
    }
}

extension Device {
    /// Read from the discovery reply, before any login.
    public var initStatus: InitStatus { InitStatus(initValue: raw["Init"]?.intValue) }
}

/// First-time setup of a factory-new device: sets the admin password.
///
/// Uses the same unauthenticated endpoint as the device's own web setup page
/// (`/OutsideCmd`). The account is sent encrypted: a random AES key encrypts the JSON,
/// and the device's RSA public key encrypts that AES key.
public enum DeviceSetup {
    public static let adminUser = "admin"

    public struct Status: Sendable {
        public var initStatus: InitStatus
        /// Password recovery methods offered by the device ("A" phone, "B" e-mail, …).
        public var recoveryMethods: String
    }

    public static func status(host: String, port: UInt16 = 80, timeout: Double = 5) throws -> Status {
        let params = try outsideCommand("DevInit.getStatus", host: host, port: port, timeout: timeout)
        return Status(initStatus: InitStatus(initValue: params["Init"]?.intValue),
                      recoveryMethods: params["Find"]?.stringValue ?? "")
    }

    /// Sets the admin password of an uninitialized device. Refuses a device that is already initialized.
    public static func initialize(host: String, port: UInt16 = 80, timeout: Double = 5,
                                  password: String, email: String = "") throws {
        guard try status(host: host, port: port, timeout: timeout).initStatus != .initialized else {
            throw RPCError(method: "DevInit.account", message: tr("the device is already initialized", fr: "l'appareil est déjà initialisé"),
                           isAuthentication: false)
        }
        let info = try outsideCommand("Security.getEncryptInfo", host: host, port: port, timeout: timeout)
        guard let publicKey = info["pub"]?.stringValue else {
            throw RPCError(method: "Security.getEncryptInfo", message: tr("no public key in the reply", fr: "pas de clé publique dans la réponse"),
                           isAuthentication: false)
        }
        let account: JSONValue = ["name": .string(adminUser), "pwd": .string(password), "CellPhone": "", "Mail": .string(email)]
        let sealed = try seal(account, publicKey: publicKey)
        _ = try outsideCommand("DevInit.account", params: sealed, host: host, port: port, timeout: timeout)
    }

    /// Problems with a new password, following the devices' rules. Empty when acceptable.
    public static func passwordProblems(_ password: String) -> [String] {
        var problems: [String] = []
        if !(8...32).contains(password.count) {
            problems.append(tr("8 to 32 characters.", fr: "8 à 32 caractères."))
        }
        let forbidden = Set("'\";:&")
        if password.contains(where: forbidden.contains) {
            problems.append(tr("No ' \" ; : & characters.", fr: "Pas de caractères ' \" ; : &."))
        }
        let kinds = [
            password.contains(where: \.isUppercase),
            password.contains(where: \.isLowercase),
            password.contains(where: \.isNumber),
            password.contains { !$0.isLetter && !$0.isNumber },
        ].filter { $0 }.count
        if kinds < 2 {
            problems.append(tr("At least two of: uppercase, lowercase, digits, symbols.",
                               fr: "Au moins deux types parmi : majuscules, minuscules, chiffres, symboles."))
        }
        return problems
    }

    // MARK: - Transport

    static func outsideCommand(_ method: String, params: JSONValue = nil, host: String, port: UInt16, timeout: Double) throws -> [String: JSONValue] {
        let channel = try HTTPChannel(host: host, port: port, timeout: timeout, fixedPath: "OutsideCmd")
        let reply = try channel.send(["method": .string(method), "params": params, "id": 1, "session": 0])
        guard reply["result"] == .bool(true) else { throw RPCError(method: method, reply: reply) }
        return reply["params"]?.objectValue ?? [:]
    }

    // MARK: - Encryption

    /// `{cipher, salt, content}` as expected by the DevInit methods (AES-128, ECB, zero padding).
    static func seal(_ payload: JSONValue, publicKey: String, key: String = randomDigits(16)) throws -> JSONValue {
        let json = try JSONEncoder().encode(payload)
        let content = try aes128ECBZeroPadded(json, key: Data(key.utf8)).base64EncodedString()
        let salt = try rsaPKCS1Encrypt(Data(key.utf8), publicKey: publicKey).map { String(format: "%02x", $0) }.joined()
        return ["cipher": "AES-128", "salt": .string(salt), "content": .string(content)]
    }

    static func randomDigits(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in Character(String(Int.random(in: 0...9, using: &generator))) })
    }

    static func aes128ECBZeroPadded(_ data: Data, key: Data) throws -> Data {
        var input = data
        if input.count % kCCBlockSizeAES128 != 0 {
            input.append(Data(count: kCCBlockSizeAES128 - input.count % kCCBlockSizeAES128))
        }
        var output = Data(count: input.count)
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil, inp.baseAddress, input.count,
                            out.baseAddress, out.count, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw SocketError.other("AES (\(status))") }
        return output.prefix(written)
    }

    /// Encrypts with a public key given as "N:<hex modulus>,E:<hex exponent>".
    static func rsaPKCS1Encrypt(_ data: Data, publicKey: String) throws -> Data {
        var parts: [String: String] = [:]
        for field in publicKey.split(separator: ",") {
            let pair = field.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { parts[pair[0].uppercased()] = pair[1] }
        }
        guard let modulus = parts["N"].flatMap(Data.init(hex:)), let exponent = parts["E"].flatMap(Data.init(hex:)) else {
            throw SocketError.other(tr("unreadable public key", fr: "clé publique illisible"))
        }
        let der = DER.sequence(DER.integer(modulus) + DER.integer(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data as CFData, &error)
        else {
            throw SocketError.other("RSA: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return encrypted as Data
    }
}

/// Just enough DER to build a PKCS#1 RSAPublicKey.
enum DER {
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes = withUnsafeBytes(of: UInt32(count).bigEndian, Array.init).drop { $0 == 0 }
        bytes.insert(0x80 | UInt8(bytes.count), at: bytes.startIndex)
        return Data(bytes)
    }

    static func integer(_ magnitude: Data) -> Data {
        var value = Data(magnitude.drop { $0 == 0 })
        if value.isEmpty || value.first! & 0x80 != 0 { value.insert(0, at: 0) }
        return Data([0x02]) + length(value.count) + value
    }

    static func sequence(_ content: Data) -> Data {
        Data([0x30]) + length(content.count) + content
    }
}

extension Data {
    init?(hex: String) {
        let hex = hex.count % 2 == 0 ? hex : "0" + hex
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
