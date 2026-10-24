import XCTest

/// Every icon-only button or menu under Conduit/Views has a spoken name, so
/// VoiceOver never reads a bare "Button" or the SF Symbol's name.
///
/// Text-level, like PrivacyManifestTests: it reads the Swift sources, not the
/// view tree. A control is icon-only when an `Image(systemName:` sits within 4
/// lines after a `Button(`, `Button {`, `Menu(`, `Menu {` or `} label: {` line
/// (the owner; a helper such as `sortMenu {` counts as its control). From
/// the image it scans forward until a line indented less than the owner, the
/// next `Button`/`Menu` at the owner's depth, another control's
/// `Image(systemName:` (one with its own owner within 4 lines above) once the
/// label closure has closed, or 25 lines. An image without an owner, like a
/// large content viewer's icon, belongs to the same control; so does a
/// separate control's image nested 5 or more lines below its owner. A
/// `.accessibilityLabel(` or `.accessibilityHidden(true)` anywhere in that
/// span names it; `Text(` or `Label(` name it only inside the label closure
/// itself. `.help(` doesn't count: on iOS it is a hint, not a name.
///
/// A control the heuristic can't see is named elsewhere (a helper whose call
/// sites add the label) goes in `allowed`, keyed by file and trimmed line text
/// so edits above it don't shift the key. An entry that no longer matches a
/// flagged site fails too, so the list never goes stale.
final class AccessibilityLabelAuditTests: XCTestCase {
    struct Site: Equatable {
        let key: String
        let line: Int
    }

    private static let allowed: Set<String> = [
        // reorderArrow(_:enabled:action:); both call sites add
        // "Move <profile> earlier/later".
        "Conduit/Views/ProfilePickerSheet.swift | Image(systemName: systemImage)",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ConduitTests
            .deletingLastPathComponent() // repo root
    }

    func testIconOnlyButtonsHaveAccessibilityLabels() throws {
        let viewsDir = Self.repoRoot.appendingPathComponent("Conduit/Views")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: viewsDir, includingPropertiesForKeys: nil))
        let viewsRoot = viewsDir.resolvingSymlinksInPath().path
        var flagged: [Site] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = "Conduit/Views" + url.resolvingSymlinksInPath().path.dropFirst(viewsRoot.count)
            let source = try String(contentsOf: url, encoding: .utf8)
            flagged += Self.unnamedIconButtons(in: source, path: path)
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 50, "Found too few view sources under \(viewsDir.path)")

        let unresolved = flagged.filter { !Self.allowed.contains($0.key) }
        XCTAssertTrue(
            unresolved.isEmpty,
            "Icon-only controls without an accessibility label (\(unresolved.count)):\n"
                + unresolved.map { "\($0.key) (line \($0.line))" }.joined(separator: "\n")
        )
        let stale = Self.allowed.subtracting(flagged.map(\.key))
        XCTAssertTrue(stale.isEmpty, "Allowlist entries that match no flagged site:\n" + stale.sorted().joined(separator: "\n"))
    }

    func testFlagsAnIconOnlyButtonWithoutALabel() {
        let source = """
            Button { clear() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        """
        XCTAssertEqual(
            Self.unnamedIconButtons(in: source, path: "A.swift"),
            [Site(key: "A.swift | Image(systemName: \"xmark.circle.fill\")", line: 2)]
        )
    }

    func testALabelAfterTheButtonStyleNamesTheButton() {
        // A custom style's name contains "Button"; it must not end the scan
        // before the label below it.
        let source = """
            Button {
                create()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canCreate)
            .accessibilityLabel(AppLocalization.string("New Bot"))
        """
        XCTAssertEqual(Self.unnamedIconButtons(in: source, path: "A.swift"), [])
    }

    func testTextInsideTheLabelNamesTheButton() {
        let source = """
            Button(action: open) {
                Image(systemName: "folder")
                Text("Open")
            }
        """
        XCTAssertEqual(Self.unnamedIconButtons(in: source, path: "A.swift"), [])
    }

    func testALabelAfterALargeContentViewerNamesTheButton() {
        // The viewer's icon belongs to the same control; it must not end the
        // scan before the label below it.
        let source = """
            Button { dictate() } label: {
                Image(systemName: "mic")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityShowsLargeContentViewer {
                Label {
                    Text("Dictate")
                } icon: {
                    Image(systemName: "mic")
                }
            }
            .accessibilityLabel(Text("Dictate"))
        """
        XCTAssertEqual(Self.unnamedIconButtons(in: source, path: "A.swift"), [])
    }

    func testANestedNextControlsImageEndsTheSpan() {
        // The next control sits deeper than the owner, so only its image can
        // end the earlier control's span before its label.
        let source = """
            VStack {
                Button { back() } label: {
                    Image(systemName: "chevron.left")
                }
                if showsForward {
                    Button { forward() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("Forward")
                }
            }
        """
        XCTAssertEqual(
            Self.unnamedIconButtons(in: source, path: "A.swift").map(\.line),
            [3]
        )
    }

    func testTheNextControlsLabelDoesNotNameAnEarlierOne() {
        let source = """
            HStack {
                Button { back() } label: {
                    Image(systemName: "chevron.left")
                }
                Button { forward() } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Forward")
            }
        """
        XCTAssertEqual(
            Self.unnamedIconButtons(in: source, path: "A.swift").map(\.line),
            [3]
        )
    }

    func testFlagsAnIconOnlyMenuWithoutALabel() {
        // A menu helper whose trailing closure is the label: no `label:`
        // line, so only the Menu owner sees the icon.
        let source = """
            HStack {
                sortMenu {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        """
        XCTAssertEqual(
            Self.unnamedIconButtons(in: source, path: "A.swift").map(\.line),
            [3]
        )
    }

    // MARK: - Scanner

    private static let owners = ["Button(", "Button {", "Menu(", "Menu {", "} label: {"]
    private static let naming = [".accessibilityLabel(", ".accessibilityHidden(true)"]
    private static let labelContent = ["Text(", "Label("]

    private static func indent(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// The nearest owner line within 4 lines above `index`.
    private static func ownerLine(above index: Int, in lines: [String]) -> Int? {
        (max(0, index - 4)..<index).reversed().first { j in
            owners.contains { lines[j].contains($0) }
        }
    }

    static func unnamedIconButtons(in source: String, path: String) -> [Site] {
        let lines = source.components(separatedBy: "\n")
        var flagged: [Site] = []
        for (i, line) in lines.enumerated() where line.contains("Image(systemName:") {
            guard let owner = ownerLine(above: i, in: lines) else { continue }
            let ownerIndent = indent(lines[owner])

            // A name on the image's own line, or label content before it.
            var named = naming.contains(where: { line.contains($0) })
                || labelContent.contains(where: { line.contains($0) })
            if lines[owner..<i].contains(where: { l in
                labelContent.contains { l.contains($0) } && !owners.contains { l.contains($0) }
            }) {
                named = true
            }

            var inLabelClosure = true
            var k = i + 1
            while !named, k < lines.count, k <= i + 25 {
                let current = k
                let l = lines[k]
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                k += 1
                guard !trimmed.isEmpty else { continue }
                let lineIndent = indent(l)
                if lineIndent < ownerIndent { break }
                // Another control's image ends the span; an image with no
                // owner of its own (a large content viewer's icon) doesn't.
                if !inLabelClosure, l.contains("Image(systemName:"), ownerLine(above: current, in: lines) != nil {
                    break
                }
                if lineIndent <= ownerIndent, trimmed.hasPrefix("Button") || trimmed.hasPrefix("Menu") { break }
                if naming.contains(where: { l.contains($0) }) { named = true; break }
                if inLabelClosure {
                    if lineIndent <= ownerIndent, trimmed.hasPrefix("}") {
                        inLabelClosure = false
                    } else if labelContent.contains(where: { l.contains($0) }) {
                        named = true
                    }
                }
            }
            if !named {
                let text = line.trimmingCharacters(in: .whitespaces)
                flagged.append(Site(key: "\(path) | \(text)", line: i + 1))
            }
        }
        return flagged
    }
}
