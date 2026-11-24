//
//  BotChatCoverFade.swift
//  Conduit
//
//  A Bot Chat's cover (`BotChatComingCover`), shown and lifted by Core
//  Animation.
//

import SwiftUI
import UIKit

/// When a Bot Chat's cover shows, apart from the view that draws it.
///
/// It shows while `AppState.botChatCoverBot` names the coming bot. Once
/// that bot's chat is the open one, it stays until the transcript has laid
/// out that chat's own rows (its saved copy, or its welcome), or a cap
/// runs out: lifted as the open switched chats, its fade played over the
/// transcript's busiest pass and jumped (a device trace, 2026-11-24).
/// Hermes' rows are never waited for: they took 340 ms to 2.3 s. Any other
/// end (an open that failed or was stood down, another chat opened) lifts
/// it at once.
struct BotChatCoverLift: Equatable {
    enum Change: Equatable {
        case none
        case show
        /// The coming chat is open: the cover waits for its rows, or the cap.
        case awaitRows
        case lift
    }

    private(set) var shows = false
    private(set) var awaitsRows = false
    private var coming: String?

    /// `coming` is `AppState.botChatCoverBot`; `openBotChat`, the Bot Chat
    /// now open (nil for any other chat or a room).
    mutating func coverChanged(coming newComing: String?, openBotChat: String?) -> Change {
        if let newComing {
            coming = newComing
            awaitsRows = false
            guard !shows else { return .none }
            shows = true
            return .show
        }
        guard shows else { return .none }
        if let coming, let openBotChat, AppState.profilesMatch(openBotChat, coming) {
            guard !awaitsRows else { return .none }
            awaitsRows = true
            return .awaitRows
        }
        return lift()
    }

    /// The transcript laid out the open chat's own rows.
    mutating func ownRowsLaidOut() -> Change {
        awaitsRows ? lift() : .none
    }

    /// The wait for those rows ran out.
    mutating func capReached() -> Change {
        awaitsRows ? lift() : .none
    }

    private mutating func lift() -> Change {
        shows = false
        awaitsRows = false
        coming = nil
        return .lift
    }
}

/// Shows and lifts a Bot Chat's cover with Core Animation, which plays in
/// the render server: the open keeps the main thread busy for a few hundred
/// milliseconds as the cover lifts, and a SwiftUI animation, evaluated
/// there frame by frame, showed its first frame 100 to 250 ms late.
@MainActor
final class BotChatCoverFade {
    private(set) var lift = BotChatCoverLift()
    /// The view whose layer fades (`BotChatCoverController`).
    weak var cover: UIView?
    var reduceMotion = false
    /// How long the cover waits for the open chat's rows once it's open.
    var cap: Duration = .milliseconds(600)
    private var capTask: Task<Void, Never>?

    static let key = "conduit.botChatCover"

    /// From the screen's update: nothing is flushed from inside it.
    func coverChanged(coming: String?, openBotChat: String?, animated: Bool) {
        apply(lift.coverChanged(coming: coming, openBotChat: openBotChat), animated: animated, flushes: false)
    }

    /// The transcript laid out a chat's own rows, outside a view update.
    func ownRowsLaidOut() {
        apply(lift.ownRowsLaidOut(), animated: true, flushes: true)
    }

    private func capReached() {
        apply(lift.capReached(), animated: true, flushes: true)
    }

    private func apply(_ change: BotChatCoverLift.Change, animated: Bool, flushes: Bool) {
        switch change {
        case .none:
            return
        case .show:
            capTask?.cancel()
            capTask = nil
            ResponsivenessSignposts.signposter.emitEvent("Bot Chat cover", "shown")
            show(true, animated: animated, flushes: flushes)
        case .awaitRows:
            capTask?.cancel()
            let cap = cap
            capTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: cap) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.capTask = nil
                self.capReached()
            }
        case .lift:
            capTask?.cancel()
            capTask = nil
            ResponsivenessSignposts.signposter.emitEvent("Bot Chat cover", "lifted")
            show(false, animated: animated, flushes: flushes)
        }
    }

    /// The cover as `lift` has it, at once (a new cover view).
    func place() {
        show(lift.shows, animated: false, flushes: false)
    }

    private func show(_ shown: Bool, animated: Bool, flushes: Bool) {
        guard let cover else { return }
        // It takes the taps while it shows, so nothing reaches the chat
        // under it, and VoiceOver reads only it.
        cover.isUserInteractionEnabled = shown
        cover.accessibilityElementsHidden = !shown
        cover.accessibilityViewIsModal = shown
        let layer = cover.layer
        let from = layer.presentation()?.opacity ?? layer.opacity
        let to: Float = shown ? 1 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = to
        CATransaction.commit()
        guard animated, from != to else {
            layer.removeAnimation(forKey: Self.key)
            return
        }
        layer.add(Self.fade(from: from, to: to, reduceMotion: reduceMotion), forKey: Self.key)
        // Sent to the render server now: the main thread stays busy next.
        if flushes { CATransaction.flush() }
    }

    static func fade(from: Float, to: Float, reduceMotion: Bool) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        // Reduce Motion: the plain settle fade (`ConduitMotion.settle`).
        fade.duration = reduceMotion ? 0.22 : 0.3
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        return fade
    }
}

/// The cover's view, in the screen's tree from its first frame and shown by
/// its layer's opacity: an inserted branch at push time grew the zoom
/// push's view update past the main thread's stack (Debug, iOS 27.3).
struct BotChatCoverHost: UIViewControllerRepresentable {
    let fade: BotChatCoverFade
    /// The bot whose backdrop the cover draws: the coming one, else the open
    /// Bot Chat's, so a fade out as it lands doesn't change color.
    let bot: String?
    /// `AppState.botChatCoverBot`.
    let coming: String?
    /// The Bot Chat now open; nil for any other chat or a room.
    let openBotChat: String?
    let reduceMotion: Bool
    let appState: AppState
    let shell: V2ShellContext

    func makeUIViewController(context: Context) -> BotChatCoverController {
        BotChatCoverController()
    }

    func updateUIViewController(_ controller: BotChatCoverController, context: Context) {
        // A hosting controller of its own doesn't inherit the screen's
        // environment: the in-app language (the root's locale) and what the
        // cover's text reads come along by hand.
        let environment = context.environment
        let content = BotChatCoverController.Content(
            bot: bot, shell: shell, locale: environment.locale,
            dynamicTypeSize: environment.dynamicTypeSize,
            layoutDirection: environment.layoutDirection,
            columnText: environment.columnText
        )
        if controller.content != content {
            controller.content = content
            controller.hosting.rootView = AnyView(
                BotChatComingCover(bot: bot)
                    .environmentObject(appState)
                    .environment(\.v2Shell, shell)
                    .environment(\.locale, content.locale)
                    .environment(\.dynamicTypeSize, content.dynamicTypeSize)
                    .environment(\.layoutDirection, content.layoutDirection)
                    .environment(\.columnText, content.columnText)
            )
        }
        fade.reduceMotion = reduceMotion
        if fade.cover !== controller.hosting.view {
            fade.cover = controller.hosting.view
            fade.place()
        }
        // The first frame shows the cover as it is, with no fade in.
        fade.coverChanged(coming: coming, openBotChat: openBotChat, animated: controller.hasUpdated)
        controller.hasUpdated = true
    }
}

final class BotChatCoverController: UIViewController {
    struct Content: Equatable {
        let bot: String?
        let shell: V2ShellContext
        let locale: Locale
        let dynamicTypeSize: DynamicTypeSize
        let layoutDirection: LayoutDirection
        let columnText: ColumnText?
    }

    let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    var content: Content?
    var hasUpdated = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.view.layer.opacity = 0
        hosting.view.isUserInteractionEnabled = false
        hosting.view.accessibilityElementsHidden = true
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    /// Hidden, the cover passes touches through to the chat under it.
    override func loadView() {
        view = PassThroughView()
    }
}

/// Takes no touch itself: only a subview that does.
private final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// A Bot Chat's screen while its open is out and the active chat is still
/// the one open before (`AppState.botChatCoverBot`): the bot's backdrop and
/// that it's opening. It takes the taps, so nothing reaches the chat under
/// it.
struct BotChatComingCover: View {
    let bot: String?

    var body: some View {
        ZStack(alignment: .top) {
            V2Backdrop(glowProfile: bot)
            ProgressView("Opening conversation…")
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 60)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
