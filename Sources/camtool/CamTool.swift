import ArgumentParser
import CamToolKit
import Darwin
import Foundation

@main
struct CamTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "camtool",
        abstract: tr("Configuration tool for Dahua cameras and recorders (macOS Apple Silicon only).",
                      fr: "Outil de configuration pour caméras et enregistreurs Dahua (macOS Apple Silicon uniquement)."),
        discussion: tr("The password is prompted interactively, or read from the CAMTOOL_PASSWORD variable. Set CAMTOOL_LANG=en or fr to force the language.",
                        fr: "Le mot de passe est demandé de façon interactive, ou lu dans la variable CAMTOOL_PASSWORD. CAMTOOL_LANG=en ou fr force la langue."),
        version: "camtool 0.1.0",
        subcommands: [Discover.self, Info.self, Config.self, Call.self]
    )
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - discover

struct Discover: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: tr("Find devices on the local network.", fr: "Rechercher les appareils sur le réseau local."))

    @Option(name: .shortAndLong, help: ArgumentHelp(tr("Listening time in seconds.", fr: "Durée d'écoute en secondes.")))
    var timeout: Double = 3
    @Option(name: .shortAndLong, help: ArgumentHelp(tr("IP address of the network interface to use.", fr: "Adresse IP de l'interface à utiliser.")))
    var interface = "0.0.0.0"
    @Flag(help: ArgumentHelp(tr("JSON output.", fr: "Sortie JSON.")))
    var json = false
    @Flag(help: ArgumentHelp(tr("Include the device's raw reply (with --json).", fr: "Inclure la réponse brute de l'appareil (avec --json).")))
    var raw = false

    func run() throws {
        var devices: [Device] = []
        do {
            try Discovery.discover(timeout: timeout, interface: interface) { device in
                devices.append(device)
                if !json {
                    print([device.ip.padded(16), device.mac.padded(18), device.model.padded(26), device.serial.padded(20), device.version].joined(separator: " "))
                    fflush(stdout)
                }
            }
        } catch {
            printError(tr("network error: \(error)", fr: "erreur réseau : \(error)"))
            throw ExitCode(2)
        }

        if json {
            let list: [JSONValue] = devices.map { device in
                var fields: [String: JSONValue] = [
                    "ip": .string(device.ip), "mac": .string(device.mac), "model": .string(device.model),
                    "serial": .string(device.serial), "version": .string(device.version), "vendor": .string(device.vendor),
                    "name": .string(device.name), "netmask": .string(device.netmask), "gateway": .string(device.gateway),
                    "http_port": device.httpPort.map { .int($0) } ?? .null, "tcp_port": device.tcpPort.map { .int($0) } ?? .null,
                    "dhcp": device.dhcp.map { .bool($0) } ?? .null, "source": .string(device.source),
                ]
                if raw { fields["raw"] = .object(device.raw) }
                return .object(fields)
            }
            print(JSONValue.array(list).prettyPrinted())
        } else {
            printError(tr("\n\(devices.count) device(s) found.", fr: "\n\(devices.count) appareil(s) trouvé(s)."))
        }
    }
}

extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

// MARK: - Authenticated commands

struct ConnectionOptions: ParsableArguments {
    @Argument(help: ArgumentHelp(tr("IP address of the device.", fr: "Adresse IP de l'appareil.")))
    var host: String
    @Option(name: .shortAndLong, help: ArgumentHelp(tr("User name.", fr: "Utilisateur.")))
    var user = "admin"
    @Option(name: .shortAndLong, help: ArgumentHelp(tr("Port (default: 80 over HTTP, 37777 with --dhip).", fr: "Port (défaut : 80 en HTTP, 37777 avec --dhip).")))
    var port: UInt16?
    @Flag(help: ArgumentHelp(tr("Use the DHIP protocol over TCP instead of HTTP (experimental).", fr: "Utiliser le protocole DHIP sur TCP au lieu de HTTP (expérimental).")))
    var dhip = false
    @Option(name: .shortAndLong, help: ArgumentHelp(tr("Network timeout in seconds.", fr: "Délai réseau en secondes.")))
    var timeout: Double = 5

    /// Opens a session, runs `action`, then logs out.
    func withSession(_ action: (Client) throws -> Void) throws {
        // Never take the password as an argument: it would end up in the shell history.
        guard let password = ProcessInfo.processInfo.environment["CAMTOOL_PASSWORD"] ?? readPassword(tr("Password for \(user)@\(host): ", fr: "Mot de passe de \(user)@\(host) : ")) else {
            printError(tr("cancelled: no password entered.", fr: "annulé : aucun mot de passe saisi."))
            throw ExitCode(1)
        }
        let transport: Transport = dhip ? .dhip(port: port ?? 37777) : .http(port: port ?? 80)
        let client = Client(host: host, transport: transport, timeout: timeout)
        defer { client.close() }
        do {
            try client.login(user: user, password: password)
            try action(client)
        } catch let error as RPCError where error.isAuthentication {
            printError(tr("login refused: \(error)", fr: "connexion refusée : \(error)"))
            printError(tr("Warning: several failed attempts in a row may lock the account on the device.", fr: "Attention : plusieurs échecs successifs peuvent verrouiller le compte sur l'appareil."))
            throw ExitCode(3)
        } catch let error as RPCError {
            printError(error.description)
            throw ExitCode(4)
        } catch {
            printError(tr("cannot communicate with \(host):\(transport.port): \(error)", fr: "erreur de communication avec \(host):\(transport.port) : \(error)"))
            throw ExitCode(2)
        }
    }
}

func readPassword(_ prompt: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: tr("Model, serial number and firmware version.", fr: "Modèle, numéro de série et version du firmware."))
    @OptionGroup var connection: ConnectionOptions

    func run() throws {
        try connection.withSession { print(JSONValue.object(try $0.systemInfo()).prettyPrinted()) }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: tr("Read a configuration section (e.g. Network, NTP, Encode).", fr: "Lire une section de configuration (ex. Network, NTP, Encode)."))
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: ArgumentHelp(tr("Section name.", fr: "Nom de la section.")))
    var name: String

    func run() throws {
        try connection.withSession { print(try $0.config(name).prettyPrinted()) }
    }
}

struct Call: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: tr("Raw RPC call (protocol exploration).", fr: "Appel RPC brut (exploration du protocole)."))
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: ArgumentHelp(tr("Method, e.g. magicBox.getDeviceType.", fr: "Méthode, ex. magicBox.getDeviceType.")))
    var method: String
    @Argument(help: ArgumentHelp(tr("JSON parameters, e.g. '{\"name\": \"Network\"}'.", fr: "Paramètres JSON, ex. '{\"name\": \"Network\"}'.")))
    var params: String?

    func run() throws {
        var value: JSONValue = nil
        if let params {
            do {
                value = try JSONDecoder().decode(JSONValue.self, from: Data(params.utf8))
            } catch {
                printError(tr("invalid JSON parameters: \(error)", fr: "paramètres JSON invalides : \(error)"))
                throw ExitCode(1)
            }
        }
        try connection.withSession { print(JSONValue.object(try $0.request(method, params: value)).prettyPrinted()) }
    }
}
