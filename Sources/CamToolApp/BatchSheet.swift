import CamToolKit
import SwiftUI

/// Settings for a multi-device setup: the admin password and a range of consecutive
/// addresses, handed out in list order (like ConfigTool).
struct BatchSheet: View {
    let devices: [Device]
    let newDevices: Set<Device.ID>
    /// False when every device is already connected in this session.
    let needsPassword: Bool
    /// Addresses that must not be handed out (other devices, this Mac).
    let otherAddresses: [String]
    let onStart: (_ items: [(device: Device, target: BatchReaddress.Target)], _ password: String, _ email: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var email = ""
    @State private var start: String
    @State private var mask: String
    @State private var gateway: String
    @State private var confirming = false

    init(devices: [Device], newDevices: Set<Device.ID>, needsPassword: Bool, otherAddresses: [String],
         onStart: @escaping (_ items: [(device: Device, target: BatchReaddress.Target)], _ password: String, _ email: String) -> Void) {
        self.devices = devices
        self.newDevices = newDevices
        self.needsPassword = needsPassword
        self.otherAddresses = otherAddresses
        self.onStart = onStart
        let first = devices.first
        _start = State(initialValue: first?.ip ?? "")
        _mask = State(initialValue: first.map { $0.netmask.isEmpty ? "255.255.255.0" : $0.netmask } ?? "255.255.255.0")
        _gateway = State(initialValue: first?.gateway ?? "")
    }

    private var hasNew: Bool { !newDevices.isEmpty }
    private var passwordProblems: [String] { hasNew ? DeviceSetup.passwordProblems(password) : [] }
    private var mismatch: Bool { hasNew && !confirmation.isEmpty && confirmation != password }
    private var emailInvalid: Bool { !email.isEmpty && !email.contains("@") }
    private var passwordReady: Bool {
        guard needsPassword else { return true }
        return hasNew ? passwordProblems.isEmpty && password == confirmation && !emailInvalid : !password.isEmpty
    }

    private var targets: Result<[String], BatchReaddress.PlanError> {
        Result {
            try BatchReaddress.addresses(count: devices.count, start: trimmed(start), mask: trimmed(mask),
                                         gateway: trimmed(gateway), avoid: otherAddresses)
        }.mapError { $0 as? BatchReaddress.PlanError ?? .invalidStart }
    }

    /// Error that prevents starting, if any.
    private var planError: String? {
        switch targets {
        case .failure(let error): return error.description
        case .success(let ips):
            if BatchReaddress.executionOrder(current: devices.map(\.ip), targets: ips) == nil {
                return tr("Two selected devices would swap addresses. Choose another start address.",
                          fr: "Deux appareils sélectionnés échangeraient leurs adresses. Choisissez une autre adresse de départ.")
            }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Set Up \(devices.count) Devices", fr: "Configurer \(devices.count) appareils")).font(.title3.weight(.semibold))
                Text(hasNew
                     ? tr("\(newDevices.count) new device(s) will be initialized, then every device gets its address.",
                          fr: "\(newDevices.count) appareil(s) neuf(s) seront initialisés, puis chaque appareil recevra son adresse.")
                     : tr("Every device gets its address, in the order below.",
                          fr: "Chaque appareil reçoit son adresse, dans l'ordre ci-dessous."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if needsPassword { passwordSection }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                field(tr("First address", fr: "Première adresse"), text: $start)
                field(tr("Subnet mask", fr: "Masque"), text: $mask)
                field(tr("Gateway", fr: "Passerelle"), text: $gateway)
            }

            preview

            HStack {
                Spacer()
                Button(tr("Cancel", fr: "Annuler"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Set Up", fr: "Configurer")) { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!passwordReady || planError != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .confirmationDialog(tr("Set up \(devices.count) devices?", fr: "Configurer \(devices.count) appareils ?"),
                            isPresented: $confirming) {
            Button(tr("Set Up", fr: "Configurer")) { submit() }
            Button(tr("Cancel", fr: "Annuler"), role: .cancel) {}
        } message: {
            Text(tr("Each device stops answering at its current address as soon as it receives its new one.",
                    fr: "Chaque appareil ne répondra plus à son adresse actuelle dès qu'il aura reçu la nouvelle."))
        }
    }

    // MARK: Password

    @ViewBuilder private var passwordSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text(tr("User", fr: "Utilisateur")).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(DeviceSetup.adminUser).font(.body.monospaced())
            }
            GridRow {
                Text(tr("Password", fr: "Mot de passe")).foregroundStyle(.secondary)
                SecureField("", text: $password).textFieldStyle(.roundedBorder)
            }
            if hasNew {
                GridRow {
                    Text(tr("Confirm", fr: "Confirmation")).foregroundStyle(.secondary)
                    SecureField("", text: $confirmation).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(tr("Recovery e-mail", fr: "E-mail de secours")).foregroundStyle(.secondary)
                    TextField("", text: $email, prompt: Text(tr("Optional", fr: "Facultatif"))).textFieldStyle(.roundedBorder)
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            if hasNew {
                ForEach(passwordProblems, id: \.self) { problem in
                    Label(problem, systemImage: "circle").foregroundStyle(.secondary)
                }
                if mismatch {
                    Label(tr("The passwords do not match.", fr: "Les mots de passe ne correspondent pas."), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                if emailInvalid {
                    Label(tr("Invalid e-mail address.", fr: "Adresse e-mail invalide."), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            Label(hasNew && devices.count > newDevices.count
                  ? tr("New devices get this password. The others must already use it, unless you are connected to them.",
                       fr: "Les appareils neufs reçoivent ce mot de passe. Les autres doivent déjà l'utiliser, sauf si vous y êtes connecté.")
                  : hasNew
                  ? tr("Keep this password safe: without it, only a hardware reset gives access back.",
                       fr: "Conservez ce mot de passe : sans lui, seule une réinitialisation matérielle redonne l'accès.")
                  : tr("Used to log in to each device you are not connected to. CamTool stops at the first refused password.",
                       fr: "Sert à se connecter à chaque appareil auquel vous n'êtes pas connecté. CamTool s'arrête au premier mot de passe refusé."),
                  systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Addresses

    @ViewBuilder private var preview: some View {
        if let planError {
            Label(planError, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .success(let ips) = targets {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(zip(devices, ips)), id: \.0.id) { device, ip in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.model.isEmpty ? device.ip : device.model).lineLimit(1)
                                Text(device.mac.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(device.ip).strikethrough(device.ip != ip).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").foregroundStyle(.tint)
                            Text(ip).fontWeight(.medium)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: 220)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField("", text: text, prompt: Text("0.0.0.0"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
        }
    }

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces) }

    private func submit() {
        guard case .success(let ips) = targets else { return }
        let items = zip(devices, ips).map { device, ip in
            (device: device, target: BatchReaddress.Target(ip: ip, mask: trimmed(mask), gateway: trimmed(gateway)))
        }
        onStart(items, password, email.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
