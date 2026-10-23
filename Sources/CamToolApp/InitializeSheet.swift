import CamToolKit
import SwiftUI

/// First-time setup of a factory-new device: choose the admin password.
struct InitializeSheet: View {
    let device: Device
    let onInitialize: (_ password: String, _ email: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var email = ""
    @FocusState private var passwordFocused: Bool

    private var problems: [String] { DeviceSetup.passwordProblems(password) }
    private var mismatch: Bool { !confirmation.isEmpty && confirmation != password }
    private var emailInvalid: Bool { !email.isEmpty && !email.contains("@") }
    private var canSubmit: Bool { problems.isEmpty && password == confirmation && !emailInvalid }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                DeviceIcon(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Initialize Device", fr: "Initialiser l'appareil")).font(.title3.weight(.semibold))
                    Text("\(device.model)  ·  \(device.ip)").font(.callout).foregroundStyle(.secondary)
                }
            }

            Text(tr("This device is new and has no password yet. Choose the password of the \"admin\" account.",
                    fr: "Cet appareil est neuf et n'a pas encore de mot de passe. Choisissez celui du compte « admin »."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(tr("User", fr: "Utilisateur")).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(DeviceSetup.adminUser).font(.body.monospaced())
                }
                GridRow {
                    Text(tr("Password", fr: "Mot de passe")).foregroundStyle(.secondary)
                    SecureField("", text: $password).textFieldStyle(.roundedBorder).focused($passwordFocused)
                }
                GridRow {
                    Text(tr("Confirm", fr: "Confirmation")).foregroundStyle(.secondary)
                    SecureField("", text: $confirmation).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(tr("Recovery e-mail", fr: "E-mail de secours")).foregroundStyle(.secondary)
                    TextField("", text: $email, prompt: Text(tr("Optional", fr: "Facultatif"))).textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                rule(tr("8 to 32 characters", fr: "8 à 32 caractères"), ok: (8...32).contains(password.count))
                rule(tr("At least two of: uppercase, lowercase, digits, symbols", fr: "Au moins deux types : majuscules, minuscules, chiffres, symboles"),
                     ok: !password.isEmpty && !problems.contains { $0.hasPrefix(tr("At least", fr: "Au moins")) })
                rule(tr("No ' \" ; : & characters", fr: "Pas de caractères ' \" ; : &"),
                     ok: !password.isEmpty && !password.contains(where: "'\";:&".contains))
                if mismatch {
                    Label(tr("The passwords do not match.", fr: "Les mots de passe ne correspondent pas."), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                if emailInvalid {
                    Label(tr("Invalid e-mail address.", fr: "Adresse e-mail invalide."), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)

            Label(tr("Keep this password safe: without it, only a hardware reset gives access back.",
                     fr: "Conservez ce mot de passe : sans lui, seule une réinitialisation matérielle redonne l'accès."),
                  systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(tr("Cancel", fr: "Annuler"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Initialize", fr: "Initialiser")) {
                    onInitialize(password, email.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { passwordFocused = true }
    }

    private func rule(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ok ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
    }
}
