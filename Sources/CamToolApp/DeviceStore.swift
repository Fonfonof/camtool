import CamToolKit
import Foundation
import Observation

/// What an authenticated session returned for one device.
struct DeviceDetails: Sendable {
    var info: [String: JSONValue]
    var network: JSONValue
}

enum DetailState {
    case idle
    case loading
    case loaded(DeviceDetails)
    case failed(message: String, isAuthentication: Bool)
}

/// Outcome of the last write to a device, shown above its cards.
struct WriteNotice: Equatable {
    enum Kind { case success, warning, failure }
    var kind: Kind
    var message: String
}

@MainActor @Observable
final class DeviceStore {
    private(set) var devices: [Device] = []
    private(set) var isScanning = false
    private(set) var scanError: String?
    private(set) var details: [Device.ID: DetailState] = [:]
    private(set) var applying: Set<Device.ID> = []
    private(set) var notices: [Device.ID: WriteNotice] = [:] {
        didSet {
            // Success messages go away on their own; warnings and failures stay until dismissed.
            for (id, notice) in notices where notice.kind == .success && oldValue[id] != notice {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    if self?.notices[id] == notice { self?.notices[id] = nil }
                }
            }
        }
    }

    func dismissNotice(for id: Device.ID) { notices[id] = nil }
    var selection: Device.ID?

    /// Credentials of the current session, kept in memory only (never written to disk)
    /// so that edits don't ask for the password again. Cleared on disconnect.
    private var credentials: [Device.ID: (user: String, password: String)] = [:]

    /// Devices initialized during this session.
    private var initializedHere: Set<Device.ID> = []

    let aliases = AliasManager.shared
    /// Temporary address added to reach each off-subnet device, shown in its details.
    private(set) var aliasInUse: [Device.ID: AliasManager.Alias] = [:]

    /// Addresses used by more than one device (e.g. several factory-new cameras at 192.168.1.108).
    var duplicateAddresses: Set<String> {
        Set(Dictionary(grouping: devices, by: \.ip).filter { $0.value.count > 1 }.keys)
    }

    /// Makes sure this Mac can reach the device, adding a temporary address if it is on another subnet.
    private func reach(_ device: Device) async throws {
        let taken = devices.map(\.ip) + aliases.active.map(\.address)
        if let alias = try await aliases.ensureReachable(device, taken: taken) {
            aliasInUse[device.id] = alias
        }
    }

    func device(_ id: Device.ID?) -> Device? { devices.first { $0.id == id } }

    func detailState(for device: Device) -> DetailState { details[device.id] ?? .idle }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        var found: [Device] = []
        do {
            for try await device in Discovery.devices(timeout: 3) {
                found.append(device)
                // Keep devices from the previous scan visible while the new one runs.
                if let index = devices.firstIndex(where: { $0.id == device.id }) {
                    devices[index] = device
                } else {
                    devices.append(device)
                }
                devices.sort { $0.ip.ipSortKey.lexicographicallyPrecedes($1.ip.ipSortKey) }
            }
            // Drop devices that no longer answer.
            devices.removeAll { device in !found.contains { $0.id == device.id } }
        } catch {
            scanError = String(describing: error)
        }
        if selection == nil || device(selection) == nil { selection = devices.first?.id }
    }

    /// Logs in once, reads the device info and network configuration, then logs out.
    func connect(to device: Device, user: String, password: String) async {
        details[device.id] = .loading
        notices[device.id] = nil
        let host = device.ip
        let mac = device.mac
        do {
            try await reach(device)
            let result = try await Task.detached {
                let client = Client(host: host)
                defer { client.close() }
                try client.login(user: user, password: password)
                let network = try client.verifyMAC(mac)
                return DeviceDetails(info: try client.systemInfo(), network: network)
            }.value
            details[device.id] = .loaded(result)
            credentials[device.id] = (user, password)
        } catch let error as RPCError {
            details[device.id] = .failed(message: error.description, isAuthentication: error.isAuthentication)
            credentials[device.id] = nil
        } catch {
            details[device.id] = .failed(message: String(describing: error), isAuthentication: false)
        }
    }

    /// Sets the admin password of a factory-new device, then logs in to show its details.
    func initialize(_ device: Device, password: String, email: String) async {
        let id = device.id
        details[id] = .loading
        notices[id] = nil
        let host = device.ip
        do {
            try await reach(device)
            try await Task.detached {
                try DeviceSetup.initialize(host: host, password: password, email: email)
            }.value
        } catch {
            details[id] = .failed(message: String(describing: error), isAuthentication: false)
            return
        }
        initializedHere.insert(id)
        // Give the device a moment to apply the new account (still showing progress, so that
        // an early login attempt can't fail and count against the account), then refresh discovery.
        try? await Task.sleep(for: .seconds(3))
        await scan()
        details[id] = .idle
        notices[id] = WriteNotice(kind: .success, message: tr(
            "Device initialized. Click Connect and log in as admin with the password you just chose.",
            fr: "Appareil initialisé. Cliquez sur « Se connecter » et utilisez le compte admin avec le mot de passe choisi."))
    }

    /// Discovery may still report a device as new for a while after it was initialized.
    func needsInitialization(_ device: Device) -> Bool {
        device.initStatus == .uninitialized && !initializedHere.contains(device.id)
    }

    func disconnect(_ device: Device) {
        details[device.id] = .idle
        notices[device.id] = nil
        credentials[device.id] = nil
    }

    /// Writes new network settings into the configuration read earlier (read-modify-write).
    func apply(_ settings: NetworkSettings, to device: Device, baseConfig: JSONValue) async {
        guard let login = credentials[device.id] else { return }
        let id = device.id
        let host = device.ip
        let mac = device.mac
        let table = settings.applied(to: baseConfig)
        let movesDevice = settings.dhcp || settings.ip != device.ip

        applying.insert(id)
        notices[id] = nil
        defer { applying.remove(id) }

        enum Outcome: Sendable { case applied, unconfirmed(String) }
        let outcome: Outcome
        do {
            try await reach(device)
            outcome = try await Task.detached {
                let client = Client(host: host)
                defer { client.close() }
                try client.login(user: login.user, password: login.password)
                _ = try client.verifyMAC(mac)
                do {
                    try client.setConfig("Network", table: table)
                    return Outcome.applied
                } catch let error as RPCError {
                    throw error
                } catch {
                    // The device may switch address before answering: the change is likely applied.
                    return Outcome.unconfirmed(String(describing: error))
                }
            }.value
        } catch let error as RPCError {
            notices[id] = WriteNotice(kind: .failure, message: tr("The device refused the change: \(error)",
                                                                   fr: "L'appareil a refusé la modification : \(error)"))
            return
        } catch {
            notices[id] = WriteNotice(kind: .failure, message: tr("Nothing was changed: \(error)",
                                                                   fr: "Rien n'a été modifié : \(error)"))
            return
        }

        switch outcome {
        case .applied:
            notices[id] = WriteNotice(kind: .success, message: movesDevice
                ? tr("Settings applied. Looking for the device at its new address…", fr: "Réglages appliqués. Recherche de l'appareil à sa nouvelle adresse…")
                : tr("Settings applied.", fr: "Réglages appliqués."))
        case .unconfirmed(let reason):
            notices[id] = WriteNotice(kind: .warning, message: tr(
                "The device stopped answering (\(reason)). The change was probably applied; looking for the device…",
                fr: "L'appareil ne répond plus (\(reason)). La modification a sans doute été appliquée ; recherche de l'appareil…"))
        }

        if movesDevice {
            details[id] = .idle
            // Give the device time to reconfigure its interface before searching for it.
            try? await Task.sleep(for: .seconds(4))
            await scan()
        }

        // Read the device back to confirm what it now reports.
        guard let updated = self.device(id) else {
            notices[id] = WriteNotice(kind: .warning, message: tr(
                "The device was not found after the change. It may now be on another subnet: run a new search or check your network.",
                fr: "L'appareil est introuvable après la modification. Il est peut-être sur un autre sous-réseau : relancez une recherche ou vérifiez votre réseau."))
            return
        }
        await connect(to: updated, user: login.user, password: login.password)
        if case .loaded = details[id] {
            var message = movesDevice
                ? tr("Settings applied. The device answers at \(updated.ip).", fr: "Réglages appliqués. L'appareil répond à l'adresse \(updated.ip).")
                : tr("Settings applied.", fr: "Réglages appliqués.")
            switch await releaseAliasIfUnneeded(for: updated) {
            case .removed:
                message += " " + tr("The temporary address was removed from this Mac.", fr: "L'adresse temporaire a été retirée de ce Mac.")
            case .kept(let reason):
                notices[id] = WriteNotice(kind: .warning, message: message + " " + tr(
                    "The temporary address could not be removed now (\(reason)); it will be removed when you quit CamTool.",
                    fr: "L'adresse temporaire n'a pas pu être retirée maintenant (\(reason)) ; elle le sera en quittant CamTool."))
                return
            case .notNeeded:
                break
            }
            notices[id] = WriteNotice(kind: .success, message: message)
        } else {
            notices[id] = WriteNotice(kind: .warning, message: tr(
                "The settings were sent, but the device could not be read back.",
                fr: "Les réglages ont été envoyés, mais l'appareil n'a pas pu être relu."))
        }
    }
}

extension DeviceStore {
    enum AliasRelease { case notNeeded, removed, kept(String) }

    /// Removes the temporary address used to reach a device, on request.
    func removeAlias(for device: Device) async {
        guard let alias = aliasInUse[device.id] else { return }
        do {
            try await aliases.remove(alias)
            for (id, used) in aliasInUse where used == alias { aliasInUse[id] = nil }
        } catch {
            notices[device.id] = WriteNotice(kind: .failure, message: tr(
                "The temporary address was not removed: \(error)", fr: "L'adresse temporaire n'a pas été retirée : \(error)"))
        }
    }

    /// Once a device has been moved into this Mac's own subnet, the temporary address used
    /// to reach it is useless: remove it, unless another device still relies on it.
    func releaseAliasIfUnneeded(for device: Device) async -> AliasRelease {
        guard let alias = aliasInUse[device.id],
              LocalNetwork.isOnLink(device.ip, interfaces: aliases.permanentInterfaces())
        else { return .notNeeded }
        aliasInUse[device.id] = nil
        if aliasInUse.values.contains(alias) { return .notNeeded }
        do {
            try await aliases.remove(alias)
            return .removed
        } catch {
            return .kept(String(describing: error))
        }
    }
}

private extension String {
    /// Sorts "192.168.1.9" before "192.168.1.10".
    var ipSortKey: [Int] { split(separator: ".").map { Int($0) ?? 0 } }
}

#if DEBUG
extension DeviceStore {
    /// Fictitious devices for screenshots (see DemoMode).
    func loadDemo() {
        devices = DemoMode.devices
        let selected = DemoMode.devices[1]
        details[selected.id] = .loaded(DemoMode.selectedDetails)
        selection = selected.id
    }
}
#endif
