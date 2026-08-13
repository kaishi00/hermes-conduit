# Cross-Block Markdown Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one Markdown response select and copy text across paragraphs, tables, and fenced code while preserving the existing rich visuals and native link behavior.

**Architecture:** Keep `MarkdownBlockView`, `MarkdownTable`, and `ChatCodeBlock` as the visual source of truth. Add a response-scoped `MarkdownSelectionCoordinator` that registers the existing child `UITextView`s in rendered order, resolves a cross-child selection from global pointer coordinates, and supplies multi-segment copy/highlight behavior. The existing single `UITextView` fast path remains unchanged for responses containing only simple flow blocks.

**Tech Stack:** Swift 5.9, SwiftUI 17, UIKit `UITextView`/`NSLayoutManager`, XCTest, XcodeGen.

## Global Constraints

- Target iOS 17.0 and keep the existing project dependency set.
- Preserve the current table grid, code cards, horizontal table/code scrolling, copy buttons, syntax colors, Dynamic Type cache behavior, and inline link attributes.
- Do not flatten a table or code block into a replacement textual card.
- Coordinate only text-bearing blocks within one Markdown response; do not span separate chat messages or rendered Mermaid/LaTeX previews.
- Invalidate registrations and UTF-16 offsets whenever the Markdown source revision changes.
- Keep standalone `SelectableTextView` users, including tool cards, on their current native-selection path when no response coordinator is supplied.
- Run the focused simulator test command after every task that changes Swift code:

```bash
/Users/agrias/bin/bin/xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -only-testing:ConduitTests/MarkdownSelectionCoordinatorTests \
  -only-testing:ConduitTests/ChatTextSelectionTests \
  CODE_SIGNING_ALLOWED=NO
```

## File Map

- Create: `Conduit/Views/Components/MarkdownSelectionCoordinator.swift` — segment descriptors, source-order planning, range resolution, attributed copy, and registration state.
- Modify: `Conduit/Views/Components/SelectableTextView.swift` — optional coordinator registration, touch/selection callbacks, coordinated copy, and teardown.
- Modify: `Conduit/Views/Components/MarkdownText.swift` — stable segment IDs, coordinator lifetime, rich-block registration, and the response-level gesture/highlight modifier.
- Create: `ConduitTests/MarkdownSelectionCoordinatorTests.swift` — pure segment ordering, range, revision, copy, and geometry tests.
- Modify: `ConduitTests/ChatTextSelectionTests.swift` — preserve existing fast-path/link tests and add the bridge contract tests that belong to `SelectableTextView`.

### Task 1: Define the ordered segment model and make its range behavior testable

**Files:**
- Create: `ConduitTests/MarkdownSelectionCoordinatorTests.swift`
- Create: `Conduit/Views/Components/MarkdownSelectionCoordinator.swift`

**Interfaces:**
- Produces `MarkdownSelectionSegmentDescriptor`, `MarkdownSelectionEndpoint`, `MarkdownSelectionSpan`, `MarkdownSelectionCoordinator`, and `MarkdownSelectionSegmentPlan` for later tasks.
- `MarkdownSelectionSegmentDescriptor` has `id: String`, `order: Int`, and `separatorBefore: String`.
- `MarkdownSelectionEndpoint` has `segmentID: String` and `offset: Int`, where offsets are UTF-16 `NSRange` offsets.
- `MarkdownSelectionSpan` has `segmentID: String` and `range: NSRange`.
- `MarkdownSelectionCoordinator` is an `ObservableObject` that exposes `replaceSegments(_:revision:)`, `register(descriptor:textView:)`, `unregister(segmentID:textView:)`, `text(for:)`, `orderedEndpoints(from:to:) -> (start: MarkdownSelectionEndpoint, end: MarkdownSelectionEndpoint)`, `spans(from:to:)`, and `copiedAttributedText(from:to:)`.
- `MarkdownSelectionSegmentPlan.descriptors(for:)` returns text-bearing segments in rendered order. Table cells are row-major, code is one segment, and non-text blocks return no segment.

- [ ] **Step 1: Write failing tests for ordering, forward/reverse ranges, and intermediate segments**

```swift
@MainActor
final class MarkdownSelectionCoordinatorTests: XCTestCase {
    func testMixedResponseUsesRenderedOrderAndSelectsEveryIntermediateSegment() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c0", order: 1, separatorBefore: "\n"),
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c1", order: 2, separatorBefore: " | "),
            MarkdownSelectionSegmentDescriptor(id: "code", order: 3, separatorBefore: "\n\n"),
            MarkdownSelectionSegmentDescriptor(id: "paragraph-2", order: 4, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "mixed-v1")
        for descriptor in descriptors {
            let text: String
            switch descriptor.id {
            case "paragraph": text = "First paragraph."
            case "table-r0-c0": text = "A"
            case "table-r0-c1": text = "B"
            case "code": text = "let x = 1"
            case "paragraph-2": text = "After"
            default: XCTFail("Unexpected descriptor \(descriptor.id)"); continue
            }
            let textView = SelectableTextView.makeTextView()
            textView.attributedText = NSAttributedString(string: text)
            coordinator.register(descriptor: descriptor, textView: textView)
        }

        XCTAssertEqual(
            coordinator.spans(
                from: MarkdownSelectionEndpoint(segmentID: "paragraph", offset: 6),
                to: MarkdownSelectionEndpoint(segmentID: "paragraph-2", offset: 3)
            ),
            [
                MarkdownSelectionSpan(segmentID: "paragraph", range: NSRange(location: 6, length: 10)),
                MarkdownSelectionSpan(segmentID: "table-r0-c0", range: NSRange(location: 0, length: 1)),
                MarkdownSelectionSpan(segmentID: "table-r0-c1", range: NSRange(location: 0, length: 1)),
                MarkdownSelectionSpan(segmentID: "code", range: NSRange(location: 0, length: 9)),
                MarkdownSelectionSpan(segmentID: "paragraph-2", range: NSRange(location: 0, length: 3))
            ]
        )
    }

    func testReverseSelectionNormalizesOnlyForRangeResolution() {
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments([
            MarkdownSelectionSegmentDescriptor(id: "a", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "b", order: 1, separatorBefore: "\n\n")
        ], revision: "v1")

        let ordered = coordinator.orderedEndpoints(
            from: MarkdownSelectionEndpoint(segmentID: "b", offset: 5),
            to: MarkdownSelectionEndpoint(segmentID: "a", offset: 2)
        )
        XCTAssertEqual(ordered.start, MarkdownSelectionEndpoint(segmentID: "a", offset: 2))
        XCTAssertEqual(ordered.end, MarkdownSelectionEndpoint(segmentID: "b", offset: 5))
    }
}
```

- [ ] **Step 2: Run the new tests and confirm they fail because the segment API does not exist**

Run the focused command from Global Constraints. Expected: compilation failure naming the missing segment types and coordinator methods.

- [ ] **Step 3: Implement the pure segment API and clamped range resolution**

Implement `replaceSegments` by sorting descriptors on `order`, resetting all active selection state when `revision` changes, and retaining only the latest descriptor for a duplicate `id`. Resolve a forward or reverse endpoint pair by segment order; clamp offsets to each registered text view’s UTF-16 length. Emit a first-segment partial span, full intermediate spans, and a final-segment partial span. For a same-segment selection, emit one normalized range. The unit tests register concrete text views so expected lengths are deterministic.

- [ ] **Step 4: Run the focused tests and confirm the model passes**

Run the focused command. Expected: the new range tests pass and the existing selection tests remain green.

- [ ] **Step 5: Commit the model as an independently reviewable change**

```bash
git add Conduit/Views/Components/MarkdownSelectionCoordinator.swift ConduitTests/MarkdownSelectionCoordinatorTests.swift
git commit -m "test: define cross-block markdown selection ranges"
```

### Task 2: Add registration and touch hooks without changing standalone selection

**Files:**
- Modify: `Conduit/Views/Components/SelectableTextView.swift`
- Modify: `ConduitTests/ChatTextSelectionTests.swift`
- Modify: `ConduitTests/MarkdownSelectionCoordinatorTests.swift`

**Interfaces:**
- `SelectableTextView` gains optional `selectionCoordinator: MarkdownSelectionCoordinator?` and `selectionSegment: MarkdownSelectionSegmentDescriptor?` parameters on all initializers, defaulting to `nil`.
- The existing `makeTextView()` test helper continues to return an uncoordinated, non-editable, non-scrolling `UITextView`.
- A coordinated text view reports `touchesBegan`, `textViewDidChangeSelection`, and `copy(_:)` to the coordinator, and unregisters on dismantle.

- [ ] **Step 1: Add failing tests for the optional hook and coordinated registration**

```swift
@MainActor
func testUncoordinatedSelectableTextViewRetainsNativeConfiguration() {
    let view = SelectableTextView.makeTextView()
    XCTAssertFalse(view.isEditable)
    XCTAssertTrue(view.isSelectable)
    XCTAssertFalse(view.isScrollEnabled)
}

@MainActor
func testRegisteredTextViewSuppliesItsAttributedTextToTheCoordinator() {
    let coordinator = MarkdownSelectionCoordinator()
    let descriptor = MarkdownSelectionSegmentDescriptor(id: "code", order: 0, separatorBefore: "")
    let textView = SelectableTextView.makeTextView()
    textView.attributedText = NSAttributedString(string: "let value = 1")
    coordinator.register(descriptor: descriptor, textView: textView)

    XCTAssertEqual(coordinator.text(for: "code")?.string, "let value = 1")
}
```

- [ ] **Step 2: Run the tests and confirm the registration API is missing**

Run the focused command. Expected: compilation failure for `register`/`text(for:)` and no production behavior change yet.

- [ ] **Step 3: Implement opt-in coordinated UIKit behavior**

Add a private `MarkdownSelectionTextView: UITextView` subclass with an `onTouchBegan` closure. In `makeUIView`, create that subclass only when both optional coordinator and segment are present; otherwise keep the existing `UITextView` path. Convert the touch point to window coordinates before calling `coordinator.beginSelection`. In the representable coordinator, keep the current link delegate implementation and add `textViewDidChangeSelection` forwarding. Implement `dismantleUIView` to nil the delegate and callbacks, resign first responder, and unregister the exact view instance. Do not add a global gesture recognizer in this task.

- [ ] **Step 4: Add the coordinated copy entry point while preserving ordinary copy**

Override `copy(_:)` in the subclass. If the response coordinator has a cross-segment active selection, write the coordinator’s attributed result to the pasteboard and return; otherwise call `super.copy(_:)`. Keep the native `shouldInteractWith` link delegate unchanged so a normal link tap still opens the URL.

- [ ] **Step 5: Run tests and commit the opt-in bridge**

Run the focused command. Expected: all current selection/link tests pass, the registration test passes, and standalone tool text remains unaffected.

```bash
git add Conduit/Views/Components/SelectableTextView.swift ConduitTests/ChatTextSelectionTests.swift ConduitTests/MarkdownSelectionCoordinatorTests.swift
git commit -m "feat: register coordinated markdown text surfaces"
```

### Task 3: Implement the response host gesture, endpoint geometry, and highlights

**Files:**
- Modify: `Conduit/Views/Components/MarkdownSelectionCoordinator.swift`
- Modify: `Conduit/Views/Components/SelectableTextView.swift`
- Modify: `Conduit/Views/Components/MarkdownText.swift`
- Modify: `ConduitTests/MarkdownSelectionCoordinatorTests.swift`

**Interfaces:**
- `MarkdownSelectionCoordinator` exposes `beginSelection(segmentID:offset:windowPoint:)`, `updateSelection(windowPoint:)`, `updateSelection(segmentID:offset:windowPoint:)`, `endSelection()`, `hasActiveSelection`, `hasCrossSegmentSelection`, `activeSpans`, and `highlightRects(in:)`.
- The host modifier is `MarkdownSelectionHost(coordinator:)`; it attaches a simultaneous `DragGesture(minimumDistance: 0, coordinateSpace: .global)` and a non-interactive highlight overlay.
- Endpoint resolution uses the registered text view’s current `window` frame and `layoutManager`; no cached frame is used across a scroll or layout pass.

- [ ] **Step 1: Write failing geometry and lifecycle tests**

```swift
@MainActor
func testEndingOutsideTheFirstSegmentProducesAForwardCrossBlockSelection() {
    let coordinator = MarkdownSelectionCoordinator()
    coordinator.replaceSegments([
        MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
        MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
    ], revision: "v1")
    coordinator.beginSelection(segmentID: "first", offset: 6, windowPoint: CGPoint(x: 20, y: 20))
    coordinator.updateSelection(segmentID: "second", offset: 4, windowPoint: CGPoint(x: 20, y: 120))

    XCTAssertTrue(coordinator.hasCrossSegmentSelection)
    XCTAssertEqual(coordinator.activeSpans.map(\.segmentID), ["first", "second"])
}

@MainActor
func testRevisionChangeClearsStaleSelectionAndRegistrations() {
    let coordinator = MarkdownSelectionCoordinator()
    coordinator.replaceSegments([
        MarkdownSelectionSegmentDescriptor(id: "old", order: 0, separatorBefore: "")
    ], revision: "old")
    coordinator.beginSelection(segmentID: "old", offset: 0, windowPoint: .zero)
    coordinator.replaceSegments([
        MarkdownSelectionSegmentDescriptor(id: "new", order: 0, separatorBefore: "")
    ], revision: "new")

    XCTAssertFalse(coordinator.hasActiveSelection)
    XCTAssertNil(coordinator.text(for: "old"))
}
```

- [ ] **Step 2: Run the tests and verify the geometry/lifecycle API fails**

Run the focused command. Expected: compilation failure for the host lifecycle methods.

- [ ] **Step 3: Implement pointer-to-caret resolution and nested-scroll-safe registration**

When a coordinated text view begins, store the fixed anchor endpoint. On each host gesture update, locate the registered text view whose converted window bounds contains the pointer. Convert the global pointer into that text view’s coordinate system and call `layoutManager.characterIndex(for:in:fractionOfDistanceBetweenInsertionPoints:)`, clamping to `[0, textStorage.length]`. Because frames are converted from the current view hierarchy on every update, a table or code horizontal scroll automatically participates in hit testing. Do not let a pointer outside every segment erase the last valid endpoint; retain the last segment until the gesture ends.

- [ ] **Step 4: Add the simultaneous host gesture and highlight overlay**

Add `MarkdownSelectionHost` as a `ViewModifier` around the fallback `VStack`. Its gesture does nothing unless the coordinator has an active anchor, so ordinary taps, link activation, table horizontal scrolling, and the code copy button keep their existing recognizers. On selection updates, assign the resolved local `selectedRange` to registered text views and call `objectWillChange`. Add a `UIViewRepresentable` overlay with `isUserInteractionEnabled = false` that converts `highlightRects(in:)` from window coordinates into its own bounds and draws translucent selection rectangles for non-active segments. Keep native handles and the edit menu on the active endpoint text view.

- [ ] **Step 5: Run focused tests and commit the host behavior**

Run the focused command. Expected: model, bridge, and existing link tests pass.

```bash
git add Conduit/Views/Components/MarkdownSelectionCoordinator.swift Conduit/Views/Components/SelectableTextView.swift Conduit/Views/Components/MarkdownText.swift ConduitTests/MarkdownSelectionCoordinatorTests.swift
git commit -m "feat: coordinate selection across markdown text blocks"
```

### Task 4: Wire stable segment IDs into every rich Markdown text surface

**Files:**
- Modify: `Conduit/Views/Components/MarkdownText.swift`
- Modify: `ConduitTests/MarkdownSelectionCoordinatorTests.swift`
- Modify: `ConduitTests/ChatTextSelectionTests.swift`

**Interfaces:**
- `MarkdownSelectionSegmentPlan.descriptors(for:)` is the single source for rendered order and IDs.
- `MarkdownBlockView` receives `blockIndex` and an optional `MarkdownSelectionCoordinator`.
- `InlineMarkdown`, heading/list/quote/callout/columns views, `MarkdownTable`, and `ChatCodeBlock` receive a descriptor and pass it into their `SelectableTextView`.

- [ ] **Step 1: Write failing plan tests for the actual parser output**

```swift
func testMixedMarkdownPlanIncludesTableCellsRowMajorAndOneCodeSegment() {
    let blocks = MarkdownParser.parse(
        "Before\n\n| A | B |\n| --- | --- |\n| [link](https://example.com) | 2 |\n\n```swift\nlet x = 1\n```\n\nAfter",
        recognizesGatewayMedia: false
    )

    XCTAssertEqual(
        MarkdownSelectionSegmentPlan.descriptors(for: blocks).map(\.id),
        ["block-0", "block-1-table-r0-c0", "block-1-table-r0-c1", "block-1-table-r1-c0", "block-1-table-r1-c1", "block-2-code", "block-3"]
    )
}
```

- [ ] **Step 2: Run the plan test and verify mixed blocks are not yet described**

Run the focused command. Expected: failure because the fallback renderer has no segment plan.

- [ ] **Step 3: Implement stable IDs, separators, and coordinator lifetime in `MarkdownText`**

Keep the paragraph-only `rendering.selectableText` branch exactly as the fast path. For the fallback branch, create one `@StateObject` coordinator per `MarkdownText` identity, replace its descriptors using the exact `source` revision, and attach `MarkdownSelectionHost` plus the highlight overlay to the response `VStack`. Use `block-(index)` for a single text block, `block-(index)-table-r(row)-c(column)` in row-major order, and `block-(index)-code` for ordinary fenced code. Use `\n\n` between Markdown blocks, ` | ` within a table row, and `\n` between table rows as the `separatorBefore` values. Exclude images, dividers, Mermaid/LaTeX previews, and other non-text blocks from the plan.

- [ ] **Step 4: Pass descriptors through the rich block tree without flattening the visual layout**

Add the optional descriptor to each `SelectableTextView` used by `InlineMarkdown` and the code/table paths. Preserve the existing SwiftUI `VStack`/`HStack`, `ScrollView(.horizontal)`, padding, backgrounds, syntax highlighter, links, and copy buttons. Table cells continue to render as individual cells; their only new behavior is registration with the response coordinator. Tool-card `SelectableTextView`s in `ChatView.swift` receive no descriptor and remain independent.

- [ ] **Step 5: Add copy and link regression assertions**

Register a table-cell attributed string containing a URL and a code string, select from the paragraph through the code, and assert that copied text contains the configured separators, the link display text, and the `.link` URL attribute on the copied link run. Keep the existing `testMarkdownBridgePreservesEmphasisCodeAndLinks` as the standalone link contract.

- [ ] **Step 6: Run the focused suite and commit the renderer integration**

Run the focused command. Expected: all selection tests pass, including mixed paragraph/table/code ordering and link preservation.

```bash
git add Conduit/Views/Components/MarkdownText.swift ConduitTests/MarkdownSelectionCoordinatorTests.swift ConduitTests/ChatTextSelectionTests.swift
git commit -m "feat: enable cross-block selection in rich markdown"
```

### Task 5: Verify the user-visible selection contract on Simulator

**Files:**
- No source changes unless a verification failure identifies a specific regression.
- Test evidence: `ConduitTests/MarkdownSelectionCoordinatorTests.swift`, `ConduitTests/ChatTextSelectionTests.swift`.

- [ ] **Step 1: Run the focused and full unit suites**

Run the focused command, then run:

```bash
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both commands finish with `TEST SUCCEEDED` and no new warnings that indicate a selection or layout failure.

- [ ] **Step 2: Exercise both selection directions and nested scrolling manually**

On the iPhone 17 Pro Simulator, open a response containing a paragraph, a Markdown table with a link, a fenced code block, and a trailing paragraph. Long-press/drag paragraph→table→code→paragraph, then repeat in reverse. Confirm every intermediate segment is highlighted, copy includes the expected separators, and the table remains horizontally scrollable. Tap the link without selecting and after clearing a selection; confirm it opens normally. Repeat at larger Dynamic Type sizes and in both color schemes.

- [ ] **Step 3: Commit only verified test adjustments**

If a test needed a deterministic UIKit layout fixture, add that fixture and run the full suite again before committing it. Do not weaken a test to hide a simulator-only gesture failure; record the exact failure in the handoff instead.
