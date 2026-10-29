//
//  CrashReportBanner.swift
//  Conduit
//
//  The "send this report?" card over the main screen after Conduit crashed
//  or froze (CrashReportOffer): once per report, with Send and Not now.
//

import SwiftUI

struct CrashReportBanner: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject private var offer = CrashReportOffer.shared

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            if offer.state != .hidden {
                banner
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: offer.state)
        // Reports left from a launch that ended before they were answered.
        .task { offer.refresh() }
    }

    private var title: String {
        switch offer.state {
        case .asking(crashed: true): AppLocalization.string("Conduit closed unexpectedly last time")
        case .asking(crashed: false): AppLocalization.string("Conduit froze last time")
        case .sending: AppLocalization.string("Sending the report…")
        case .sent: AppLocalization.string("Report sent. Thank you!")
        case .failed: AppLocalization.string("Couldn't send the report")
        case .hidden: ""
        }
    }

    private var symbol: String {
        switch offer.state {
        case .sent: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "ladybug"
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            if offer.state == .sending {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(offer.state == .failed ? Color.orange : Color.conduitAura)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.subheadline)
                    .lineLimit(2)
                if case .asking = offer.state {
                    Text(verbatim: AppLocalization.string("Send the report to Conduit's developer? It shows where the app stopped, never your messages."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch offer.state {
            case .asking, .failed:
                Button { Task { await offer.send() } } label: {
                    Text(offer.state == .failed ? AppLocalization.string("Try Again") : AppLocalization.string("Send"))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("crashReport.send")
            default:
                EmptyView()
            }
            if offer.state != .sending {
                Button { offer.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(offer.state == .sent ? AppLocalization.string("Dismiss") : AppLocalization.string("Not now")))
                .accessibilityIdentifier("crashReport.dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.08))
        .task(id: title) {
            guard !title.isEmpty else { return }
            UIAccessibility.post(notification: .announcement, argument: title)
        }
    }
}
