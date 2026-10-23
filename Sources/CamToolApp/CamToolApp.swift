import AppKit
import CamToolKit
import SwiftUI

@main
struct CamToolApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = DeviceStore()

    var body: some Scene {
        WindowGroup("CamTool") {
            ContentView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 460)
                .task { await store.scan() }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(tr("About CamTool", fr: "À propos de CamTool")) { AppDelegate.showAbout() }
            }
            CommandGroup(after: .newItem) {
                Button(tr("Scan Network", fr: "Rechercher les appareils")) {
                    Task { await store.scan() }
                }
                .keyboardShortcut("r")
                .disabled(store.isScanning)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Task { @MainActor in await AliasManager.shared.cleanUpLeftovers() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Removes the temporary addresses before quitting. If that fails (e.g. the password prompt
    /// is cancelled), quit anyway: the aliases are recorded and removed at the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AliasManager.shared.active.isEmpty else { return .terminateNow }
        Task { @MainActor in
            try? await AliasManager.shared.removeAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor static func showAbout() {
        let credits = tr(
            "Configuration tool for Dahua cameras and recorders.\nIndependent project, not affiliated with Dahua Technology.\nMIT License — provided without any warranty.",
            fr: "Outil de configuration pour caméras et enregistreurs Dahua.\nProjet indépendant, non affilié à Dahua Technology.\nLicence MIT — fourni sans aucune garantie."
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: credits, attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }
}
