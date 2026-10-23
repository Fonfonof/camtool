import Foundation

/// Encoding / decoding of DHIP frames (JSON-RPC over TCP/UDP used by Dahua devices).
///
/// Format reimplemented from observed network traffic (interoperability,
/// EU Directive 2009/24/EC art. 5(3)). No part of the Dahua SDK is used.
///
/// A frame = 32-byte header (little-endian integers) + payload:
///
///     off  size  content
///     0    4     header length, 0x20
///     4    4     magic "DHIP"
///     8    4     session id
///     12   4     request id
///     16   4     total payload length
///     20   4     reserved (0)
///     24   4     JSON part length (= total, unless binary data follows)
///     28   4     reserved (0)
///
/// Any binary data follows the JSON inside the payload.
public enum DHIP {
    public static let headerLength = 32
    static let magic: [UInt8] = Array("DHIP".utf8)

    public struct Header: Sendable, Equatable {
        public var sessionID: UInt32
        public var requestID: UInt32
        public var length: Int
        public var jsonLength: Int
    }

    public struct Packet: Sendable {
        public var sessionID: UInt32
        public var requestID: UInt32
        public var payload: [String: JSONValue]
        public var extra: Data
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case tooShort(Int)
        case badMagic
        case truncated(got: Int, expected: Int)
        case invalidJSON(String)

        public var description: String {
            switch self {
            case .tooShort(let n): tr("frame too short (\(n) bytes)", fr: "trame trop courte (\(n) octets)")
            case .badMagic: tr("unexpected magic (the device may not speak DHIP on this port)", fr: "magic inattendu (l'appareil ne parle peut-être pas DHIP sur ce port)")
            case .truncated(let got, let expected): tr("truncated payload (\(got)/\(expected) bytes)", fr: "charge utile tronquée (\(got)/\(expected) octets)")
            case .invalidJSON(let why): tr("invalid JSON: \(why)", fr: "JSON invalide : \(why)")
            }
        }
    }

    public static func encode(_ payload: [String: JSONValue], sessionID: UInt32 = 0, requestID: UInt32 = 0) -> Data {
        let body = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        var frame = Data(capacity: headerLength + body.count)
        frame.appendLE(UInt32(headerLength))
        frame.append(contentsOf: magic)
        frame.appendLE(sessionID)
        frame.appendLE(requestID)
        frame.appendLE(UInt32(body.count))
        frame.appendLE(UInt32(0))
        frame.appendLE(UInt32(body.count))
        frame.appendLE(UInt32(0))
        frame.append(body)
        return frame
    }

    public static func parseHeader(_ data: Data) throws -> Header {
        guard data.count >= headerLength else { throw Error.tooShort(data.count) }
        let bytes = [UInt8](data.prefix(headerLength))
        guard Array(bytes[4..<8]) == magic else { throw Error.badMagic }
        let length = Int(bytes.readLE(at: 16))
        var jsonLength = Int(bytes.readLE(at: 24))
        if jsonLength <= 0 || jsonLength > length { jsonLength = length }
        return Header(sessionID: bytes.readLE(at: 8), requestID: bytes.readLE(at: 12), length: length, jsonLength: jsonLength)
    }

    public static func decode(_ data: Data) throws -> Packet {
        let header = try parseHeader(data)
        let body = Data(data.dropFirst(headerLength).prefix(header.length))
        guard body.count == header.length else { throw Error.truncated(got: body.count, expected: header.length) }
        var json = body.prefix(header.jsonLength)
        while json.last == 0 { json.removeLast() }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: json)
        } catch {
            throw Error.invalidJSON(String(describing: error))
        }
        guard case .object(let payload) = value else { throw Error.invalidJSON(tr("the payload is not a JSON object", fr: "la charge utile n'est pas un objet JSON")) }
        return Packet(sessionID: header.sessionID, requestID: header.requestID, payload: payload,
                      extra: Data(body.dropFirst(header.jsonLength)))
    }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension [UInt8] {
    func readLE(at offset: Int) -> UInt32 {
        self[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
