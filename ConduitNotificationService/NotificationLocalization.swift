//
//  NotificationLocalization.swift
//  ConduitNotificationService
//
//  Notifications speak the language Conduit is set to (#1144). The app
//  mirrors its App Language into the notifications App Group ("system" or a
//  localization identifier); the extension carries the app's String Catalog
//  and resolves every string through it, like the app's own AppLocalization.
//

import Foundation

enum AppLocalization {
    /// The pinned localization, or nil to follow the system.
    static var languageIdentifier: String?

    static var bundle: Bundle? {
        guard let identifier = languageIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    static func string(_ keyAndValue: String.LocalizationValue) -> String {
        guard let identifier = languageIdentifier, let bundle else {
            return String(localized: keyAndValue, locale: .current)
        }
        return String(localized: keyAndValue, bundle: bundle, locale: Locale(identifier: identifier))
    }

    /// Pins the language the app published, if this build ships it.
    static func adopt(appLanguage: String?) {
        guard let appLanguage, appLanguage != "system", !appLanguage.isEmpty,
              Bundle.main.path(forResource: appLanguage, ofType: "lproj") != nil else {
            languageIdentifier = nil
            return
        }
        languageIdentifier = appLanguage
    }
}
