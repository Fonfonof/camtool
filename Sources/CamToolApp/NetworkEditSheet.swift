import CamToolKit
import SwiftUI

struct NetworkEditSheet: View {
    let device: Device
    let original: NetworkSettings
    /// Addresses of the other devices found on the network, to catch conflicts.
    let otherAddresses: [String]
    let onApply: (NetworkSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: NetworkSettings
    @State private var dns1: String
    @State private var dns2: String
    @State private var confirming = false

    init(device: Device, original: NetworkSettings, otherAddresses: [String], onApply: @escaping (NetworkSettings) -> Void) {
        self.device = device
        self.original = original
        self.otherAddresses = otherAddresses
        self.onApply = onApply
        _draft = State(initialValue: original)
        _dns1 = State(initialValue: original.dns.first ?? "")
        _dns2 = State(initialValue: original.dns.dropFirst().first ?? "")
    }

    private var edited: NetworkSettings {
        var settings = draft
        settings.dns = [dns1, dns2].map { $0.trimmingCharacters(in: .whitespaces) }
        settings.ip = settings.ip.trimmingCharacters(in: .whitespaces)
        settings.mask = settings.mask.trimmingCharacters(in: .whitespaces)
        settings.gateway = settings.gateway.trimmingCharacters(in: .whitespaces)
        return settings
    }

    private var errors: [String] { edited.validationErrors() }

    private var warnings: [String] {
        let settings = edited
        var warnings: [String] = []
        if settings.dhcp && !original.dhcp {
            warnings.append(tr("The device will take an address from your DHCP server. CamTool will search for it afterwards.",
                               fr: "L'appareil prendra une adresse auprès de votre serveur DHCP. CamTool le recherchera ensuite."))
        }
        guard !settings.dhcp else { return warnings }
        if settings.ip != original.ip && otherAddresses.contains(settings.ip) {
            warnings.append(tr("Another device found on the network already uses \(settings.ip).",
                               fr: "Un autre appareil trouvé sur le réseau utilise déjà \(settings.ip)."))
        }
        if let new = IPv4(settings.ip), let old = IPv4(original.ip), let mask = IPv4(original.mask),
           !new.isInSubnet(of: old, mask: mask) {
            warnings.append(tr("This address is outside the current subnet: your Mac may no longer reach the device.",
                               fr: "Cette adresse sort du sous-réseau actuel : votre Mac risque de ne plus joindre l'appareil."))
        }
        return warnings
    }

    private var changes: [(label: String, old: String, new: String)] {
        let settings = edited
        let mode = { (dhcp: Bool) in dhcp ? "DHCP" : tr("Static", fr: "Statique") }
        var changes: [(String, String, String)] = []
        if settings.dhcp != original.dhcp { changes.append((tr("Addressing", fr: "Adressage"), mode(original.dhcp), mode(settings.dhcp))) }
        if !settings.dhcp {
            if settings.ip != original.ip { changes.append((tr("IP address", fr: "Adresse IP"), original.ip, settings.ip)) }
            if settings.mask != original.mask { changes.append((tr("Subnet mask", fr: "Masque"), original.mask, settings.mask)) }
            if settings.gateway != original.gateway { changes.append((tr("Gateway", fr: "Passerelle"), original.gateway, settings.gateway)) }
        }
        // Compare what will actually be written (see NetworkSettings.applied(to:)).
        let newDNS = settings.dns.filter { !$0.isEmpty }
        let written = newDNS.count == 1 ? [newDNS[0], newDNS[0]] : newDNS
        if !newDNS.isEmpty && written != original.dns {
            changes.append(("DNS", original.dns.filter { !$0.isEmpty }.joined(separator: ", "), newDNS.joined(separator: ", ")))
        }
        return changes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Network Settings", fr: "Réglages réseau")).font(.title3.weight(.semibold))
                Text("\(device.model)  ·  \(device.ip)").font(.callout).foregroundStyle(.secondary)
            }

            Picker(selection: $draft.dhcp) {
                Text(tr("Static", fr: "Statique")).tag(false)
                Text("DHCP").tag(true)
            } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                field(tr("IP address", fr: "Adresse IP"), text: $draft.ip, disabled: draft.dhcp)
                field(tr("Subnet mask", fr: "Masque"), text: $draft.mask, disabled: draft.dhcp)
                field(tr("Gateway", fr: "Passerelle"), text: $draft.gateway, disabled: draft.dhcp)
                Divider().gridCellColumns(2)
                field(tr("Primary DNS", fr: "DNS principal"), text: $dns1, disabled: false)
                field(tr("Secondary DNS", fr: "DNS secondaire"), text: $dns2, disabled: false)
            }

            messages

            HStack {
                Spacer()
                Button(tr("Cancel", fr: "Annuler"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Apply", fr: "Appliquer")) {
                    if edited.dhcp != original.dhcp || edited.ip != original.ip { confirming = true } else { apply() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!errors.isEmpty || changes.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .confirmationDialog(confirmationTitle, isPresented: $confirming) {
            Button(tr("Apply", fr: "Appliquer")) { apply() }
            Button(tr("Cancel", fr: "Annuler"), role: .cancel) {}
        } message: {
            Text(tr("The device will stop answering at \(original.ip) as soon as the change is applied.",
                    fr: "L'appareil ne répondra plus à l'adresse \(original.ip) dès que la modification sera appliquée."))
        }
    }

    private var confirmationTitle: String {
        edited.dhcp
            ? tr("Switch \(device.ip) to DHCP?", fr: "Passer \(device.ip) en DHCP ?")
            : tr("Change the address from \(original.ip) to \(edited.ip)?", fr: "Changer l'adresse \(original.ip) en \(edited.ip) ?")
    }

    @ViewBuilder private var messages: some View {
        let errors = errors, warnings = warnings, changes = changes
        if !errors.isEmpty || !warnings.isEmpty || !changes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(errors, id: \.self) { message in
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                ForEach(warnings, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if errors.isEmpty {
                    ForEach(changes, id: \.label) { change in
                        Label {
                            Text(tr("\(change.label): ", fr: "\(change.label) : ")).foregroundStyle(.secondary)
                                + Text(change.old.isEmpty ? "—" : change.old).strikethrough().foregroundStyle(.secondary)
                                + Text("  →  \(change.new)")
                        } icon: {
                            Image(systemName: "arrow.right.circle.fill").foregroundStyle(.tint)
                        }
                    }
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, text: Binding<String>, disabled: Bool) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField("", text: text, prompt: Text("0.0.0.0"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
        }
    }

    private func apply() {
        onApply(edited)
        dismiss()
    }
}
