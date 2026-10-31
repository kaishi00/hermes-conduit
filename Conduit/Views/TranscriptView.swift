//
//  TranscriptView.swift
//  Conduit
//
//  The chat transcript drawn by a collection view (#1533, the transcript
//  rewrite).
//

import SwiftUI
import UIKit

/// The chat's transcript (#1533, the transcript rewrite): a collection view
/// laid out by TranscriptLayout, its offset TranscriptScroller's alone. The
/// rows are TranscriptModel's, each drawn by ChatView's SwiftUI in a hosting
/// controller of its own (TranscriptCell), with the chat's environment
/// handed to it (TranscriptCellEnvironment).
///
/// It fills the area around it, under the bars at its edges and the
/// keyboard, and keeps its rows clear of them with content insets: `insets`
/// is the safe area there (the header, the pinned replies, the composer, the
/// keyboard, a readable column's margins). A change SwiftUI animates (the
/// keyboard coming up, a bar growing) moves the insets, and the scroller's
/// offset with them, in the same animation.
struct TranscriptView: UIViewControllerRepresentable {
    let appState: AppState
    let scroller: TranscriptScroller
    let rows: [TranscriptRow]
    /// Draws a row (ChatView's).
    let rowContent: @MainActor (TranscriptRow) -> AnyView
    /// The rows' opened and closed runs (ChatRowDisclosure), one per chat.
    let disclosure: ChatRowDisclosure
    let insets: EdgeInsets
    /// The conversation drawn: measured heights are kept per conversation,
    /// whose row ids can repeat another's.
    let conversation: String
    /// The composer floats over the transcript (V2), which scrolls on under
    /// it and its header with the soft edge.
    let composerFloats: Bool
    /// The scope the rows drawn are (TranscriptScroller.renderedScrollScope),
    /// told to `layoutSettled` once a pass has laid them out.
    let renderedScope: ChatRenderedScrollScope?
    let layoutSettled: @MainActor (ChatRenderedScrollScope) -> Void

    func makeUIViewController(context: Context) -> TranscriptViewController {
        TranscriptViewController(appState: appState, scroller: scroller)
    }

    func updateUIViewController(_ controller: TranscriptViewController, context: Context) {
        controller.rowContent = rowContent
        controller.layoutSettled = layoutSettled
        let transaction = context.transaction
        controller.update(
            rows: rows,
            environment: TranscriptCellEnvironment(context.environment, disclosure: disclosure),
            insets: insets,
            insetsAnimation: transaction.disablesAnimations ? nil : transaction.animation,
            conversation: conversation,
            composerFloats: composerFloats,
            renderedScope: renderedScope
        )
    }

    static func dismantleUIViewController(_ controller: TranscriptViewController, coordinator: ()) {
        controller.detach()
    }
}

/// Holds the transcript's collection view, its rows' hosting controllers
/// (children of this one, so what a row presents, a sheet or a popover,
/// has a place to present from) and the scroller's attachment to them.
@MainActor
final class TranscriptViewController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    let layout = TranscriptLayout()
    private(set) lazy var collectionView = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
    let scroller: TranscriptScroller
    private let cellContext: TranscriptCellContext
    var rowContent: @MainActor (TranscriptRow) -> AnyView = { _ in AnyView(EmptyView()) }
    var layoutSettled: @MainActor (ChatRenderedScrollScope) -> Void = { _ in }

    private var rowsByID: [String: TranscriptRow] = [:]
    private var appliedRows: [TranscriptRow] = []
    private var appliedConversation: String?
    private var hasAppliedRows = false
    private var attached = false
    private var lastOffsetY: CGFloat = 0
    /// What the last pass the scroller heard of had: a pass with the same
    /// is a scroll's, which the scroller hears of through the offset.
    private var seenLayout: (generation: UInt64, size: CGSize, insets: UIEdgeInsets)?
    private var tracedContentHeight: CGFloat = 0
    private var pendingScope: ChatRenderedScrollScope?
    private var reportedScope: ChatRenderedScrollScope?
    /// Hosting controllers taken out of their cells while something was
    /// presented: a row's sheet or popover lives as long as its hosting
    /// controller shows that row, so a cell reused meanwhile gets a new one
    /// and the old one waits here, hidden, until nothing is presented.
    private var parked: [UIHostingController<TranscriptCellRoot>] = []
    private let parkingView = UIView()

    init(appState: AppState, scroller: TranscriptScroller) {
        self.scroller = scroller
        cellContext = TranscriptCellContext(appState: appState)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
        parkingView.isHidden = true
        parkingView.isUserInteractionEnabled = false
        view.addSubview(parkingView)
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.automaticallyAdjustsScrollIndicatorInsets = false
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.allowsSelection = false
        collectionView.delegate = self
        collectionView.register(TranscriptCell.self, forCellWithReuseIdentifier: TranscriptCell.reuseIdentifier)
        collectionView.didLayout = { [weak self] in self?.collectionViewDidLayout() }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TranscriptCell.reuseIdentifier, for: indexPath)
            if let cell = cell as? TranscriptCell { self?.configure(cell, id: id) }
            return cell
        }
        // After UIScrollView's own target, so a fling has begun by the time
        // the scroller hears the finger lift.
        collectionView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        // A tap between rows or beside them puts the keyboard away, as one
        // on a row does (TranscriptCellRoot).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        collectionView.addGestureRecognizer(tap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        dropParkedIfIdle()
    }

    func detach() {
        scroller.detach(collectionView)
        attached = false
    }

    // MARK: - Updates

    func update(
        rows: [TranscriptRow],
        environment: TranscriptCellEnvironment,
        insets: EdgeInsets,
        insetsAnimation: Animation?,
        conversation: String,
        composerFloats: Bool,
        renderedScope: ChatRenderedScrollScope?
    ) {
        // Before the rows: a cell configured for them draws with these.
        if environment != cellContext.environment {
            cellContext.environment = environment
        }
        layout.setScope("\(conversation)|\(environment.textScope)")
        applyInsets(insets, animation: insetsAnimation)
        applyEdgeEffect(composerFloats: composerFloats)
        let conversationChanged = appliedConversation != nil && appliedConversation != conversation
        appliedConversation = conversation
        applyRows(rows, redrawingAll: conversationChanged)
        if renderedScope != pendingScope {
            pendingScope = renderedScope
            collectionView.setNeedsLayout()
        }
    }

    /// The rows, by id: a row that changed draws again in its cell, the
    /// rest as they are. `redrawingAll` draws every row again (another
    /// conversation, whose rows can share ids with the last one's: Load
    /// earlier, the live rows).
    private func applyRows(_ rows: [TranscriptRow], redrawingAll: Bool) {
        let changes = TranscriptChangeSet.between(appliedRows, rows)
        guard !changes.isEmpty || !hasAppliedRows || redrawingAll, let dataSource else { return }
        let redrawn = redrawingAll ? rows.map(\.id).filter { rowsByID[$0] != nil } : changes.changed
        appliedRows = rows
        hasAppliedRows = true
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        layout.setRows(rows)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id), toSection: 0)
        if !redrawn.isEmpty {
            snapshot.reconfigureItems(redrawn)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The insets, in `animation` when SwiftUI animates their change: the
    /// pass inside it, where the scroller hears of them, moves the offset
    /// in the same animation (following, the end stays on the composer as
    /// the keyboard comes up).
    private func applyInsets(_ insets: EdgeInsets, animation: Animation?) {
        layout.setSideInsets(leading: insets.leading, trailing: insets.trailing)
        let content = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        guard collectionView.contentInset != content else { return }
        let collectionView = collectionView
        let change = {
            collectionView.contentInset = content
            collectionView.verticalScrollIndicatorInsets = content
        }
        guard let animation, attached else {
            change()
            collectionView.setNeedsLayout()
            return
        }
        let changeAndLayOut = {
            change()
            collectionView.layoutIfNeeded()
        }
        if #available(iOS 18.0, *) {
            UIView.animate(animation, changes: changeAndLayOut)
        } else {
            UIView.animate(
                withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                animations: changeAndLayOut
            )
        }
    }

    /// iOS 26's soft edges, as the stack had them: under the header
    /// (V2SoftTopScrollEdge) and under the floating composer (v2EdgeBar's
    /// system bar; on a Mac its own fade stands in). Before iOS 26 the
    /// fades are masks over this view, as before.
    private func applyEdgeEffect(composerFloats: Bool) {
        guard #available(iOS 26.0, *) else { return }
        collectionView.topEdgeEffect.style = composerFloats ? .soft : .automatic
        collectionView.bottomEdgeEffect.style = composerFloats && V2SystemScrollEdge.isUsed ? .soft : .automatic
    }

    private func configure(_ cell: TranscriptCell, id: String) {
        guard let row = rowsByID[id] else { return }
        if cell.hostedRowID != id, presentedViewController != nil, let hosting = cell.releaseHosting() {
            park(hosting)
        }
        let root = TranscriptCellRoot(
            rowID: id,
            content: rowContent(row),
            context: cellContext,
            resized: { [weak layout] size in layout?.rowResized(id, to: size) }
        )
        cell.host(root, rowID: id, in: self)
    }

    // MARK: - Layout

    /// After every pass of the collection view's, scrolls included: the
    /// scroller hears of the passes that moved a row, the content's size,
    /// the viewport or the insets.
    private func collectionViewDidLayout() {
        guard collectionView.bounds.height > 0 else { return }
        let current = (layout.generation, collectionView.bounds.size, collectionView.adjustedContentInset)
        traceSurface(size: current.1, insets: current.2)
        if !attached {
            attached = true
            seenLayout = current
            lastOffsetY = collectionView.contentOffset.y
            ChatViewportWatch.shared.surfaceChanged()
            scroller.attach(collectionView)
        } else if let seen = seenLayout, seen != current {
            seenLayout = current
            if seen.size != current.1 { ChatViewportWatch.shared.surfaceChanged() }
            scroller.layoutChanged()
        } else if seenLayout == nil {
            seenLayout = current
        }
        dropParkedIfIdle()
        reportSettledScope()
    }

    /// The recorder's lines for the collection view's size (a rotation, a
    /// split window), its insets (a bar, the keyboard) and its content's
    /// height.
    private func traceSurface(size: CGSize, insets: UIEdgeInsets) {
        if let seen = seenLayout {
            if seen.size != size {
                ChatViewportTrace.shared.log(String(
                    format: "surface bounds %.1fx%.1f -> %.1fx%.1f",
                    seen.size.width, seen.size.height, size.width, size.height
                ))
            }
            if seen.insets != insets {
                ChatViewportTrace.shared.log(String(format: "surface inset top %.1f bottom %.1f", insets.top, insets.bottom))
            }
        }
        let contentHeight = collectionView.contentSize.height
        if abs(contentHeight - tracedContentHeight) > 0.5 {
            ChatViewportTrace.shared.log(String(
                format: "surface contentSize h %.1f -> %.1f", tracedContentHeight, contentHeight
            ))
            tracedContentHeight = contentHeight
        }
    }

    /// The rows the scroller's scope names are laid out: AppState's
    /// handshake hears it on the next turn, outside this pass.
    private func reportSettledScope() {
        guard let scope = pendingScope, scope != reportedScope else { return }
        reportedScope = scope
        DispatchQueue.main.async { [weak self] in
            self?.layoutSettled(scope)
        }
    }

    // MARK: - Parked hosting controllers

    private func park(_ hosting: UIHostingController<TranscriptCellRoot>) {
        parkingView.addSubview(hosting.view)
        parked.append(hosting)
    }

    private func dropParkedIfIdle() {
        guard !parked.isEmpty, presentedViewController == nil else { return }
        for hosting in parked {
            hosting.willMove(toParent: nil)
            hosting.view.removeFromSuperview()
            hosting.removeFromParent()
        }
        parked = []
    }

    // MARK: - Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offsetY = scrollView.contentOffset.y
        if abs(offsetY - lastOffsetY) > 0.01 {
            ChatViewportWatch.shared.offsetMoved(
                from: lastOffsetY, to: offsetY, viewportHeight: scrollView.bounds.height,
                byUser: scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            )
            lastOffsetY = offsetY
        }
        guard attached else { return }
        scroller.surfaceScrolled()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard attached else { return }
        scroller.surfaceScrolled()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard attached else { return }
        scroller.surfaceScrolled()
    }

    /// The status bar's tap goes to the top the way the title's does.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        ChatViewportWatch.shared.command("explicitTop (status bar)")
        scroller.explicitTopRequested()
        return false
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard attached else { return }
        switch recognizer.state {
        case .began:
            scroller.userDragBegan()
        case .ended, .cancelled, .failed:
            scroller.userDragEnded()
        default:
            break
        }
    }

    @objc private func handleBackgroundTap() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Only touches on the collection view itself: one on a row is the
    /// row's.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === collectionView
    }
}

/// The transcript's collection view: the scroller's surface, reading the
/// layout's frames.
@MainActor
final class TranscriptCollectionView: UICollectionView, TranscriptScrollSurface {
    var didLayout: (() -> Void)?

    private var transcriptLayout: TranscriptLayout? { collectionViewLayout as? TranscriptLayout }

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }

    var contentOffsetY: CGFloat { contentOffset.y }
    var contentHeight: CGFloat { contentSize.height }
    var viewportHeight: CGFloat { bounds.height }
    var insetTop: CGFloat { adjustedContentInset.top }
    var insetBottom: CGFloat { adjustedContentInset.bottom }
    var reservedContentHeight: CGFloat { transcriptLayout?.appliedReserve ?? 0 }

    func setContentOffsetY(_ y: CGFloat, animated: Bool) {
        let target = CGPoint(x: contentOffset.x, y: y)
        if animated {
            setContentOffset(target, animated: true)
        } else {
            // Not setContentOffset(_:animated: false), which stops a fling.
            contentOffset = target
        }
    }

    func frame(ofRow id: String) -> TranscriptRowFrame? {
        transcriptLayout?.rowFrame(id)
    }

    func rows(crossing band: ClosedRange<CGFloat>) -> [TranscriptRowFrame] {
        transcriptLayout?.rows(crossing: band) ?? []
    }

    func reserveContentHeight(_ height: CGFloat) {
        transcriptLayout?.reserveContentHeight(height)
    }
}

/// One row's cell: the row draws in a hosting controller of the cell's,
/// kept while the cell is reused for other rows.
final class TranscriptCell: UICollectionViewCell {
    static let reuseIdentifier = "TranscriptCell"

    private(set) var hosting: UIHostingController<TranscriptCellRoot>?
    private(set) var hostedRowID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `root` in the cell, in a hosting controller that is a child of
    /// `parent`'s.
    func host(_ root: TranscriptCellRoot, rowID: String, in parent: UIViewController) {
        hostedRowID = rowID
        if let hosting {
            hosting.rootView = root
            return
        }
        let hosting = UIHostingController(rootView: root)
        // The transcript's insets keep rows clear of the bars; a cell under
        // one mustn't pad its row as well.
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        hosting.view.frame = contentView.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.addChild(hosting)
        contentView.addSubview(hosting.view)
        hosting.didMove(toParent: parent)
        self.hosting = hosting
    }

    /// The hosting controller, out of the cell, for one that must keep
    /// showing its row; the cell makes a new one when next shown.
    func releaseHosting() -> UIHostingController<TranscriptCellRoot>? {
        let released = hosting
        hosting = nil
        hostedRowID = nil
        return released
    }

    /// The row's height at the cell's width: its SwiftUI ideal height, the
    /// gap above it included.
    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard let hosting else { return layoutAttributes }
        let size = hosting.sizeThatFits(in: CGSize(width: layoutAttributes.size.width, height: .greatestFiniteMagnitude))
        guard size.height > 0, size.height.isFinite, abs(size.height - layoutAttributes.size.height) > 0.5,
              let attributes = layoutAttributes.copy() as? UICollectionViewLayoutAttributes else { return layoutAttributes }
        attributes.size.height = size.height
        return attributes
    }
}

/// A row's root in its cell: the row centered in the column, as in the
/// stack, under the gap above it (TranscriptLayout.rowGap), at its ideal
/// height, which it reports when it changes (a picture loading, a card
/// taking its height, a reply streaming in). Keyed by the row's id, so a
/// cell reused for another row starts that row's state afresh.
struct TranscriptCellRoot: View {
    let rowID: String
    let content: AnyView
    @ObservedObject var context: TranscriptCellContext
    let resized: @MainActor (CGSize) -> Void

    var body: some View {
        TranscriptCellLayout {
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .padding(.top, TranscriptLayout.rowGap)
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    MainActor.assumeIsolated { resized(size) }
                }
        }
        // A tap on the row that no control in it takes puts the keyboard
        // away, as one on the transcript did.
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .transcriptCellEnvironment(context.environment)
        .environmentObject(context.appState)
        .id(rowID)
    }
}

/// The row in its cell. Measured (the cell asks with no height, or one no
/// row reaches), it's the row's ideal height at the cell's width. Drawn,
/// it's the cell's frame, the row at its top at its ideal height: a row
/// that grows draws down from its top at once while the cell takes its new
/// height in the next pass, where the hosting controller would center it
/// in the old frame meanwhile and move it up and back.
private struct TranscriptCellLayout: Layout {
    /// A proposed height at least this tall is a measurement's.
    private static let measuringHeight: CGFloat = 1e7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let row = subviews.first else { return .zero }
        let width = proposal.width ?? row.sizeThatFits(.unspecified).width
        if let height = proposal.height, height < Self.measuringHeight {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: width, height: row.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}
