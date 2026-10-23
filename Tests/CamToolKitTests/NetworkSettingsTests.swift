import Testing
@testable import CamToolKit

@Suite struct NetworkSettingsTests {
    /// Same shape as the "Network" table returned by a camera (firmware 3.140).
    static let config: JSONValue = [
        "DefaultInterface": "eth0",
        "Domain": "Dahua",
        "Hostname": "IPC",
        "eth0": [
            "DefaultGateway": "192.168.1.1",
            "DhcpEnable": false,
            "DnsServers": ["8.8.8.8", "8.8.4.4"],
            "EnableDhcpReservedIP": false,
            "IPAddress": "192.168.1.108",
            "MTU": 1500,
            "PhysicalAddress": "30:dd:aa:00:00:01",
            "SubnetMask": "255.255.255.0",
        ],
    ]

    @Test func readsDefaultInterface() throws {
        let settings = try #require(NetworkSettings(config: Self.config))
        #expect(settings == NetworkSettings(dhcp: false, ip: "192.168.1.108", mask: "255.255.255.0",
                                            gateway: "192.168.1.1", dns: ["8.8.8.8", "8.8.4.4"]))
        #expect(NetworkSettings(config: ["DefaultInterface": "eth0"]) == nil)
    }

    @Test func writesOnlyEditedFields() throws {
        var settings = try #require(NetworkSettings(config: Self.config))
        settings.ip = "192.168.1.150"
        settings.dns = ["1.1.1.1", ""]
        let updated = settings.applied(to: Self.config)
        #expect(updated["eth0"]?["IPAddress"] == "192.168.1.150")
        #expect(updated["eth0"]?["DnsServers"] == ["1.1.1.1", "1.1.1.1"])
        // Untouched fields survive.
        #expect(updated["eth0"]?["MTU"] == 1500)
        #expect(updated["eth0"]?["PhysicalAddress"] == "30:dd:aa:00:00:01")
        #expect(updated["eth0"]?["EnableDhcpReservedIP"] == false)
        #expect(updated["Hostname"] == "IPC")
    }

    @Test func validSettingsHaveNoErrors() throws {
        #expect(try #require(NetworkSettings(config: Self.config)).validationErrors().isEmpty)
        #expect(NetworkSettings(dhcp: true, ip: "", mask: "", gateway: "", dns: []).validationErrors().isEmpty)
        #expect(NetworkSettings(dhcp: false, ip: "10.0.0.5", mask: "255.0.0.0", gateway: "", dns: []).validationErrors().isEmpty)
    }

    @Test(arguments: [
        ("192.168.1.300", "255.255.255.0", "192.168.1.1"),   // bad IP
        ("192.168.1", "255.255.255.0", "192.168.1.1"),       // shorthand IP
        ("192.168.1.10", "255.0.255.0", "192.168.1.1"),      // non-contiguous mask
        ("192.168.1.10", "255.255.255.0", "192.168.2.1"),    // gateway in another subnet
        ("192.168.1.10", "255.255.255.0", "192.168.1.10"),   // gateway = device
        ("192.168.1.0", "255.255.255.0", "192.168.1.1"),     // network address
        ("192.168.1.255", "255.255.255.0", "192.168.1.1"),   // broadcast address
    ])
    func rejectsInvalidSettings(ip: String, mask: String, gateway: String) {
        #expect(!NetworkSettings(dhcp: false, ip: ip, mask: mask, gateway: gateway, dns: []).validationErrors().isEmpty)
    }

    @Test func rejectsInvalidDNS() {
        #expect(!NetworkSettings(dhcp: true, ip: "", mask: "", gateway: "", dns: ["8.8.8"]).validationErrors().isEmpty)
    }
}

@Suite struct LocalNetworkTests {
    static let mac = [LocalNetwork.Interface(name: "en0", address: "192.168.1.20", netmask: "255.255.255.0")]

    static func device(ip: String, mask: String = "255.255.255.0", gateway: String = "") -> Device {
        Device(info: ["IPv4Address": ["IPAddress": .string(ip), "SubnetMask": .string(mask), "DefaultGateway": .string(gateway)]], source: ip)
    }

    @Test func onLinkDetection() {
        #expect(LocalNetwork.isOnLink("192.168.1.108", interfaces: Self.mac))
        #expect(!LocalNetwork.isOnLink("10.1.1.109", interfaces: Self.mac))
        #expect(!LocalNetwork.isOnLink("192.168.0.110", interfaces: Self.mac))
    }

    @Test func aliasPicksFreeHighAddress() throws {
        let alias = try #require(LocalNetwork.aliasAddress(for: Self.device(ip: "10.1.1.109", gateway: "10.1.1.254")))
        #expect(alias.address == "10.1.1.253")
        #expect(alias.netmask == "255.255.255.0")
        let taken = try #require(LocalNetwork.aliasAddress(for: Self.device(ip: "192.168.0.110"), taken: ["192.168.0.254"]))
        #expect(taken.address == "192.168.0.253")
    }

    @Test func aliasDefaultsToSlash24() throws {
        let alias = try #require(LocalNetwork.aliasAddress(for: Self.device(ip: "172.16.5.9", mask: "")))
        #expect(alias == ("172.16.5.254", "255.255.255.0"))
    }

    @Test func thisMacHasAnInterface() {
        #expect(!LocalNetwork.interfaces().isEmpty)
    }
}
