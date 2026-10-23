import Darwin
import Foundation

/// IPv4 settings of one network interface, read from and written back to the "Network" configuration.
///
/// Writing is read-modify-write: `applied(to:)` only touches these fields inside the full
/// configuration read from the device, so unknown fields are preserved.
public struct NetworkSettings: Sendable, Equatable {
    public var interface: String
    public var dhcp: Bool
    public var ip: String
    public var mask: String
    public var gateway: String
    public var dns: [String]

    public init(interface: String = "eth0", dhcp: Bool, ip: String, mask: String, gateway: String, dns: [String]) {
        self.interface = interface
        self.dhcp = dhcp
        self.ip = ip
        self.mask = mask
        self.gateway = gateway
        self.dns = dns
    }

    /// Reads the settings of the default interface from a "Network" configuration table.
    public init?(config: JSONValue) {
        let interface = config["DefaultInterface"]?.stringValue ?? "eth0"
        guard let eth = config[interface], eth.objectValue != nil else { return nil }
        var dns: [String] = []
        if case .array(let servers)? = eth["DnsServers"] { dns = servers.compactMap(\.stringValue) }
        self.init(
            interface: interface,
            dhcp: eth["DhcpEnable"]?.boolValue ?? false,
            ip: eth["IPAddress"]?.stringValue ?? "",
            mask: eth["SubnetMask"]?.stringValue ?? "",
            gateway: eth["DefaultGateway"]?.stringValue ?? "",
            dns: dns
        )
    }

    /// Returns `config` with these settings written into the interface, everything else untouched.
    public func applied(to config: JSONValue) -> JSONValue {
        guard case .object(var root) = config, case .object(var eth)? = root[interface] else { return config }
        eth["DhcpEnable"] = .bool(dhcp)
        eth["IPAddress"] = .string(ip)
        eth["SubnetMask"] = .string(mask)
        eth["DefaultGateway"] = .string(gateway)
        let servers = dns.filter { !$0.isEmpty }
        if !servers.isEmpty {
            // Devices expect two entries: repeat the primary server when there is no secondary.
            eth["DnsServers"] = .array((servers.count == 1 ? [servers[0], servers[0]] : servers).map { .string($0) })
        }
        root[interface] = .object(eth)
        return .object(root)
    }

    /// Problems that make the settings unusable, in the current language. Empty when valid.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        let servers = dns.filter { !$0.isEmpty }
        if servers.contains(where: { IPv4($0) == nil }) {
            errors.append(tr("Invalid DNS server address.", fr: "Adresse de serveur DNS invalide."))
        }
        if dhcp { return errors }

        guard let address = IPv4(ip) else {
            return errors + [tr("Invalid IP address.", fr: "Adresse IP invalide.")]
        }
        guard let netmask = IPv4(mask), netmask.isNetmask, netmask.value != 0 else {
            return errors + [tr("Invalid subnet mask.", fr: "Masque de sous-réseau invalide.")]
        }
        let hostBits = ~netmask.value
        if hostBits > 1 && (address.value & hostBits == 0 || address.value & hostBits == hostBits) {
            errors.append(tr("The IP address is the network or broadcast address of its subnet.",
                             fr: "L'adresse IP est l'adresse de réseau ou de broadcast de son sous-réseau."))
        }
        if !gateway.isEmpty {
            if let router = IPv4(gateway) {
                if !router.isInSubnet(of: address, mask: netmask) {
                    errors.append(tr("The gateway is not in the same subnet as the IP address.",
                                     fr: "La passerelle n'est pas dans le même sous-réseau que l'adresse IP."))
                } else if router == address {
                    errors.append(tr("The gateway cannot be the device's own address.",
                                     fr: "La passerelle ne peut pas être l'adresse de l'appareil."))
                }
            } else {
                errors.append(tr("Invalid gateway address.", fr: "Adresse de passerelle invalide."))
            }
        }
        return errors
    }
}

/// Minimal IPv4 address value, for validation.
public struct IPv4: Sendable, Equatable {
    public let value: UInt32

    public init?(_ string: String) {
        var addr = in_addr()
        // inet_pton rejects shorthand forms like "10.1" that inet_aton would accept.
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        value = UInt32(bigEndian: addr.s_addr)
    }

    /// True for contiguous masks such as 255.255.255.0.
    public var isNetmask: Bool { (~value) & (~value &+ 1) == 0 }

    public func isInSubnet(of other: IPv4, mask: IPv4) -> Bool {
        value & mask.value == other.value & mask.value
    }
}

extension Client {
    /// Fails unless the device answering is the one with this MAC address. Guards against
    /// talking to the wrong device when several share an IP (e.g. new cameras at 192.168.1.108).
    public func verifyMAC(_ expected: String) throws -> JSONValue {
        let network = try config("Network")
        let interface = network["DefaultInterface"]?.stringValue ?? "eth0"
        let actual = network[interface]?["PhysicalAddress"]?.stringValue ?? ""
        if !expected.isEmpty, !actual.isEmpty, actual.lowercased() != expected.lowercased() {
            throw RPCError(method: "configManager.getConfig", message: tr(
                "another device (\(actual)) answered at this address instead of \(expected)",
                fr: "un autre appareil (\(actual)) a répondu à cette adresse au lieu de \(expected)"), isAuthentication: false)
        }
        return network
    }

    /// Writes a full configuration section (`configManager.setConfig`).
    public func setConfig(_ name: String, table: JSONValue) throws {
        try call("configManager.setConfig", params: ["name": .string(name), "table": table])
    }
}
