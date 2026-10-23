import Foundation
import Testing
@testable import CamToolKit

@Suite struct DHIPTests {
    @Test func roundTrip() throws {
        let frame = DHIP.encode(["method": "x", "params": ["a": 1]], sessionID: 7, requestID: 3)
        #expect(Array(frame.prefix(8)) == [0x20, 0, 0, 0] + Array("DHIP".utf8))
        let packet = try DHIP.decode(frame)
        #expect(packet.sessionID == 7 && packet.requestID == 3)
        #expect(packet.payload == ["method": "x", "params": ["a": 1]])
    }

    @Test func lengthsInHeader() throws {
        let frame = DHIP.encode(["k": "v"])
        let header = try DHIP.parseHeader(frame)
        #expect(header.length == frame.count - DHIP.headerLength)
        #expect(header.jsonLength == header.length)
    }

    @Test func rejectsBadFrames() {
        #expect(throws: DHIP.Error.tooShort(0)) { try DHIP.decode(Data()) }
        #expect(throws: DHIP.Error.badMagic) { try DHIP.decode(Data([0x20, 0, 0, 0] + Array("XXXX".utf8) + [UInt8](repeating: 0, count: 24))) }
        let full = DHIP.encode(["a": 1])
        #expect(throws: DHIP.Error.self) { try DHIP.decode(full.dropLast(2)) }
    }

    @Test func toleratesTrailingNulAndBinaryTrailer() throws {
        let json = Data(#"{"a":1}"#.utf8) + [0]
        let binary = Data([0xDE, 0xAD])
        var frame = Data()
        for v: UInt32 in [32] { frame.appendLE(v) }
        frame.append(contentsOf: Array("DHIP".utf8))
        for v in [0, 0, UInt32(json.count + binary.count), 0, UInt32(json.count), 0] { frame.appendLE(v) }
        frame += json + binary
        let packet = try DHIP.decode(frame)
        #expect(packet.payload == ["a": 1])
        #expect(packet.extra == binary)
    }

    @Test func jsonValueTypes() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"b":true,"i":37777,"d":1.5,"s":"x","n":null,"a":[1]}"#.utf8))
        #expect(value == ["b": true, "i": 37777, "d": .double(1.5), "s": "x", "n": nil, "a": [1]])
    }
}

@Suite struct DiscoveryTests {
    static let notify: [String: JSONValue] = [
        "method": "client.notifyDevInfo",
        "mac": "3C:EF:8C:12:34:56",
        "params": ["deviceInfo": [
            "DeviceType": "IPC-HDW2431T-AS-S2",
            "SerialNo": "6G0ABCDEF123456",
            "Version": "2.800.0000000.25.R",
            "HttpPort": 80,
            "Port": 37777,
            "IPv4Address": [
                "IPAddress": "192.168.1.108", "SubnetMask": "255.255.255.0",
                "DefaultGateway": "192.168.1.1", "DhcpEnable": false,
            ],
        ]],
    ]

    @Test func searchRequest() throws {
        #expect(try DHIP.decode(Discovery.searchRequest()).payload["method"] == "DHDiscover.search")
    }

    @Test func parseNotify() throws {
        let device = try #require(Discovery.parseResponse(DHIP.encode(Self.notify), source: "192.168.1.108"))
        #expect(device.ip == "192.168.1.108")
        #expect(device.model == "IPC-HDW2431T-AS-S2")
        #expect(device.tcpPort == 37777)
        #expect(device.dhcp == false)
        #expect(device.key == "3c:ef:8c:12:34:56")
    }

    @Test func ignoresOwnSearchAndGarbage() {
        #expect(Discovery.parseResponse(Discovery.searchRequest(), source: "10.0.0.1") == nil)
        #expect(Discovery.parseResponse(Data("garbage".utf8), source: "10.0.0.1") == nil)
        #expect(Discovery.parseResponse(DHIP.encode(["method": "client.notifyDevInfo"]), source: "10.0.0.1") == nil)
    }

    @Test func fallsBackToSourceIP() throws {
        let frame = DHIP.encode(["method": "client.notifyDevInfo", "params": ["deviceInfo": [:]]])
        #expect(try #require(Discovery.parseResponse(frame, source: "10.0.0.9")).ip == "10.0.0.9")
    }
}

@Suite struct LanguageTests {
    @Test func englishByDefault() {
        #expect(Language.resolve(override: nil, preferred: ["en-US"]) == .english)
        #expect(Language.resolve(override: nil, preferred: ["de-DE", "fr-FR"]) == .english)
        #expect(Language.resolve(override: nil, preferred: []) == .english)
    }

    @Test func frenchWhenPreferred() {
        #expect(Language.resolve(override: nil, preferred: ["fr-FR", "en-US"]) == .french)
        #expect(Language.resolve(override: nil, preferred: ["fr-CA"]) == .french)
    }

    @Test func overrideWins() {
        #expect(Language.resolve(override: "en", preferred: ["fr-FR"]) == .english)
        #expect(Language.resolve(override: "FR", preferred: ["en-US"]) == .french)
        #expect(Language.resolve(override: "", preferred: ["fr-FR"]) == .french)
    }
}
