import Foundation

enum AppLocalization {
    static var locale: Locale {
        let language = UserDefaults.standard.string(forKey: "appUiLanguage") ?? "system"
        return language == "system" ? .current : Locale(identifier: language)
    }

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, locale: locale)
    }
}
