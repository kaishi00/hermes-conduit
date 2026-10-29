//
//  ColumnDivider.swift
//  Conduit
//
//  A wide window's resizable columns (#1487): the chat list beside a chat,
//  the drawer shell's persistent sidebar, and Artifacts beside a chat. The
//  line between a column and the chat drags to resize it; a double-click or
//  double-tap puts it back. Each width is kept per device, as hiding the
//  list is, and gives way to the chat's least width on a smaller window.
//

import SwiftUI

/// One resizable column's widths. The user's width is stored; what shows is
/// that width within the column's bounds and the room the window leaves it.
struct ColumnWidth {
    /// The `@AppStorage` key of the user's width.
    let key: String
    /// The width before the user drags it, and after a reset.
    let standard: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat

    /// The column's width in a window `window` wide, where the chat beside
    /// it keeps `keeping` and a 1 pt line parts them. The window decides
    /// whether the column shows at all, at its least width (`fits`), so
    /// this never takes it below `minimum`.
    func resolved(_ stored: Double, window: CGFloat, keeping: CGFloat) -> CGFloat {
        let wanted = stored.isFinite ? CGFloat(stored) : standard
        let room = window - keeping - 1
        return max(minimum, min(wanted, maximum, room))
    }

    /// Where a drag leaves the column: its width when the drag began plus
    /// the pointer's travel, within its bounds and the room it has now. A
    /// width dragged on a small window isn't stored past what showed.
    func dragged(from start: CGFloat, by translation: CGFloat, room: CGFloat) -> CGFloat {
        max(minimum, min(start + translation, maximum, max(minimum, room)))
    }

    /// One VoiceOver adjustment's step.
    static let accessibilityStep: CGFloat = 40
}

/// The 1 pt line between a column and the chat, with a wider grip that
/// drags the column's width and resets it on a double-click.
struct ColumnDivider: View {
    let widths: ColumnWidth
    /// The column's width as laid out.
    let width: CGFloat
    /// The widest the column can be in this window.
    let room: CGFloat
    /// Which side of the line the column is on: dragging away from it
    /// widens it.
    let columnEdge: HorizontalEdge
    /// What VoiceOver calls the line, such as "Chat list width".
    let label: String
    @Binding var stored: Double
    /// The width while a drag is under way, which the parent lays the
    /// column out at. It goes to `stored` once, when the drag ends: every
    /// defaults write redraws each `@AppStorage` view, whatever its key.
    @Binding var live: CGFloat?

    /// Reset when the drag ends or the system cancels it.
    @GestureState private var dragStart: CGFloat?
    /// The width the drag began at, which `commit` compares with, as the
    /// gesture state is reset by then.
    @State private var dragBegan: CGFloat?
    /// The pointer's travel when the drag was recognized (its least
    /// distance), left out so the line doesn't jump to catch up.
    @State private var dragSlop: CGFloat = 0
    @State private var isHovering = false

    private static let gripWidth: CGFloat = 12

    private var direction: CGFloat { columnEdge == .leading ? 1 : -1 }
    private var isActive: Bool { isHovering || dragStart != nil }

    var body: some View {
        Rectangle()
            .fill(isActive ? Color.conduitAccent.opacity(0.6) : Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay {
                // The grip reaches past the line into both columns, so a
                // finger or the pointer needn't find a single point. The
                // divider sits above the columns (zIndex) to take it.
                Rectangle()
                    .fill(isActive ? Color.conduitAccent.opacity(0.18) : Color.clear)
                    .frame(width: Self.gripWidth)
                    .contentShape(Rectangle())
                    .onHover { isHovering = $0 }
                    .onTapGesture(count: 2) { reset() }
                    .gesture(drag)
                    .macTooltip(AppLocalization.string("Drag to resize. Double-click to reset."))
            }
            .ignoresSafeArea()
            .zIndex(1)
            .animation(.easeOut(duration: 0.12), value: isActive)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(Text(Double(width / widths.standard), format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(width + ColumnWidth.accessibilityStep)
                case .decrement: set(width - ColumnWidth.accessibilityStep)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Reset width")) { reset() }
            .onChange(of: dragStart == nil) { _, ended in
                if ended { commit() }
            }
            // Gone mid-drag (a rotation, a window crossing the split): the
            // gesture's end never comes.
            .onDisappear { commit() }
    }

    /// Measured in the window, so the line moving with the column doesn't
    /// move the drag's own frame of reference.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($dragStart) { value, start, _ in
                let from = start ?? width
                // State set here reads back only from the next update.
                let slop = start == nil ? value.translation.width : dragSlop
                if start == nil {
                    dragBegan = from
                    dragSlop = slop
                }
                start = from
                live = widths.dragged(from: from, by: (value.translation.width - slop) * direction, room: room)
            }
    }

    /// Stores the dragged width, once, and hands the layout back to it. A
    /// press that didn't move the line keeps the stored width, which a
    /// smaller window may be showing less of.
    private func commit() {
        defer {
            live = nil
            dragBegan = nil
        }
        guard let width = live, abs(width - (dragBegan ?? width)) >= 1 else { return }
        stored = Double(width)
    }

    /// A step that can't move the line (at a bound, or a window showing
    /// less than the stored width) keeps the stored width.
    private func set(_ newWidth: CGFloat) {
        let width = widths.dragged(from: newWidth, by: 0, room: room)
        guard abs(width - self.width) >= 1 else { return }
        stored = Double(width)
    }

    private func reset() {
        Haptics.light()
        stored = Double(widths.standard)
    }
}
