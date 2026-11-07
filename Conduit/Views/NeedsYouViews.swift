//
//  NeedsYouViews.swift
//  Conduit
//
//  Hermes is waiting on you (issue 1705): the banner over the main screen
//  when another chat starts waiting, and the Needs you list of every
//  profile's waiting chats. Both only open a chat at its card: an approval
//  is answered there, where the whole command shows.
//

import SwiftUI

/// "Atlas · Release prep · Approval needed", with Open, over whatever is on
/// screen. It never takes focus and goes by itself after a few seconds; the
/// wait stays on the profile chips and in the Needs you list.
struct NeedsYouBanner: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: NeedsYouStore
    @State private var showsList = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            if let item = store.banner {
                banner(item)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .frame(maxWidth: 560)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: item.id) {
                        UIAccessibility.post(notification: .announcement, argument: announcement(item))
                        // Cancelled (the banner moved over a call's screen, or
                        // went): the other banner keeps it.
                        do { try await Task.sleep(for: .seconds(NeedsYouStore.bannerSeconds)) } catch { return }
                        store.dismissBanner(item)
                    }
            }
        }
        .animation(.snappy, value: store.banner)
        .sheet(isPresented: $showsList) {
            NeedsYouSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
    }

    private func announcement(_ item: NeedsYouItem) -> String {
        [appState.profileDisplayName(item.profile), NeedsYouRow.title(item), item.kindLine].joined(separator: ", ")
    }

    private func banner(_ item: NeedsYouItem) -> some View {
        // Not counting the open chat's wait, whose card is on screen.
        let others = store.items.filter { $0.id != item.id && !appState.isOpenChat($0) }.count
        return HStack(spacing: 10) {
            ProfileAvatarView(
                profile: item.profile,
                displayName: appState.profileDisplayName(item.profile),
                url: appState.profileAvatarURL(for: item.profile),
                size: 28
            )
            .overlay(alignment: .bottomTrailing) { NeedsYouDot(size: 9) }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(appState.profileDisplayName(item.profile)) · \(NeedsYouRow.title(item))")
                    .scaledFont(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: others > 0
                     ? "\(item.kindLine) · \(AppLocalization.string("\(Int(others)) more waiting"))"
                     : item.kindLine)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // One element for VoiceOver, which offers the text's tap as its
            // actions: the list when others wait too.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityActions {
                if others > 0 {
                    Button(AppLocalization.string("Needs you")) {
                        store.dismissBanner(item)
                        showsList = true
                    }
                }
            }
            // The rest of the banner opens the list when others wait too.
            .onTapGesture {
                if others > 0 {
                    store.dismissBanner(item)
                    showsList = true
                } else {
                    appState.openNeedsYou(item)
                }
            }
            Button {
                Haptics.selection()
                appState.openNeedsYou(item)
            } label: {
                Text(AppLocalization.string("Open"))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .scaledFont(.subheadline.weight(.semibold))
            .accessibilityIdentifier("needsYou.banner.open")
            Button { store.dismissBanner(item) } label: {
                Image(systemName: "xmark")
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(AppLocalization.string("Dismiss")))
            .accessibilityIdentifier("needsYou.banner.dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .conduitGlassSurface(cornerRadius: 18, tint: Color.conduitAttention.opacity(0.10))
        .accessibilityElement(children: .contain)
    }
}

/// The amber dot of a wait: the same color as a chat row's Approve and the
/// filter's dot, apart from the gold unread dot.
struct NeedsYouDot: View {
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(Color.conduitAttention)
            .frame(width: size, height: size)
            .overlay { Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1) }
    }
}

/// A profile chip's count of waiting chats.
struct NeedsYouCountBadge: View {
    let count: Int

    var body: some View {
        // Fixed size: a badge on a fixed-size profile picture, as the unread dot.
        Text(verbatim: count > 9 ? "9+" : "\(count)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(Color.black)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Color.conduitAttention))
            .overlay { Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 1) }
            .fixedSize()
    }
}

/// Every chat Hermes waits on the user in, every profile's, newest first.
/// A row opens its chat at the card.
struct NeedsYouSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: NeedsYouStore

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                List {
                    if store.items.isEmpty {
                        ContentUnavailableView(
                            AppLocalization.string("Nothing needs you"),
                            systemImage: "checkmark.circle",
                            description: Text(AppLocalization.string("When Hermes waits on your approval or answer in any chat, it shows here."))
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(store.items) { item in
                            Button {
                                Haptics.selection()
                                dismiss()
                                appState.openNeedsYou(item)
                            } label: {
                                NeedsYouRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(AppLocalization.string("Opens the chat at its card"))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Needs you"), close: { dismiss() })
            }
        }
        // Fresh while it's up, whichever screen opened it.
        .task { await appState.refreshNeedsYou() }
    }
}

/// One waiting chat: its profile, title, what it waits on and since when,
/// as a Work panel card's head reads.
struct NeedsYouRow: View {
    @EnvironmentObject private var appState: AppState
    let item: NeedsYouItem

    static func title(_ item: NeedsYouItem) -> String {
        item.title.isEmpty ? AppLocalization.string("Untitled chat") : item.title
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileAvatarView(
                profile: item.profile,
                displayName: appState.profileDisplayName(item.profile),
                url: appState.profileAvatarURL(for: item.profile),
                size: 30
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: Self.title(item))
                        .scaledFont(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // A host that sent no time: no age to show.
                    if item.since != .distantPast {
                        Text(item.since, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    NeedsYouDot(size: 7)
                    Text(verbatim: "\(appState.profileDisplayName(item.profile)) · \(item.kindLine)")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(Color.conduitAttention)
                        .lineLimit(1)
                }
                if !item.summary.isEmpty {
                    Text(verbatim: item.summaryLine)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
