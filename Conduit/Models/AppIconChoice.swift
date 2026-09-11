import Foundation

enum AppIconChoice: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: Self { self }

    var title: String {
        switch self {
        case .dark: return String(localized: "Dark")
        case .light: return String(localized: "Light")
        }
    }

    var alternateIconName: String? {
        self == .light ? "Light" : nil
    }

    var previewAssetName: String {
        self == .light ? "AppIconLightPreview" : "AppIconPreview"
    }
}
