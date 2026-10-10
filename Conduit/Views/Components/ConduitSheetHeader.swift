import SwiftUI

/// Shared title and close affordance for full-height sheets.
struct ConduitSheetHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                // Clear of the close button at any text size.
                .padding(.horizontal, 52)
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .conduitGlassControl(cornerRadius: 18)
                .accessibilityLabel("Close \(title)")
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }
}
