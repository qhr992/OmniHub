import Foundation

/// The interface language, chosen in Settings › General (English unless
/// changed; it does not follow the system language).
///
/// Texts are written in English in the code and looked up with `L(…)` in
/// `zh-Hans.lproj/Localizable.strings`, keyed by the English text; a text
/// with no translation stays English. The language is fixed for the life of
/// the process — a change takes effect on the next launch — and is also
/// handed to AppKit as the app's `AppleLanguages`, so the parts macOS draws
/// (text field menus, open and save panels) follow it.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    static let prefKey = "app.language"

    /// Shown in the language menu, each in its own language.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    /// For dates written out with month and weekday names.
    var locale: Locale { Locale(identifier: self == .chinese ? "zh_Hans" : "en_US") }

    /// Column heads of the month grid, Monday first.
    var weekdayInitials: [String] {
        self == .chinese ? ["一", "二", "三", "四", "五", "六", "日"] : ["M", "T", "W", "T", "F", "S", "S"]
    }

    /// The language picked in Settings.
    static var chosen: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: prefKey) ?? "") ?? .english
    }

    /// The language this process shows.
    static private(set) var current: AppLanguage = .english

    private static var table: Bundle?

    /// Call first thing at launch. Self-tests run in English, since they
    /// look controls up by their English titles — except the one that
    /// checks the Chinese interface.
    static func start(arguments: [String]) {
        let isSelfTest = arguments.contains { $0.hasSuffix("-selftest") }
        let isChineseCheck = arguments.contains("--l10n-selftest")
        current = isChineseCheck ? .chinese : isSelfTest ? .english : chosen
        if !isSelfTest {
            UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
        }
        table = current == .english ? nil
            : Bundle.main.path(forResource: current.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    static func text(_ key: String) -> String {
        guard let table else { return key }
        return table.localizedString(forKey: key, value: key, table: nil)
    }

    /// Whether `text` is an English text the current language translates
    /// (test hook: such a text on screen was not passed through `L`).
    static func hasTranslation(_ text: String) -> Bool {
        guard let table else { return false }
        let missing = "\u{0}"
        let value = table.localizedString(forKey: text, value: missing, table: nil)
        return value != missing && value != text
    }
}

/// The interface text `key` (written in English) in the current language.
func L(_ key: String) -> String {
    AppLanguage.text(key)
}

/// `key` is a format (`%@`, `%d`, `%.1f` …) filled in with `arguments`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: AppLanguage.text(key), arguments: arguments)
}
