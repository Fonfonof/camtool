import CamToolKit
import SwiftUI

struct DeviceDetailView: View {
    @Environment(DeviceStore.self) private var store
    let device: Device
    @State private var showingLogin = false
    @State private var editingNetwork = false
    @State private var initializing = false

    private var state: DetailState { store.detailState(for: device) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                content
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.3), value: store.notices[device.id])
        }
        .navigationTitle("")
        .sheet(isPresented: $showingLogin) {
            LoginSheet(device: device) { user, password in
                Task { await store.connect(to: device, user: user, password: password) }
            }
        }
        .sheet(isPresented: $initializing) {
            InitializeSheet(device: device) { password, email in
                Task { await store.initialize(device, password: password, email: email) }
            }
        }
        .sheet(isPresented: $editingNetwork) {
            if case .loaded(let details) = state, let settings = NetworkSettings(config: details.network) {
                NetworkEditSheet(
                    device: device,
                    original: settings,
                    otherAddresses: store.devices.filter { $0.id != device.id }.map(\.ip)
                ) { edited in
                    Task { await store.apply(edited, to: device, baseConfig: details.network) }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            DeviceIcon(size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.model.isEmpty ? device.ip : device.model)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text([device.ip, device.mac.uppercased()].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let url = webURL {
                Link(destination: url) {
                    Image(systemName: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(tr("Open the web interface", fr: "Ouvrir l'interface web"))
            }
            connectButton
        }
    }

    @ViewBuilder private var connectButton: some View {
        switch state {
        case .loaded:
            Label(tr("Connected", fr: "Connecté"), systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle())
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            Button(tr("Disconnect", fr: "Déconnecter")) { store.disconnect(device) }
                .buttonStyle(.bordered)
                .controlSize(.large)
        case .loading:
            ProgressView().controlSize(.small).frame(width: 110)
        case .idle, .failed:
            if store.needsInitialization(device) {
                // Discovery can lag behind: keep a way to log in anyway.
                Button(tr("Connect", fr: "Se connecter")) { showingLogin = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button(tr("Initialize…", fr: "Initialiser…")) { initializing = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button(tr("Connect", fr: "Se connecter")) { showingLogin = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    private var webURL: URL? {
        let port = device.httpPort.map { $0 == 80 ? "" : ":\($0)" } ?? ""
        return URL(string: "http://\(device.ip)\(port)")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if store.needsInitialization(device), case .idle = state {
            Notice(systemImage: "sparkles", tint: .accentColor,
                   title: tr("New device", fr: "Appareil neuf"),
                   message: tr("This device has not been initialized yet. Choose its admin password to start using it.",
                               fr: "Cet appareil n'a pas encore été initialisé. Choisissez son mot de passe admin pour commencer."))
        }
        if store.duplicateAddresses.contains(device.ip) {
            Notice(systemImage: "exclamationmark.triangle.fill", tint: .orange,
                   title: tr("Address used by several devices", fr: "Adresse utilisée par plusieurs appareils"),
                   message: tr("Several devices answer at \(device.ip) (often new cameras with the factory address). Connect them one at a time, or change their address one by one, so that CamTool talks to the right one.",
                               fr: "Plusieurs appareils répondent à \(device.ip) (souvent des caméras neuves à l'adresse d'usine). Branchez-les un par un, ou changez leur adresse une par une, pour que CamTool s'adresse au bon."))
        }
        if let alias = store.aliasInUse[device.id] {
            Notice(systemImage: "point.3.connected.trianglepath.dotted", tint: .blue,
                   title: tr("Temporary address on this Mac", fr: "Adresse temporaire sur ce Mac"),
                   message: tr("\(alias.address) was added to \(alias.interface) to reach this device. It is removed when no longer needed or when you quit CamTool.",
                               fr: "\(alias.address) a été ajoutée à \(alias.interface) pour joindre cet appareil. Elle est retirée dès qu'elle ne sert plus, ou en quittant CamTool."),
                   action: (tr("Remove", fr: "Retirer"), { Task { await store.removeAlias(for: device) } }))
        } else if !LocalNetwork.isOnLink(device.ip), case .idle = state {
            Notice(systemImage: "network", tint: .blue,
                   title: tr("Different subnet", fr: "Autre sous-réseau"),
                   message: tr("This device is not on your Mac's subnet. CamTool will add a temporary address to your Mac to reach it (macOS asks for your administrator password).",
                               fr: "Cet appareil n'est pas sur le sous-réseau de votre Mac. CamTool ajoutera une adresse temporaire à votre Mac pour le joindre (macOS demande votre mot de passe administrateur)."))
        }
        if store.applying.contains(device.id) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(tr("Applying network settings…", fr: "Application des réglages réseau…"))
            }
            .font(.callout)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
        }
        if let notice = store.notices[device.id] {
            switch notice.kind {
            case .success:
                Notice(systemImage: "checkmark.circle.fill", tint: .green, title: tr("Done", fr: "Terminé"), message: notice.message,
                       onClose: { store.dismissNotice(for: device.id) })
            case .warning:
                Notice(systemImage: "exclamationmark.triangle.fill", tint: .orange, title: tr("Check the device", fr: "Vérifiez l'appareil"), message: notice.message,
                       onClose: { store.dismissNotice(for: device.id) })
            case .failure:
                Notice(systemImage: "xmark.octagon.fill", tint: .red, title: tr("Not applied", fr: "Non appliqué"), message: notice.message,
                       onClose: { store.dismissNotice(for: device.id) })
            }
        }
        switch state {
        case .loaded(let details):
            LoadedCards(details: details, onEditNetwork: store.applying.contains(device.id) ? nil : { editingNetwork = true })
        case .failed(let message, let isAuthentication):
            Notice(
                systemImage: "exclamationmark.triangle.fill", tint: .orange,
                title: isAuthentication ? tr("Login refused", fr: "Connexion refusée") : tr("Connection failed", fr: "Échec de connexion"),
                message: isAuthentication
                    ? message + "\n" + tr("Several failed attempts in a row may lock the account on the device.",
                                          fr: "Plusieurs échecs successifs peuvent verrouiller le compte sur l'appareil.")
                    : message
            )
            discoveryCard
        default:
            discoveryCard
        }
    }

    private var discoveryCard: some View {
        Card(tr("Overview", fr: "Aperçu"), systemImage: "dot.radiowaves.left.and.right") {
            InfoRow(tr("Serial number", fr: "Numéro de série"), device.serial)
            InfoRow(tr("Firmware", fr: "Firmware"), device.version)
            InfoRow(tr("Subnet mask", fr: "Masque"), device.netmask)
            InfoRow(tr("Gateway", fr: "Passerelle"), device.gateway)
            InfoRow(tr("Addressing", fr: "Adressage"), device.dhcp.map { $0 ? "DHCP" : tr("Static", fr: "Statique") })
            InfoRow(tr("Ports", fr: "Ports"), [device.httpPort.map { "HTTP \($0)" }, device.tcpPort.map { "TCP \($0)" }]
                .compactMap { $0 }.joined(separator: "  ·  "))
        }
    }
}

private struct LoadedCards: View {
    let details: DeviceDetails
    let onEditNetwork: (() -> Void)?

    var body: some View {
        let info = details.info
        let network = details.network
        let iface = network["DefaultInterface"]?.stringValue ?? "eth0"
        let eth = network[iface]

        Card(tr("Device", fr: "Appareil"), systemImage: "video") {
            InfoRow(tr("Serial number", fr: "Numéro de série"), info["serialNumber"]?.stringValue)
            InfoRow(tr("Firmware", fr: "Firmware"), info["Version"]?.stringValue)
            InfoRow(tr("Build date", fr: "Date du firmware"), info["BuildDate"]?.stringValue)
            InfoRow(tr("Firmware model", fr: "Modèle firmware"), info["updateSerial"]?.stringValue)
            InfoRow(tr("Web interface", fr: "Interface web"), info["WebVersion"]?.stringValue)
            InfoRow(tr("Hardware", fr: "Matériel"), [info["hardwareVersion"]?.stringValue, info["processor"]?.stringValue]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
            InfoRow(tr("Security baseline", fr: "Socle de sécurité"), info["SecurityBaseLineVersion"]?.stringValue)
        }

        Card(tr("Network", fr: "Réseau"), systemImage: "network",
             action: onEditNetwork.map { (tr("Change IP…", fr: "Modifier l'IP…"), $0) }) {
            InfoRow(tr("Host name", fr: "Nom d'hôte"), network["Hostname"]?.stringValue)
            InfoRow(tr("IP address", fr: "Adresse IP"), eth?["IPAddress"]?.stringValue)
            InfoRow(tr("Subnet mask", fr: "Masque"), eth?["SubnetMask"]?.stringValue)
            InfoRow(tr("Gateway", fr: "Passerelle"), eth?["DefaultGateway"]?.stringValue)
            InfoRow("DNS", eth?["DnsServers"].flatMap { value -> String? in
                guard case .array(let servers) = value else { return nil }
                return servers.compactMap(\.stringValue).filter { !$0.isEmpty }.joined(separator: "  ·  ")
            })
            InfoRow(tr("Addressing", fr: "Adressage"), eth?["DhcpEnable"]?.boolValue.map { $0 ? "DHCP" : tr("Static", fr: "Statique") })
            InfoRow("MTU", eth?["MTU"]?.intValue.map(String.init))
        }
    }
}

// MARK: - Building blocks

/// Rounded card with a small title, holding label/value rows.
struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    let action: (label: String, perform: () -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, action: (label: String, perform: () -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let action {
                    Button(action.label, action: action.perform)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                content
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

/// One label/value line; hidden when the value is missing so firmware differences leave no gaps.
struct InfoRow: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.leading)
                Text(value)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
    }
}

struct Notice: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    var action: (label: String, perform: () -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.label, action: action.perform)
                    .controlSize(.small)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(tr("Dismiss", fr: "Fermer"))
            }
        }
        .padding(16)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 14))
        .transition(.opacity)
    }
}

struct DeviceIcon: View {
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: "video.fill")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.accentColor.gradient, in: .rect(cornerRadius: size * 0.28))
    }
}

/// Small colored dot followed by the label, for connection status.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 8))
            configuration.title
        }
    }
}
