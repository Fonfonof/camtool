import CamToolKit
import SwiftUI

/// Shown when several devices are selected: sets them all up in one go, then shows
/// how each one went.
struct BatchView: View {
    @Environment(DeviceStore.self) private var store
    @State private var settingUp = false

    var body: some View {
        let devices = store.selectedDevices
        let newCount = devices.filter(store.needsInitialization).count
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 16) {
                    DeviceIcon(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("\(devices.count) devices selected", fr: "\(devices.count) appareils sélectionnés"))
                            .font(.title2.weight(.semibold))
                        Text(newCount == 0
                             ? tr("Give them consecutive addresses.", fr: "Donnez-leur des adresses qui se suivent.")
                             : tr("\(newCount) new: they will be initialized, then addressed.",
                                  fr: "\(newCount) neuf(s) : ils seront initialisés, puis adressés."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if store.isBatchRunning {
                        ProgressView().controlSize(.small).frame(width: 110)
                    } else {
                        Button(tr("Set Up…", fr: "Configurer…")) { settingUp = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }

                Card(tr("Devices", fr: "Appareils"), systemImage: "video") {
                    ForEach(devices) { device in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.model.isEmpty ? device.ip : device.model).lineLimit(1)
                                Text(device.mac.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(device.ip).monospacedDigit().foregroundStyle(.secondary)
                            BatchStepLabel(step: store.batchSteps[device.id], isNew: store.needsInitialization(device))
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("")
        .sheet(isPresented: $settingUp) {
            BatchSheet(
                devices: devices,
                newDevices: Set(devices.filter(store.needsInitialization).map(\.id)),
                needsPassword: devices.contains { store.needsInitialization($0) || !store.isConnected($0) },
                otherAddresses: store.devices.filter { !store.selection.contains($0.id) }.map(\.ip)
                    + LocalNetwork.interfaces().map(\.address)
            ) { items, password, email in
                Task { await store.runBatch(items, password: password, email: email) }
            }
        }
    }
}

private struct BatchStepLabel: View {
    let step: BatchStep?
    let isNew: Bool

    var body: some View {
        switch step {
        case nil:
            if isNew {
                Text(tr("New", fr: "Neuf"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: .capsule)
                    .foregroundStyle(Color.accentColor)
            }
        case .waiting:
            Label(tr("Waiting", fr: "En attente"), systemImage: "clock").foregroundStyle(.secondary)
        case .initializing:
            progress(tr("Initializing…", fr: "Initialisation…"))
        case .addressing:
            progress(tr("Addressing…", fr: "Adressage…"))
        case .done(let ip, let confirmed):
            Label(confirmed ? ip : tr("\(ip) (unconfirmed)", fr: "\(ip) (non confirmé)"),
                  systemImage: confirmed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(confirmed ? .green : .orange)
                .monospacedDigit()
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .skipped(let message):
            Label(message, systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text)
        }
    }
}
