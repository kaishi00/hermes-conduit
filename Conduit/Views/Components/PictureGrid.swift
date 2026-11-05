import SwiftUI

/// Two or more pictures in one message, as square tiles side by side
/// instead of a stack of full pictures (issue 1801). As many go on a row as
/// the message's width takes, the rows kept even, so a wide chat on an iPad
/// or a Mac lays them out across and a phone two to a row. Past
/// `maxShown`, the last tile says how many more there are; a tap on any
/// tile opens the picture viewer, which pages through the rest.
enum PictureGrid {
    /// Space between tiles.
    static let spacing: CGFloat = 6
    /// Tiles shown at most; the last one shown carries the "+N".
    static let maxShown = 6
    /// The smallest a tile gets before the row takes one fewer.
    static let minTile: CGFloat = 104
    /// The largest a tile gets on a wide chat.
    static let maxTile: CGFloat = 180
    static let cornerRadius: CGFloat = 12

    /// How the tiles are laid out for a width.
    struct Plan: Equatable {
        let columns: Int
        let rows: Int
        let tile: CGFloat

        var size: CGSize {
            CGSize(
                width: CGFloat(columns) * tile + CGFloat(max(columns - 1, 0)) * PictureGrid.spacing,
                height: CGFloat(rows) * tile + CGFloat(max(rows - 1, 0)) * PictureGrid.spacing
            )
        }
    }

    /// The layout of `count` tiles in `width`. At least two to a row, as
    /// many as fit at `minTile`, then the rows evened out: six in a 640 pt
    /// column are two rows of three, not five and one. Without a width (a
    /// view asking for its ideal size) it is the width a row of every tile
    /// takes at `maxTile`, so a bubble that hugs its ideal width, as a
    /// group room's does, still offers the grid all the room it has.
    static func plan(count: Int, width: CGFloat?) -> Plan {
        guard count > 0 else { return Plan(columns: 0, rows: 0, tile: 0) }
        guard let width, width.isFinite else {
            return plan(count: count, width: CGFloat(count) * maxTile + CGFloat(count - 1) * spacing)
        }
        let fitting = max(2, Int((max(width, 0) + spacing) / (minTile + spacing)))
        let rows = (count + fitting - 1) / fitting
        let columns = (count + rows - 1) / rows
        let fill = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let tile = max(1, min(maxTile, fill.rounded(.down)))
        return Plan(columns: columns, rows: rows, tile: tile)
    }

    /// How many of `count` pictures get a tile.
    static func shownCount(_ count: Int) -> Int { min(count, maxShown) }

    /// The "+N" on the last tile shown: the pictures without a tile, and
    /// the one under the badge, which the badge covers. Nil when every
    /// picture has a tile of its own.
    static func moreCount(total: Int) -> Int? {
        total > maxShown ? total - maxShown + 1 : nil
    }
}

/// Lays its subviews out as `PictureGrid` plans, each proposed its tile.
struct PictureGridLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        PictureGrid.plan(count: subviews.count, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = PictureGrid.plan(count: subviews.count, width: proposal.width ?? bounds.width)
        guard plan.columns > 0 else { return }
        let tileProposal = ProposedViewSize(width: plan.tile, height: plan.tile)
        for (index, subview) in subviews.enumerated() {
            let column = index % plan.columns
            let row = index / plan.columns
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (plan.tile + PictureGrid.spacing),
                    y: bounds.minY + CGFloat(row) * (plan.tile + PictureGrid.spacing)
                ),
                proposal: tileProposal
            )
        }
    }
}

/// A tile's backing while its picture loads or when it won't: the tile's
/// shape, with a spinner or a symbol in it.
struct PictureTilePlaceholder: View {
    enum Kind { case loading, unavailable, attached }

    let state: Kind
    var onAccent = false

    var body: some View {
        RoundedRectangle(cornerRadius: PictureGrid.cornerRadius, style: .continuous)
            .fill(onAccent ? Color.white.opacity(0.13) : Color.primary.opacity(0.05))
            .overlay {
                switch state {
                case .loading:
                    ProgressView().tint(onAccent ? .white : nil)
                case .unavailable, .attached:
                    Image(systemName: state == .attached ? "photo" : "photo.badge.exclamationmark")
                        .scaledFont(.title3)
                        .foregroundStyle(onAccent ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
    }
}

/// A loaded picture filling its square tile, cropped, never stretched.
struct PictureTileImage: View {
    let image: UIImage
    var onAccent = false

    var body: some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(RoundedRectangle(cornerRadius: PictureGrid.cornerRadius, style: .continuous))
            .overlay {
                if onAccent {
                    RoundedRectangle(cornerRadius: PictureGrid.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
            }
    }
}

/// The "+N" over the last tile shown when a message has more pictures
/// than tiles. Taps go through to the tile, which opens the viewer there.
struct PictureGridMoreBadge: ViewModifier {
    let more: Int?

    func body(content: Content) -> some View {
        if let moreCount = more {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: PictureGrid.cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                        .overlay {
                            Text(verbatim: "+\(moreCount)")
                                .scaledFont(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .accessibilityValue(Text("\(moreCount) more images"))
        } else {
            content
        }
    }
}
