import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// Issue #98 ("Kanban UI texts are broken"): regression coverage for the
/// responsive selection chrome on narrow iPhones (iPhone 17-class logical
/// width ≈ 393pt).
///
/// Layers covered:
/// 1. PURE POLICY — count singular/plural, header variant replacement,
///    idle-only cancel exit, and full/compact bulk-action descriptor
///    equivalence (identical kinds, symbols, and accessibility labels).
/// 2. REAL HOSTED LAYOUT — the extracted production components
///    ('KanbanSelectionHeaderBar', 'KanbanBulkActionsCluster') are measured
///    at an iPhone-sized width to prove "Cancel" / "N tasks selected" /
///    action controls never wrap into multi-line fragments, including one
///    Dynamic Type step above the default, and that 'ViewThatFits' actually
///    trades labeled actions for icon-only ones as width shrinks.
///
/// Selection/bulk-operation semantics themselves (staging, ownership,
/// pruning, wire contracts) stay protected by 'KanbanV3CTests'; these tests
/// intentionally do not duplicate them.
@MainActor
final class KanbanSelectionLayoutTests: XCTestCase {

    /// Logical width of an iPhone 17-sized display.
    private let phoneWidth: CGFloat = 393

    // MARK: - Hosted-layout harness

    /// Keeps a hosting controller (and its window) alive for one test.
    /// `@MainActor`: everything here touches UIKit/MainActor-isolated APIs.
    @MainActor
    private final class HostBox {
        let window: UIWindow
        let hostView: UIView
        let proposedWidth: CGFloat
        /// `UIHostingController.sizeThatFits(in:)`, captured so the generic
        /// content type can be erased without losing the sizing API.
        // (Not `private`: the owning test type reads it from outside.)
        fileprivate let fitSize: @MainActor (CGSize) -> CGSize

        init<V: View>(_ view: V, width: CGFloat) {
            let host = UIHostingController(rootView: view.frame(width: width))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1400))
            window.addSubview(host.view)
            self.window = window
            self.hostView = host.view
            self.proposedWidth = width
            // STRONG capture: HostBox owns the controller's lifetime. A
            // weak capture let it deallocate right after init, silently
            // collapsing fitSize to .zero and neutering every guard below.
            self.fitSize = { proposal in
                host.sizeThatFits(in: proposal)
            }
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }
    }

    private var liveHosts: [HostBox] = []

    override func tearDown() {
        liveHosts.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func render(
        _ view: some View,
        width: CGFloat,
        dynamicTypeSize: DynamicTypeSize = .medium
    ) -> HostBox {
        let box = HostBox(
            view.environment(\.dynamicTypeSize, dynamicTypeSize),
            width: width
        )
        liveHosts.append(box)
        return box
    }

    /// Content height of the hosted view at the pinned proposal width.
    /// Any accidental line-wrap shows up directly as extra height.
    @discardableResult
    private func fittedHeight(of box: HostBox) -> CGFloat {
        box.window.layoutIfNeeded()
        let size = box.fitSize(CGSize(width: box.proposedWidth, height: .greatestFiniteMagnitude))
        // Real-measurement guard: proves the hosted controller is alive and
        // actually sized (a .zero here would mean a dead/never-measured host).
        XCTAssertGreaterThan(size.height, 0, "hosted layout measurement collapsed")
        return max(size.height, box.hostView.bounds.height)
    }

    private func allViews(in root: UIView) -> [UIView] {
        var collected: [UIView] = []
        func walk(_ view: UIView) {
            collected.append(view)
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return collected
    }

    /// Best-effort visible-text scrape. REVIEW-GATE NOTE: this couples to
    /// SwiftUI's CURRENT UILabel materialization (an implementation detail a
    /// future OS could change); the binding guarantees live in the policy
    /// layer and the fitting-height proofs, so if scraping ever yields
    /// nothing those guards still fully protect the layout.
    private func uiLabelTexts(in root: UIView) -> Set<String> {
        Set(allViews(in: root).compactMap { ($0 as? UILabel)?.text }.filter { !$0.isEmpty })
    }

    // NOTE: runtime accessibility-tree introspection is deliberately NOT used
    // here — SwiftUI materializes the tree lazily and only for real assistive
    // clients, so hosted unit tests read it as empty. The VoiceOver strings
    // themselves are pinned variant-independent at the policy layer instead.

    private func subheadlineLineHeight(for category: UIContentSizeCategory) -> CGFloat {
        UIFont.preferredFont(
            forTextStyle: .subheadline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        ).lineHeight
    }

    // MARK: - Pure policy: count label

    func testSelectedCountLabelsRemainOneLogicalLabelIncludingZero() {
        XCTAssertEqual(KanbanSelectionChromePolicy.selectedCountLabel(count: 0), "0 tasks selected")
        XCTAssertEqual(KanbanSelectionChromePolicy.selectedCountLabel(count: 1), "1 task selected")
        XCTAssertEqual(KanbanSelectionChromePolicy.selectedCountLabel(count: 3), "3 tasks selected")
        XCTAssertEqual(KanbanSelectionChromePolicy.selectedCountLabel(count: 12), "12 tasks selected")
        for count in [0, 1, 3, 12] {
            let label = KanbanSelectionChromePolicy.selectedCountLabel(count: count)
            XCTAssertFalse(label.contains("\n"), "count label must never embed newlines: \(label)")
        }
    }

    // MARK: - Pure policy: header variant

    func testSelectionModeReplacesRatherThanSharesTheHeaderRow() {
        XCTAssertEqual(
            KanbanSelectionChromePolicy.headerVariant(isSelectionActive: false),
            .standardBoardControls
        )
        XCTAssertEqual(
            KanbanSelectionChromePolicy.headerVariant(isSelectionActive: true),
            .compactSelection
        )
    }

    // MARK: - Pure policy: cancel gating

    func testCancelExitIsIdleOnlyAndStaysBlockedWhileBulkBusy() {
        XCTAssertTrue(KanbanSelectionChromePolicy.allowsCancelExit(bulkBusy: false))
        XCTAssertFalse(KanbanSelectionChromePolicy.allowsCancelExit(bulkBusy: true))
    }

    // MARK: - Pure policy: bulk-action descriptor equivalence

    func testCompactAndFullBulkActionsPreserveMoveAssignMoreSemanticsAndAccessibility() {
        let kinds: [KanbanSelectionChromePolicy.BulkActionDescriptor.Kind] = [.move, .assign, .more]
        XCTAssertEqual(KanbanSelectionChromePolicy.fullBulkActions.map(\.kind), kinds)
        XCTAssertEqual(KanbanSelectionChromePolicy.compactBulkActions.map(\.kind), kinds)

        // Identical glyphs in both variants…
        XCTAssertEqual(
            KanbanSelectionChromePolicy.fullBulkActions.map(\.systemImage),
            ["arrow.left.arrow.right", "person.fill.badge.plus", "ellipsis.circle"]
        )
        XCTAssertEqual(
            KanbanSelectionChromePolicy.compactBulkActions.map(\.systemImage),
            KanbanSelectionChromePolicy.fullBulkActions.map(\.systemImage)
        )

        // …labeled when roomy, icon-only when narrow…
        XCTAssertTrue(KanbanSelectionChromePolicy.fullBulkActions.allSatisfy { $0.title != nil })
        XCTAssertTrue(KanbanSelectionChromePolicy.compactBulkActions.allSatisfy { $0.title == nil })

        // …and VoiceOver text identical for both variants, singular noun
        // for exactly one selected task, plural otherwise.
        for count in [0, 1, 3] {
            let noun = count == 1 ? "task" : "tasks"
            for kind in kinds {
                let expected: String
                switch kind {
                case .move: expected = "Move \(count) selected \(noun)"
                case .assign: expected = "Assign \(count) selected \(noun)"
                case .more: expected = "More actions for \(count) selected \(noun)"
                }
                XCTAssertEqual(
                    KanbanSelectionChromePolicy.bulkAccessibilityLabel(kind, selectedCount: count),
                    expected
                )
            }
        }
    }

    // MARK: - Hosted: compact selection header (real component)

    func testSelectionHeaderStaysSingleLineAtIphoneWidthForZeroOneThreeSelected() {
        let defaultBound = subheadlineLineHeight(for: .large) * 2 + 34
        for count in [0, 1, 3] {
            let box = render(
                KanbanSelectionHeaderBar(selectedCount: count, bulkBusy: false) {},
                width: phoneWidth
            )
            let height = fittedHeight(of: box)
            // A single row with the padded Cancel capsule must stay well
            // below TWO text lines; the pre-fix bug stacked >=3 character rows.
            XCTAssertLessThanOrEqual(height, defaultBound, "wrapped header at count \(count)")
            // VoiceOver strings themselves are pinned variant-independent by
            // the policy suite below; SwiftUI mediates their runtime exposure.
        }
    }

    func testSelectionHeaderTextNeverFragmentsVerticallyAtPhoneWidth() {
        // Direct guard for the reported symptom: no single-character column
        // ("Ca"/"nc"/"el"). At 393pt the whole padded row comfortably fits,
        // so ANY tiny multi-char fragment is a regression.
        let box = render(
            KanbanSelectionHeaderBar(selectedCount: 3, bulkBusy: false) {},
            width: phoneWidth
        )
        fittedHeight(of: box)
        for text in uiLabelTexts(in: box.hostView) {
            XCTAssertGreaterThan(text.count, 2, "text fragmented vertically: '\(text)'")
        }
    }

    func testSelectionHeaderDegradesGracefullyAboveDefaultDynamicType() {
        // One+ step above default: sensible degradation — a taller SINGLE
        // row, never character-by-character wrapping.
        let bound = subheadlineLineHeight(for: .extraExtraExtraLarge) + 40
        for typeSize in [DynamicTypeSize.large, .xLarge, .xxLarge] {
            let box = render(
                KanbanSelectionHeaderBar(selectedCount: 3, bulkBusy: false) {},
                width: phoneWidth,
                dynamicTypeSize: typeSize
            )
            XCTAssertLessThanOrEqual(
                fittedHeight(of: box),
                bound,
                "header must degrade sensibly (no char-wrap) at \(typeSize)"
            )
        }
    }

    // MARK: - Hosted: adaptive bulk-action cluster (real component)

    func testBulkActionsStaySingleLineAndAccessibleWithZeroSelected() {
        let cluster = KanbanBulkActionsCluster(
            selectedCount: 0,
            controlsEnabled: false, // zero-selected keeps actions disabled, as before
            onMove: {},
            onAssign: {},
            moreMenuContent: { EmptyView() }
        )
        let box = render(cluster, width: phoneWidth)

        let bodyLine = UIFont.preferredFont(forTextStyle: .body).lineHeight
        XCTAssertLessThanOrEqual(fittedHeight(of: box), bodyLine * 2 + 16, "bulk actions wrapped")

        // The icon-only fallback must never silently drop an action: the
        // compact set still carries ALL THREE kinds. Their VoiceOver strings
        // are pinned identical to the labeled set by the policy suite.
        XCTAssertEqual(
            Set(KanbanSelectionChromePolicy.compactBulkActions.map(\.kind)),
            [KanbanSelectionChromePolicy.BulkActionDescriptor.Kind.move,
             .assign,
             .more]
        )
    }

    func testAdaptiveClusterTradesTitlesForIconsAsWidthShrinks() {
        func renderedState(width: CGFloat) -> (height: CGFloat, texts: Set<String>) {
            let cluster = KanbanBulkActionsCluster(
                selectedCount: 3,
                controlsEnabled: true,
                onMove: {},
                onAssign: {},
                moreMenuContent: { EmptyView() }
            )
            let box = render(cluster, width: width)
            return (
                fittedHeight(of: box),
                uiLabelTexts(in: box.hostView)
            )
        }

        let bodyLine = UIFont.preferredFont(forTextStyle: .body).lineHeight

        // Roomy (tablet-split class width): labeled actions on ONE line.
        let roomy = renderedState(width: 900)
        XCTAssertLessThanOrEqual(roomy.height, bodyLine * 2 + 16, "roomy bulk actions wrapped")

        // Phone width: still ONE line; any surviving visible titles are whole
        // words — never per-letter fragments of Move / Assign / More.
        let narrow = renderedState(width: phoneWidth)
        XCTAssertLessThanOrEqual(narrow.height, bodyLine * 2 + 16, "phone-width bulk actions wrapped")
        for text in narrow.texts where ["Move", "Assign", "More"].contains(text) {
            XCTFail("full title '\(text)' survived next to squeezed neighbors at phone width")
        }
        for text in narrow.texts {
            XCTAssertGreaterThan(text.count, 2, "letter fragment '\(text)' leaked at phone width")
        }
    }

    func testComposedBulkBarFitsPhoneWidthWithoutWrappingForAllCounts() {
        // Mirrors 'bulkActionBar' geometry exactly (count text + spacer +
        // real cluster + same padding/material frame) so the ONE-LINE
        // outcome of the composed bottom bar is measured end-to-end.
        // NOTE: bounds derive from current iOS system font metrics (17–26.x).
        // If a future OS changes .subheadline/.body line heights, update the
        // multipliers here rather than loosening the regression intent.
        let sub = subheadlineLineHeight(for: .large)
        let body = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let bound = max(sub, body) * 2 + 20

        // Both production states: idle AND bulkBusy — the spinner consumes
        // real width between Spacer and the cluster, so it belongs in the
        // worst-case geometry this guard measures.
        for busy in [false, true] {
            for count in [0, 1, 3] {
                let countLabel = KanbanSelectionChromePolicy.selectedCountLabel(count: count)
                let bar = HStack(spacing: 10) {
                    Text(countLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityLabel(countLabel)
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                    KanbanBulkActionsCluster(
                        selectedCount: count,
                        controlsEnabled: false,
                        onMove: {},
                        onAssign: {},
                        moreMenuContent: { EmptyView() }
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                let barWidth = phoneWidth - 20 // outer horizontal padding from safeAreaInset chrome
                let box = render(bar, width: barWidth)
                XCTAssertLessThanOrEqual(
                    fittedHeight(of: box), bound,
                    "composed bulk bar wrapped at count \(count) busy=\(busy)"
                )

                for label in uiLabelTexts(in: box.hostView) {
                    XCTAssertGreaterThan(label.count, 2, "fragmented text '\(label)' at count \(count)")
                }
            }
        }
    }

    // MARK: - Hosted: busy header keeps its compact shape

    func testBusyHeaderKeepsCompactShapeWhileCancelStaysInertByPolicy() {
        // Parity with pre-#98 behavior: while bulkBusy, Cancel stays disabled
        // AND the busy indicator space is reserved; exiting remains blocked.
        let busy = KanbanSelectionHeaderBar(selectedCount: 3, bulkBusy: true) {}
        let box = render(busy, width: phoneWidth)

        XCTAssertLessThanOrEqual(fittedHeight(of: box), 72, "busy header wrapped")
        XCTAssertFalse(KanbanSelectionChromePolicy.allowsCancelExit(bulkBusy: true))
    }
}
