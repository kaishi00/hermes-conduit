import SwiftUI

// MARK: - Inbox semantic surfaces

extension ShapeStyle where Self == Color {
    static var conduitCanvas: Color { .conduitCanvasColor }
    static var conduitRaisedSurface: Color { .conduitRaisedSurfaceColor }
    static var conduitPrimaryText: Color { .conduitPrimaryTextColor }
    static var conduitSecondaryText: Color { .conduitSecondaryTextColor }
    static var conduitSeparator: Color { .conduitSeparatorColor }
    static var conduitPrimaryAction: Color { .conduitPrimaryActionColor }
}

extension Color {
    static let conduitCanvasColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1) // #111214
            : UIColor(red: 0.980, green: 0.980, blue: 0.973, alpha: 1) // #FAFAF8
    })

    static let conduitRaisedSurfaceColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.125, green: 0.133, blue: 0.145, alpha: 1) // #202225
            : UIColor(red: 0.941, green: 0.945, blue: 0.937, alpha: 1) // #F0F1EF
    })

    static let conduitPrimaryTextColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.957, green: 0.957, blue: 0.949, alpha: 1) // #F4F4F2
            : UIColor(red: 0.094, green: 0.098, blue: 0.106, alpha: 1) // #18191B
    })

    static let conduitSecondaryTextColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.667, green: 0.686, blue: 0.710, alpha: 1) // #AAAFB5
            : UIColor(red: 0.420, green: 0.435, blue: 0.451, alpha: 1) // #6B6F73
    })

    static let conduitSeparatorColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.196, green: 0.208, blue: 0.227, alpha: 1) // #32353A
            : UIColor(red: 0.894, green: 0.902, blue: 0.890, alpha: 1) // #E4E6E3
    })

    static let conduitPrimaryActionColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.957, green: 0.957, blue: 0.949, alpha: 1)
            : UIColor(red: 0.094, green: 0.098, blue: 0.106, alpha: 1)
    })

    static let conduitPrimaryActionForegroundColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.094, green: 0.098, blue: 0.106, alpha: 1)
            : UIColor(red: 0.980, green: 0.980, blue: 0.973, alpha: 1)
    })
}

enum ConduitInboxMetrics {
    static let phoneHorizontalInset: CGFloat = 20
    static let narrowColumnHorizontalInset: CGFloat = 16
    static let profileRailSizePhone: CGFloat = 86
    static let profileRailSizeNarrow: CGFloat = 64
    static let profileShelfUnpinnedSize: CGFloat = 48
    static let sessionArtworkSize: CGFloat = 40
    static let rowMinimumHeight: CGFloat = 58
    static let rowArtworkTextGap: CGFloat = 12
}

/// Flat inbox canvas. Prefer this over `ConduitBackdrop` on redesigned routes.
struct ConduitCanvasBackground: View {
    var body: some View {
        Color.conduitCanvas
            .ignoresSafeArea()
    }
}

extension View {
    /// Quiet raised surface for inputs and grouped information.
    func conduitRaisedSurface(cornerRadius: CGFloat) -> some View {
        self.background(
            Color.conduitRaisedSurface,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    /// Primary filled control (near-black / near-white by appearance).
    func conduitPrimaryActionControl(cornerRadius: CGFloat = 22) -> some View {
        self
            .foregroundStyle(Color.conduitPrimaryActionForegroundColor)
            .background(
                Color.conduitPrimaryAction,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}
