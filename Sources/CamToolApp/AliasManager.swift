import CamToolKit
import Foundation

/// Adds a temporary IPv4 address to this Mac so that devices on another subnet can be reached
/// (e.g. a camera at 10.1.1.109 while the Mac is on 192.168.1.0/24).
///
/// Needs administrator rights: macOS asks for the Mac's password. Aliases are removed once no
/// longer needed, when CamTool quits, or at the next launch if CamTool was closed abruptly
/// (they are recorded on disk for that). Restarting the Mac also clears them.
@MainActor
final class AliasManager {
    /// One instance for the whole app, so quitting can clean up every alias.
    static let shared = AliasManager()
    private init() {}

    struct Alias: Hashable, Codable {
        var interface: String
        var address: String
        var netmask: String
    }

    private static let storageKey = "temporaryAliases"

    private(set) var active: [Alias] = [] {
        didSet { Self.save(active) }
    }

    /// Makes `device` reachable, adding an alias if needed. Returns the alias added, or nil if none was needed.
    func ensureReachable(_ device: Device, taken: [String]) async throws -> Alias? {
        if LocalNetwork.isOnLink(device.ip) { return nil }
        guard let (address, netmask) = LocalNetwork.aliasAddress(for: device, taken: taken) else {
            throw SocketError.other(tr("no free address in the device's subnet", fr: "aucune adresse libre dans le sous-réseau de l'appareil"))
        }
        let alias = Alias(interface: try await Self.defaultInterface(), address: address, netmask: netmask)
        try await Self.runPrivileged("/sbin/ifconfig \(alias.interface) alias \(alias.address) netmask \(alias.netmask)", prompt: tr(
            "CamTool needs to add the temporary address \(address) to this Mac to reach the device at \(device.ip).",
            fr: "CamTool doit ajouter l'adresse temporaire \(address) à ce Mac pour joindre l'appareil \(device.ip)."))
        active.append(alias)
        // The kernel needs a moment before the new route is used.
        try? await Task.sleep(for: .milliseconds(500))
        return alias
    }

    /// Removes one alias right away. macOS usually remembers the administrator password
    /// for a few minutes, so this rarely asks again.
    func remove(_ alias: Alias) async throws {
        try await Self.runPrivileged(Self.removeCommand([alias]), prompt: tr(
            "CamTool needs to remove the temporary address \(alias.address) from this Mac.",
            fr: "CamTool doit retirer l'adresse temporaire \(alias.address) de ce Mac."))
        active.removeAll { $0 == alias }
    }

    /// Removes every alias still active, in a single administrator prompt.
    func removeAll(prompt: String = tr(
        "CamTool needs to remove its temporary addresses from this Mac before quitting.",
        fr: "CamTool doit retirer ses adresses temporaires de ce Mac avant de quitter.")) async throws {
        guard !active.isEmpty else { return }
        try await Self.runPrivileged(Self.removeCommand(active), prompt: prompt)
        active.removeAll()
    }

    /// Removes aliases left by a previous session that ended abruptly (crash, forced quit).
    func cleanUpLeftovers() async {
        let present = Set(LocalNetwork.interfaces().map(\.address))
        active = Self.load().filter { present.contains($0.address) }
        try? await removeAll(prompt: tr(
            "CamTool was not closed properly last time. It needs to remove the temporary addresses it had added to this Mac.",
            fr: "CamTool n'a pas été fermé correctement la dernière fois. Il doit retirer les adresses temporaires qu'il avait ajoutées à ce Mac."))
    }

    /// This Mac's interfaces, ignoring the temporary aliases added by CamTool.
    func permanentInterfaces() -> [LocalNetwork.Interface] {
        LocalNetwork.interfaces().filter { iface in !active.contains { $0.address == iface.address } }
    }

    // MARK: - Persistence

    private static func save(_ aliases: [Alias]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(aliases), forKey: storageKey)
    }

    private static func load() -> [Alias] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return ((try? JSONDecoder().decode([Alias].self, from: data)) ?? [])
            .filter { isSafeInterfaceName($0.interface) && IPv4($0.address) != nil && IPv4($0.netmask) != nil }
    }

    // MARK: - Shell

    static func removeCommand(_ aliases: [Alias]) -> String {
        aliases.map { "/sbin/ifconfig \($0.interface) -alias \($0.address)" }.joined(separator: "; ")
    }

    /// Interface carrying the default route, which is also the one discovery uses.
    static func defaultInterface() async throws -> String {
        let output = try await run("/sbin/route", ["-n", "get", "default"])
        let name = output.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }
            .map { $0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces) }
        if let name, isSafeInterfaceName(name) { return name }
        if let fallback = LocalNetwork.interfaces().first(where: { $0.name.hasPrefix("en") })?.name { return fallback }
        throw SocketError.other(tr("no active network interface", fr: "aucune interface réseau active"))
    }

    static func isSafeInterfaceName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func runPrivileged(_ command: String, prompt: String) async throws {
        // Only interface names and dotted addresses are interpolated (validated), never user text.
        let escaped = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "do shell script \"\(escaped(command))\" with prompt \"\(escaped(prompt))\" with administrator privileges"
        do {
            _ = try await run("/usr/bin/osascript", ["-e", script])
        } catch let error as ProcessError where error.output.contains("-128") {
            throw SocketError.other(tr("cancelled by the user", fr: "annulé par l'utilisateur"))
        }
    }

    struct ProcessError: Error, CustomStringConvertible {
        var output: String
        var description: String { output }
    }

    static func run(_ path: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw ProcessError(output: output) }
            return output
        }.value
    }
}
