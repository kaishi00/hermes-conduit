//
//  StarterFaces.swift
//  Conduit
//
//  Starter faces (Eric, 2026-11-17): a bot with no picture of its own shows
//  one of twelve small robot faces, each with its own color, instead of its
//  initial on a color. They're for people who haven't given their bots
//  pictures yet, a new Hermes included, so the first bots get the best ones
//  and no two share a color. The faces are drawn here, never stored as
//  pictures: the bot still has no picture, and the first one it's given
//  replaces its face.
//
//  Which face a bot wears is `ui_meta['hermes-bots'].face`, written when
//  Conduit makes the bot or when one is picked in Edit Bot, so every phone
//  shows the same one. A bot without it gets the first face no other bot
//  on its Hermes has, in the order the bots were made (the main bot first),
//  so reordering never moves a face. Desktop ignores the key.
//

import SwiftUI
import UIKit

/// One face: its color and the parts it's drawn from.
struct StarterFace: Equatable, Hashable {
    enum Antenna: Equatable, Hashable { case none, pair, ball, nub }
    enum Head: Equatable, Hashable { case square, round, wide }
    enum Eyes: Equatable, Hashable { case dots, pills, wideDots, bigDots }
    /// What VoiceOver calls a face of the set, by its color.
    enum ColorName: Equatable, Hashable { case purple, skyBlue, orange, mint, yellow, pink, blue, cyan, red, lime, magenta, gray }

    /// Degrees, 0..<360.
    let hue: Double
    /// 0...1.
    let saturation: Double
    let antenna: Antenna
    let bolts: Bool
    let head: Head
    let eyes: Eyes
    /// The set's faces only; one past the twelve has none.
    var colorName: ColorName? = nil

    /// The face's color, behind the head. A near-gray face sits a little
    /// darker so its white head still stands out.
    var rgb: BotAvatarColor.RGB {
        BotAvatarColor.hslToRGB(hue: hue, saturation: saturation, lightness: saturation < 0.3 ? 0.5 : 0.58)
    }

    /// The face's color as a bot's color is written in ui_meta.
    var hex: String {
        let rgb = rgb
        return ProfileGlowRGB(red: rgb.red, green: rgb.green, blue: rgb.blue).hex
    }

    var color: Color {
        let rgb = rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// The head: near white, in the face's hue.
    var headColor: Color {
        let rgb = BotAvatarColor.hslToRGB(hue: hue, saturation: 0.35, lightness: 0.94)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// The eyes and bolts: near black, in the face's hue.
    var inkColor: Color {
        let rgb = BotAvatarColor.hslToRGB(hue: hue, saturation: 0.4, lightness: 0.16)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

enum StarterFaces {
    /// The ui_meta key that holds a bot's face number.
    static let metaKey = "face"

    /// The twelve, in the order they're handed out: the colors far apart
    /// for the first few bots, the parts varied a little.
    static let set: [StarterFace] = [
        StarterFace(hue: 262, saturation: 0.62, antenna: .pair, bolts: true, head: .square, eyes: .dots, colorName: .purple),
        StarterFace(hue: 205, saturation: 0.58, antenna: .none, bolts: false, head: .square, eyes: .dots, colorName: .skyBlue),
        StarterFace(hue: 12, saturation: 0.70, antenna: .ball, bolts: true, head: .wide, eyes: .pills, colorName: .orange),
        StarterFace(hue: 158, saturation: 0.52, antenna: .none, bolts: true, head: .round, eyes: .dots, colorName: .mint),
        StarterFace(hue: 40, saturation: 0.78, antenna: .nub, bolts: false, head: .square, eyes: .wideDots, colorName: .yellow),
        StarterFace(hue: 318, saturation: 0.58, antenna: .pair, bolts: false, head: .round, eyes: .bigDots, colorName: .pink),
        StarterFace(hue: 225, saturation: 0.60, antenna: .none, bolts: true, head: .wide, eyes: .dots, colorName: .blue),
        StarterFace(hue: 180, saturation: 0.55, antenna: .ball, bolts: false, head: .square, eyes: .pills, colorName: .cyan),
        StarterFace(hue: 350, saturation: 0.72, antenna: .none, bolts: false, head: .round, eyes: .wideDots, colorName: .red),
        StarterFace(hue: 95, saturation: 0.48, antenna: .pair, bolts: true, head: .square, eyes: .bigDots, colorName: .lime),
        StarterFace(hue: 290, saturation: 0.58, antenna: .nub, bolts: true, head: .wide, eyes: .dots, colorName: .magenta),
        StarterFace(hue: 215, saturation: 0.18, antenna: .ball, bolts: false, head: .round, eyes: .dots, colorName: .gray)
    ]

    /// Face `index`. Past the twelve, the parts and colors keep varying:
    /// the hue steps by the golden angle so neighbors stay apart.
    static func face(_ index: Int) -> StarterFace {
        let index = max(0, index)
        if index < set.count { return set[index] }
        let antennas: [StarterFace.Antenna] = [.none, .pair, .ball, .nub]
        let heads: [StarterFace.Head] = [.square, .round, .wide]
        let eyes: [StarterFace.Eyes] = [.dots, .pills, .wideDots, .bigDots]
        let hue = (262 + Double(index) * 137.508).truncatingRemainder(dividingBy: 360)
        return StarterFace(
            hue: hue,
            saturation: 0.6,
            antenna: antennas[index % antennas.count],
            bolts: index % 2 == 1,
            head: heads[(index / 2) % heads.count],
            eyes: eyes[(index / 3) % eyes.count]
        )
    }

    /// A face drawn as a square picture, for what takes a picture rather
    /// than a view (the looks a linked room sends). The same face and color
    /// give the same image, so a share sees no change.
    @MainActor
    static func image(_ face: StarterFace, color: String?) -> UIImage? {
        let key = "\(face.hashValue)|\(color ?? "")"
        if let drawn = drawnImages[key] { return drawn }
        let renderer = ImageRenderer(content: StarterFaceView(
            face: face,
            background: color.map { BotAvatarView.color(for: $0, name: "") }
        ).frame(width: 256, height: 256))
        renderer.scale = 1
        guard let image = renderer.uiImage else { return nil }
        drawnImages[key] = image
        return image
    }

    @MainActor private static var drawnImages: [String: UIImage] = [:]

    /// The face number a bot's ui_meta holds, if any.
    static func storedFace(in meta: [String: AnyCodable]) -> Int? {
        guard let value = meta[metaKey]?.intValue, value >= 0 else { return nil }
        return value
    }

    /// The bots with their faces: the one each holds (ui_meta's, else the
    /// one a kept copy carries), then the first free face for each of the
    /// rest, in the order they were made. Two bots that hold the same face
    /// both keep it: it was picked.
    static func assign(_ bots: [BotProfile]) -> [BotProfile] {
        var faces: [String: Int] = [:]
        var taken = Set<Int>()
        for bot in bots {
            if let face = storedFace(in: bot.botMeta) ?? bot.starterFace {
                faces[bot.name] = face
                taken.insert(face)
            }
        }
        var next = 0
        for bot in bots.filter({ faces[$0.name] == nil }).sorted(by: madeEarlier) {
            while taken.contains(next) { next += 1 }
            faces[bot.name] = next
            taken.insert(next)
        }
        return bots.map { bot in
            var bot = bot
            bot.starterFace = faces[bot.name]
            return bot
        }
    }

    /// The face a new bot gets: the first one no bot in `bots` wears.
    static func nextFree(after bots: [BotProfile]) -> Int {
        let taken = Set(bots.compactMap(\.starterFace))
        var next = 0
        while taken.contains(next) { next += 1 }
        return next
    }

    /// The main bot first, then by when ui_meta says the bot was made, then
    /// by name (a bot with no date after the dated ones).
    private static func madeEarlier(_ lhs: BotProfile, _ rhs: BotProfile) -> Bool {
        let lhsMain = lhs.isDefault || BotManagement.isDefaultProfile(lhs.name)
        let rhsMain = rhs.isDefault || BotManagement.isDefaultProfile(rhs.name)
        if lhsMain != rhsMain { return lhsMain }
        let lhsMade = lhs.botMeta["created"]?.doubleValue
        let rhsMade = rhs.botMeta["created"]?.doubleValue
        switch (lhsMade, rhsMade) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.name < rhs.name
        }
    }
}

/// A starter face, drawn at any size in a 100-point square scaled to fit,
/// clipped to a circle by its caller.
struct StarterFaceView: View {
    let face: StarterFace
    /// The bot's own color when one was picked for it; else the face's.
    var background: Color? = nil

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 100
            func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect {
                CGRect(x: x * unit, y: y * unit, width: width * unit, height: height * unit)
            }
            func rounded(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double) -> Path {
                Path(roundedRect: rect(x, y, width, height), cornerRadius: radius * unit, style: .continuous)
            }
            func circle(_ x: Double, _ y: Double, _ radius: Double) -> Path {
                Path(ellipseIn: rect(x - radius, y - radius, radius * 2, radius * 2))
            }
            func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: x1 * unit, y: y1 * unit))
                path.addLine(to: CGPoint(x: x2 * unit, y: y2 * unit))
                return path
            }
            let head = GraphicsContext.Shading.color(face.headColor)
            let ink = GraphicsContext.Shading.color(face.inkColor)
            context.fill(Path(rect(0, 0, 100, 100)), with: .color(background ?? face.color))

            let width: Double = face.head == .wide ? 54 : 46
            let height: Double = 40
            let x = 50 - width / 2
            let y: Double = 34
            switch face.antenna {
            case .none:
                break
            case .pair:
                let stroke = StrokeStyle(lineWidth: 3.4 * unit, lineCap: .round)
                context.stroke(line(43, y + 1, 38, y - 10), with: head, style: stroke)
                context.stroke(line(57, y + 1, 62, y - 10), with: head, style: stroke)
            case .ball:
                context.stroke(line(50, y, 50, y - 9), with: head, style: StrokeStyle(lineWidth: 3.2 * unit, lineCap: .round))
                context.fill(circle(50, y - 12, 4), with: head)
            case .nub:
                context.fill(rounded(46, y - 6, 8, 8, 2.5), with: head)
            }
            if face.bolts {
                context.fill(rounded(x - 5, y + 12, 8, 16, 3.5), with: ink)
                context.fill(rounded(x + width - 3, y + 12, 8, 16, 3.5), with: ink)
            }
            context.fill(rounded(x, y, width, height, face.head == .round ? 18 : 13), with: head)

            let eyeY = y + height / 2 + 1
            let gap: Double = face.eyes == .wideDots ? 11 : 8.5
            switch face.eyes {
            case .dots, .wideDots:
                context.fill(circle(50 - gap, eyeY, 4.6), with: ink)
                context.fill(circle(50 + gap, eyeY, 4.6), with: ink)
            case .pills:
                context.fill(rounded(50 - gap - 3.6, eyeY - 6, 7.2, 12, 3.6), with: ink)
                context.fill(rounded(50 + gap - 3.6, eyeY - 6, 7.2, 12, 3.6), with: ink)
            case .bigDots:
                context.fill(circle(50 - gap - 0.5, eyeY, 6), with: ink)
                context.fill(circle(50 + gap + 0.5, eyeY, 6), with: ink)
                context.fill(circle(50 - gap + 1.5, eyeY - 2, 1.7), with: .color(.white))
                context.fill(circle(50 + gap + 2.5, eyeY - 2, 1.7), with: .color(.white))
            }
        }
    }
}

/// The faces of the bots by profile name, for the views that draw a profile
/// rather than a bot (ProfileAvatarView): the dashboard on screen's, and each
/// other combined dashboard's as its last read listed them. AppState keeps
/// it in step with both.
@MainActor
@Observable
final class BotFaceDirectory {
    static let shared = BotFaceDirectory()

    struct Look: Equatable {
        let face: StarterFace
        /// The bot's color string, picked or the face's.
        let color: String?
    }

    private(set) var looks: [String: Look] = [:]
    /// Each other combined dashboard's, by its id.
    private(set) var otherLooks: [UUID: [String: Look]] = [:]

    /// The profile's look on `dashboardID` (nil: the one on screen) by its
    /// exact name, else by a name that differs only in case when just one
    /// bot has it. Nil when that dashboard's bots aren't known here.
    func look(for profile: String, on dashboardID: UUID? = nil) -> Look? {
        guard let looks = dashboardID.map({ otherLooks[$0] ?? [:] }) ?? Optional(self.looks) else { return nil }
        if let exact = looks[profile] { return exact }
        let folded = looks.filter { $0.key.caseInsensitiveCompare(profile) == .orderedSame }
        return folded.count == 1 ? folded.first?.value : nil
    }

    func update(_ bots: [BotProfile]) {
        let next = Self.looks(of: bots)
        if next != looks { looks = next }
    }

    func updateOthers(_ bots: [UUID: [BotProfile]]) {
        let next = bots.mapValues(Self.looks(of:))
        if next != otherLooks { otherLooks = next }
    }

    private static func looks(of bots: [BotProfile]) -> [String: Look] {
        var looks: [String: Look] = [:]
        for bot in bots {
            guard let face = bot.faceLook else { continue }
            looks[bot.name] = Look(face: face, color: bot.shownColor)
        }
        return looks
    }
}
