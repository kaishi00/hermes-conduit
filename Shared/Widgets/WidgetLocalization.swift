import Foundation

enum WidgetLocalization {
    /// The bundle for a pinned app language, or the main bundle when
    /// following the system.
    static func bundle(language: String) -> Bundle {
        guard language != "system", !language.isEmpty,
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    static func string(_ key: String, language: String) -> String {
        guard language != "system", !language.isEmpty,
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func title(_ copy: WidgetTitleCopy, language: String) -> String {
        switch copy {
        case .cached(let value): value
        case .openConduit: string("Open Conduit", language: language)
        case .openConduitToRefresh: string("Open Conduit to refresh", language: language)
        case .resumeChat: string("Resume chat", language: language)
        }
    }
}
