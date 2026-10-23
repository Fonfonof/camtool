import CamToolKit
import SwiftUI

struct ContentView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(store.devices, selection: $store.selection) { device in
                DeviceRow(device: device)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .overlay { sidebarPlaceholder }
            .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            if let device = store.device(store.selection) {
                DeviceDetailView(device: device)
                    .id(device.id)
            } else {
                ContentUnavailableView(
                    tr("No Device Selected", fr: "Aucun appareil sélectionné"),
                    systemImage: "video",
                    description: Text(tr("Select a device in the list.", fr: "Sélectionnez un appareil dans la liste."))
                )
            }
        }
        .toolbar {
            ToolbarItem {
                if store.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await store.scan() } } label: {
                        Label(tr("Scan Network", fr: "Rechercher les appareils"), systemImage: "arrow.clockwise")
                    }
                    .help(tr("Scan the local network (⌘R)", fr: "Rechercher sur le réseau local (⌘R)"))
                }
            }
        }
    }

    @ViewBuilder private var sidebarPlaceholder: some View {
        if store.devices.isEmpty {
            if store.isScanning {
                ProgressView(tr("Scanning…", fr: "Recherche en cours…"))
            } else if let error = store.scanError {
                ContentUnavailableView(
                    tr("Scan Failed", fr: "Échec de la recherche"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ContentUnavailableView(
                    tr("No Devices Found", fr: "Aucun appareil trouvé"),
                    systemImage: "video.slash",
                    description: Text(tr(
                        "Check that this Mac is on the same network as the cameras and that the firewall allows CamTool.",
                        fr: "Vérifiez que ce Mac est sur le même réseau que les caméras et que le pare-feu autorise CamTool."
                    ))
                )
            }
        }
    }

    private var footer: some View {
        Text(tr("\(store.devices.count) device(s)", fr: "\(store.devices.count) appareil(s)"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

struct DeviceRow: View {
    @Environment(DeviceStore.self) private var store
    let device: Device

    var body: some View {
        HStack(spacing: 10) {
            DeviceIcon(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.model.isEmpty ? device.ip : device.model)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(device.ip)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !LocalNetwork.isOnLink(device.ip) {
                        Image(systemName: "network")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .help(tr("On another subnet", fr: "Sur un autre sous-réseau"))
                    }
                }
            }
            Spacer(minLength: 4)
            if store.needsInitialization(device) {
                Text(tr("New", fr: "Neuf"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: .capsule)
                    .foregroundStyle(Color.accentColor)
                    .help(tr("Not initialized", fr: "Non initialisé"))
            }
        }
        .padding(.vertical, 3)
    }
}
