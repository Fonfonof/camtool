import Foundation

/// Re-addressing several devices at once, including several factory-new devices sharing
/// the same address (e.g. all at 192.168.1.108).
///
/// Devices are always identified by the MAC address they report after login, never by their
/// IP alone, so a device answering at a shared address receives the address planned for it.
public enum BatchReaddress {
    /// New settings for one device, keyed by its MAC address in `Plan`.
    public struct Target: Sendable, Equatable {
        public var ip: String
        public var mask: String
        public var gateway: String
        /// Empty: keep the device's DNS servers.
        public var dns: [String]

        public init(ip: String, mask: String, gateway: String, dns: [String] = []) {
            self.ip = ip
            self.mask = mask
            self.gateway = gateway
            self.dns = dns
        }
    }

    /// Lower-cased MAC → target.
    public typealias Plan = [String: Target]

    public struct Result: Sendable, Equatable {
        public var mac: String
        public var ip: String
        /// False when the device stopped answering right after the write (usually means it applied).
        public var confirmed: Bool
    }

    public enum PlanError: Error, Equatable, CustomStringConvertible {
        case invalidStart, invalidMask, gatewayOutsideSubnet, notEnoughAddresses(available: Int)

        public var description: String {
            switch self {
            case .invalidStart: tr("Invalid start address.", fr: "Adresse de départ invalide.")
            case .invalidMask: tr("Invalid subnet mask.", fr: "Masque de sous-réseau invalide.")
            case .gatewayOutsideSubnet: tr("The gateway is not in the same subnet.", fr: "La passerelle n'est pas dans le même sous-réseau.")
            case .notEnoughAddresses(let n): tr("Only \(n) free address(es) from the start address to the end of the subnet.",
                                                 fr: "Seulement \(n) adresse(s) libre(s) entre l'adresse de départ et la fin du sous-réseau.")
            }
        }
    }

    /// Consecutive free addresses from `start`, skipping `avoid` (other devices, gateway, this Mac),
    /// and never the network or broadcast address.
    public static func addresses(count: Int, start: String, mask: String, gateway: String, avoid: [String]) throws -> [String] {
        guard let first = IPv4(start) else { throw PlanError.invalidStart }
        guard let netmask = IPv4(mask), netmask.isNetmask, netmask.value != 0, netmask.value != .max else { throw PlanError.invalidMask }
        let network = first.value & netmask.value
        let broadcast = network | ~netmask.value
        guard first.value > network, first.value < broadcast else { throw PlanError.invalidStart }
        if !gateway.isEmpty {
            guard let router = IPv4(gateway), router.isInSubnet(of: first, mask: netmask) else { throw PlanError.gatewayOutsideSubnet }
        }
        let excluded = Set((avoid + [gateway]).compactMap { IPv4($0)?.value })
        var result: [String] = []
        var candidate = first.value
        while result.count < count, candidate < broadcast {
            if !excluded.contains(candidate) { result.append(IPv4(value: candidate).description) }
            candidate += 1
        }
        guard result.count == count else { throw PlanError.notEnoughAddresses(available: result.count) }
        return result
    }

    /// Order in which to re-address devices so that no device takes an address still used by
    /// another device of the batch: a device whose target is another one's current address waits
    /// until that one has moved. Returns nil for a circular swap (A→B's address, B→A's address).
    public static func executionOrder(current: [String], targets: [String]) -> [Int]? {
        var pending = Array(current.indices)
        var occupied = current
        var order: [Int] = []
        while !pending.isEmpty {
            guard let next = pending.first(where: { i in
                !occupied.enumerated().contains { $0.offset != i && $0.element == targets[i] }
            }) else { return nil }
            order.append(next)
            occupied[next] = targets[next]
            pending.removeAll { $0 == next }
        }
        return order
    }

    /// Logs in at `host`, identifies the device answering by its MAC, and writes the address
    /// planned for it. Throws if that device is not in the plan.
    public static func readdressOne(host: String, user: String, password: String, plan: Plan,
                                    port: UInt16 = 80, timeout: Double = 5) throws -> Result {
        let client = Client(host: host, transport: .http(port: port), timeout: timeout)
        defer { client.close() }
        try client.login(user: user, password: password)
        let network = try client.config("Network")
        guard var settings = NetworkSettings(config: network) else {
            throw RPCError(method: "configManager.getConfig", message: tr("no network configuration", fr: "pas de configuration réseau"),
                           isAuthentication: false)
        }
        let mac = (network[settings.interface]?["PhysicalAddress"]?.stringValue ?? "").lowercased()
        guard let target = plan[mac] else {
            throw RPCError(method: "configManager.getConfig", message: tr(
                "the device answering at \(host) (\(mac.isEmpty ? "?" : mac)) is not in the selection",
                fr: "l'appareil qui répond à \(host) (\(mac.isEmpty ? "?" : mac)) ne fait pas partie de la sélection"), isAuthentication: false)
        }
        settings.dhcp = false
        settings.ip = target.ip
        settings.mask = target.mask
        settings.gateway = target.gateway
        settings.dns = target.dns
        if let problem = settings.validationErrors().first {
            throw RPCError(method: "configManager.setConfig", message: problem, isAuthentication: false)
        }
        do {
            try client.setConfig("Network", table: settings.applied(to: network))
            return Result(mac: mac, ip: target.ip, confirmed: true)
        } catch let error as RPCError {
            throw error
        } catch {
            // The device may switch address before answering: the change is likely applied.
            return Result(mac: mac, ip: target.ip, confirmed: false)
        }
    }
}
