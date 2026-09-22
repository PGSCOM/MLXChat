import Foundation

/// How the model's replies should read. `.normal` carries no instruction —
/// no reason to spend context telling the model to behave the default way.
enum ResponseStyle: String, CaseIterable, Hashable, Sendable {
    case normal, conciso, explicativo, formal

    var label: String {
        switch self {
        case .normal: "Normal"
        case .conciso: "Conciso"
        case .explicativo: "Explicativo"
        case .formal: "Formal"
        }
    }

    var instruction: String {
        switch self {
        case .normal: ""
        case .conciso: "Responde de forma breve y directa, sin rodeos."
        case .explicativo: "Explica tu razonamiento paso a paso, con detalle."
        case .formal: "Responde en un registro formal y profesional."
        }
    }
}

/// The user's profile, applied to every conversation's system prompt.
/// `UserDefaults`-backed like `AppSettings` — small strings, no SwiftData
/// model needed.
enum Personalization {
    private static let nameKey = "personalizeName"
    private static let contextKey = "personalizeContext"
    private static let preferencesKey = "personalizePreferences"
    private static let styleKey = "personalizeStyle"

    static var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    static var context: String {
        get { UserDefaults.standard.string(forKey: contextKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: contextKey) }
    }

    static var preferences: String {
        get { UserDefaults.standard.string(forKey: preferencesKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: preferencesKey) }
    }

    static var style: ResponseStyle {
        get { UserDefaults.standard.string(forKey: styleKey).flatMap(ResponseStyle.init) ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    /// Prepended to the system prompt. Empty when nothing is filled in — a
    /// phone-sized model can't afford to pay context for a blank preamble.
    static func preamble(style: ResponseStyle) -> String {
        var lines: [String] = []
        if !name.isEmpty { lines.append("El usuario se llama \(name).") }
        if !context.isEmpty { lines.append("Sobre el usuario: \(context)") }
        if !preferences.isEmpty { lines.append("Preferencias: \(preferences)") }
        if !style.instruction.isEmpty { lines.append(style.instruction) }
        return lines.joined(separator: "\n")
    }
}
