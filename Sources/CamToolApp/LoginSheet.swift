import CamToolKit
import SwiftUI

struct LoginSheet: View {
    let device: Device
    let onConnect: (_ user: String, _ password: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var user = "admin"
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Log in to \(device.model.isEmpty ? device.ip : device.model)",
                    fr: "Connexion à \(device.model.isEmpty ? device.ip : device.model)"))
                .font(.headline)
            Text(device.ip)
                .foregroundStyle(.secondary)

            Form {
                TextField(tr("User", fr: "Utilisateur"), text: $user)
                SecureField(tr("Password", fr: "Mot de passe"), text: $password)
                    .focused($passwordFocused)
            }

            Label(tr("A single attempt is made. Several failures in a row may lock the account on the device.",
                     fr: "Une seule tentative est faite. Plusieurs échecs successifs peuvent verrouiller le compte sur l'appareil."),
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(tr("Cancel", fr: "Annuler"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Connect", fr: "Se connecter")) {
                    onConnect(user, password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(user.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { passwordFocused = true }
    }
}
