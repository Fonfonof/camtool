import Foundation

/// Message language: English by default, French when it is the Mac's preferred language.
/// `CAMTOOL_LANG=en` or `CAMTOOL_LANG=fr` forces the choice.
public enum Language: Sendable {
    case english
    case french

    public static let current = resolve(
        override: ProcessInfo.processInfo.environment["CAMTOOL_LANG"],
        preferred: Locale.preferredLanguages
    )

    static func resolve(override: String?, preferred: [String]) -> Language {
        if let override = override?.lowercased(), !override.isEmpty {
            return override.hasPrefix("fr") ? .french : .english
        }
        return preferred.first?.lowercased().hasPrefix("fr") == true ? .french : .english
    }
}

/// Returns the text in the current language.
public func tr(_ english: String, fr french: String) -> String {
    Language.current == .french ? french : english
}
