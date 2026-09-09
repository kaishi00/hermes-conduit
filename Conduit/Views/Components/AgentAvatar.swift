import Foundation
import SwiftUI
import UIKit

/// A profile keeps its character across renames, sessions, and app launches.
struct AgentAvatar: View {
    let profileID: String
    let displayName: String
    let photoURL: URL?
    var size: CGFloat = 40
    var showsSelectionRing = false
    var state: AgentAvatarState = .idle
    var animates = true
    var selection: AgentAvatarSelection?
    var previewImage: UIImage?
    @AppStorage(AgentAvatarSelectionStore.key) private var savedSelections = Data()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var stateStarted = Date()
    @State private var completionSettled = false

    private var motionEnabled: Bool {
        animates && visible && !reduceMotion && scenePhase == .active
            && !(state == .done && completionSettled)
    }

    var body: some View {
        let seed = AgentAvatarIdentity.seed(for: profileID)
        let choice = selection ?? AgentAvatarSelectionStore.selections(from: savedSelections)[profileID]
        let appearance = choice?.character ?? AgentAvatarAppearance.generated(for: profileID)
        let palette = AgentAvatarIdentity.palette(for: appearance.color.paletteSeed)
        let photo = choice?.usesPhoto == false ? nil : (previewImage ?? photoURL.flatMap { AgentAvatarImageCache.shared.image(at: $0) })
        TimelineView(.animation(minimumInterval: state == .idle ? 1.0 / 15 : 1.0 / 30,
                                paused: !motionEnabled || (photo != nil && state == .idle))) { context in
            let time = motionEnabled ? context.date.timeIntervalSinceReferenceDate : 0
            let pose = AgentAvatarPose(state: state, time: time,
                                       elapsed: context.date.timeIntervalSince(stateStarted),
                                       seed: seed, animated: motionEnabled)
            ZStack {
                Circle().fill(palette.background.gradient)
                if let photo {
                    Image(uiImage: photo)
                        .resizable().scaledToFill()
                        .frame(width: size, height: size).clipped()
                } else {
                    character(appearance: appearance, palette: palette, pose: pose)
                }
                if state != .idle {
                    Circle().trim(from: 0.03, to: state == .thinking || state == .working ? 0.76 : 0.97)
                        .stroke(state.tint.opacity(0.8), style: StrokeStyle(lineWidth: max(1.5, size * 0.025), lineCap: .round))
                        .rotationEffect(.degrees(state == .thinking || state == .working ? pose.orbit : -90))
                        .padding(size * 0.075)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(showsSelectionRing ? Color.conduitPrimaryAction : palette.fill.opacity(0.16),
                                      lineWidth: showsSelectionRing ? max(2.5, size * 0.035) : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if let symbol = state.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: max(7, size * 0.13), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.27, height: size * 0.27)
                        .background(state.tint, in: Circle())
                        .overlay { Circle().strokeBorder(Color.conduitCanvas, lineWidth: max(1, size * 0.025)) }
                }
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion || !animates ? nil : .spring(response: 0.38, dampingFraction: 0.72), value: state)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: state) {
            stateStarted = Date()
            completionSettled = false
            guard state == .done else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            completionSettled = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayName)
        .accessibilityValue(state.label)
    }

    private func character(appearance: AgentAvatarAppearance, palette: AgentAvatarIdentity.Palette, pose: AgentAvatarPose) -> some View {
        ZStack {
            Ellipse().fill(palette.face.opacity(0.13))
                .frame(width: size * 0.52, height: size * 0.075)
                .blur(radius: size * 0.025)
                .offset(y: size * 0.34)
                .scaleEffect(x: 1 - abs(pose.lift) * 2, y: 1)
            ZStack {
                AgentCharacterShape(kind: appearance.shape)
                    .fill(LinearGradient(colors: [palette.accent, palette.fill, palette.fill],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        AgentCharacterShape(kind: appearance.shape)
                            .stroke(Color.white.opacity(0.28), lineWidth: size * 0.012)
                    }
                    .shadow(color: palette.fill.opacity(0.28), radius: size * 0.045, x: 0, y: size * 0.04)
                    .frame(width: size * 0.71, height: size * 0.70)
                // A small reflected light gives the bodies a soft, tactile finish.
                Capsule().fill(.white.opacity(0.24))
                    .frame(width: size * 0.15, height: size * 0.035)
                    .rotationEffect(.degrees(-28))
                    .offset(x: -size * 0.17, y: -size * 0.23)
                AgentCharacterAccessory(kind: appearance.accessory)
                    .fill(appearance.accessory == .cheekDot
                          ? palette.accent.opacity(0.9) : palette.face.opacity(0.88))
                    .frame(width: size * 0.77, height: size * 0.77)
                AgentExpressiveFace(state: state, blink: pose.blink, gaze: pose.gaze, time: pose.faceTime)
                    .foregroundStyle(palette.face)
                    .frame(width: size * 0.47, height: size * 0.38)
                    .offset(x: size * pose.gaze * 0.012, y: size * 0.035)
            }
            .scaleEffect(x: pose.squash, y: 2 - pose.squash, anchor: .bottom)
            .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
            .offset(y: size * (pose.lift - 0.015))
        }
    }
}

// Explicit states also make the component usable in previews without AppState.
enum AgentAvatarState: String, CaseIterable {
    case idle, thinking, working, waiting, blocked, done

    var label: String { rawValue.capitalized }
    var symbol: String? {
        switch self {
        case .idle, .thinking, .working: return nil
        case .waiting: return "pause.fill"
        case .blocked: return "exclamationmark"
        case .done: return "checkmark"
        }
    }
    var tint: Color {
        switch self {
        case .idle: return Color(hex: 0x777D8B)
        case .thinking: return Color(hex: 0x8263ED)
        case .working: return Color(hex: 0x198CBA)
        case .waiting: return Color(hex: 0xB87516)
        case .blocked: return Color(hex: 0xCE4F62)
        case .done: return Color(hex: 0x278467)
        }
    }

    /// Only the active profile has authoritative live session state.
    static func resolve(turn: TurnState, connected: Bool, switching: Bool,
                        needsInput: Bool, hasFailure: Bool, hasTool: Bool,
                        hasOutput: Bool, hasReply: Bool) -> Self {
        if switching || turn == .synchronizing || turn == .reconnecting { return .waiting }
        if !connected || turn == .unsupportedGateway || hasFailure { return .blocked }
        if needsInput { return .waiting }
        if turn == .running { return hasTool || hasOutput ? .working : .thinking }
        return hasReply ? .done : .idle
    }
}

extension AppState {
    func avatarState(for profile: String) -> AgentAvatarState {
        guard profile == activeProfile else { return .idle }
        // Only inspect the current turn; an old rejected approval is not a current blocker.
        let currentTurn = messages.reversed().prefix { $0.role != .user }
        let needsInput = currentTurn.contains {
            $0.approval.map { [.pending, .submitting].contains($0.status) } == true
                || $0.clarify.map { [.pending, .submitting].contains($0.status) } == true
        }
        let failure = currentTurn.contains {
            $0.approval?.status == .error || $0.clarify?.status == .error
        }
        return AgentAvatarState.resolve(
            turn: turnState, connected: isConnected, switching: isProfileSwitching,
            needsInput: needsInput, hasFailure: failure,
            hasTool: currentTurn.contains { $0.tool?.status == .running },
            hasOutput: !streamingText.isEmpty,
            hasReply: currentTurn.contains { $0.role == .assistant && !$0.content.isEmpty }
        )
    }
}

private struct AgentAvatarPose {
    var lift = 0.0
    var tilt = 0.0
    var squash = 1.0
    var blink = 1.0
    var gaze = 0.0
    var orbit = -90.0
    var faceTime = 0.0

    init(state: AgentAvatarState, time: Double, elapsed: Double, seed: UInt64, animated: Bool) {
        guard animated else {
            if state == .thinking { gaze = 0.7; tilt = -5 }
            if state == .waiting { tilt = 6 }
            return
        }
        let t = time + Double(seed % 997) / 71
        let breath = sin(t * 1.8)
        let blinkPhase = t.truncatingRemainder(dividingBy: 4.7)
        blink = blinkPhase < 0.16 ? max(0.08, abs(blinkPhase - 0.08) / 0.08) : 1
        faceTime = t
        let orbitPeriod = state == .working ? 3.6 : 7.5
        orbit = t.truncatingRemainder(dividingBy: orbitPeriod) / orbitPeriod * 360 - 90
        switch state {
        case .idle:
            lift = breath * 0.014
            squash = 1 + breath * 0.012
            gaze = sin(t * 0.48) * 0.35
        case .thinking:
            lift = breath * 0.018
            tilt = -6 + sin(t * 1.3) * 3
            gaze = 0.8
        case .working:
            lift = -abs(sin(t * 3.8)) * 0.045
            squash = 1 + sin(t * 7.6) * 0.026
            tilt = sin(t * 3.8) * 4
            gaze = sin(t * 2.2) * 0.65
        case .waiting:
            tilt = 7 + sin(t * 1.4) * 2
            lift = breath * 0.009
        case .blocked:
            tilt = sin(t * 2) * 2
            gaze = -0.35
        case .done:
            let envelope = max(0, 1 - elapsed / 1.6)
            lift = -abs(sin(elapsed * 7)) * 0.09 * envelope
            squash = 1 + sin(elapsed * 14) * 0.04 * envelope
            tilt = sin(elapsed * 7) * 7 * envelope
        }
    }
}

private struct AgentExpressiveFace: View {
    let state: AgentAvatarState
    let blink: Double
    let gaze: Double
    let time: Double

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                HStack(spacing: w * 0.14) {
                    eye(width: w * 0.34, height: h * 0.59, right: false)
                    eye(width: w * 0.34, height: h * 0.59, right: true)
                }
                .offset(y: -h * 0.16)
                mouth(width: w, height: h)
                    .stroke(style: StrokeStyle(lineWidth: max(1.3, w * 0.06), lineCap: .round))
            }
            .frame(width: w, height: h)
        }
    }

    private func eye(width: CGFloat, height: CGFloat, right: Bool) -> some View {
        ZStack {
            if state == .done {
                Path { p in
                    p.move(to: CGPoint(x: width * 0.12, y: height * 0.6))
                    p.addQuadCurve(to: CGPoint(x: width * 0.88, y: height * 0.6),
                                   control: CGPoint(x: width * 0.5, y: height * 0.06))
                }.stroke(style: StrokeStyle(lineWidth: max(1.8, width * 0.2), lineCap: .round))
            } else {
                Capsule().fill(Color(hex: 0xFFFDF5))
                Capsule().frame(width: width * 0.43, height: height * (state == .working ? 0.61 : 0.54))
                    .offset(x: width * gaze * 0.18, y: state == .thinking ? -height * 0.12 : height * 0.04)
                if state == .blocked {
                    Rectangle().frame(height: height * 0.23)
                        .rotationEffect(.degrees(right ? -15 : 15))
                        .offset(y: -height * 0.45)
                }
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(x: 1, y: blink)
        .rotationEffect(.degrees(state == .waiting && right ? -9 : 0))
    }

    private func mouth(width: CGFloat, height: CGFloat) -> Path {
        Path { p in
            let y = height * 0.81
            if state == .thinking {
                p.move(to: CGPoint(x: width * 0.46, y: y))
                p.addLine(to: CGPoint(x: width * 0.60, y: y - height * 0.025))
            } else if state == .working {
                p.addEllipse(in: CGRect(x: width * 0.44, y: y - height * 0.06,
                                        width: width * 0.12, height: height * (0.10 + abs(sin(time * 3)) * 0.07)))
            } else {
                let curve = state == .blocked ? -0.13 : state == .waiting ? 0.025 : 0.17
                p.move(to: CGPoint(x: width * 0.35, y: y))
                p.addQuadCurve(to: CGPoint(x: width * 0.65, y: y),
                               control: CGPoint(x: width * 0.5, y: y + height * curve))
            }
        }
    }
}

enum AgentAvatarIdentity {
    struct Palette {
        let background: Color
        let fill: Color
        let face: Color
        let accent: Color
    }

    /// Stable, process-independent seed from the profile ID.
    static func seed(for profileID: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in profileID.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return hash == 0 ? 1 : hash
    }

    static func shape(for seed: UInt64) -> AgentCharacterKind {
        let kinds = AgentCharacterKind.allCases
        return kinds[Int(seed % UInt64(kinds.count))]
    }

    static func accessory(for seed: UInt64) -> AgentCharacterAccessoryKind {
        let kinds = AgentCharacterAccessoryKind.allCases
        return kinds[Int((seed / 7) % UInt64(kinds.count))]
    }

    static func palette(for seed: UInt64) -> Palette {
        let palettes: [Palette] = [
            Palette(
                background: Color(hex: 0xE8DEFF),
                fill: Color(hex: 0x6B4EFF),
                face: Color(hex: 0x24185C),
                accent: Color(hex: 0xB9A6FF)
            ),
            Palette(
                background: Color(hex: 0xD4E8FF),
                fill: Color(hex: 0x2F6FED),
                face: Color(hex: 0x16357A),
                accent: Color(hex: 0x93C0FF)
            ),
            Palette(
                background: Color(hex: 0xD4F5E2),
                fill: Color(hex: 0x1EAE5A),
                face: Color(hex: 0x0F3F24),
                accent: Color(hex: 0x8DE0B0)
            ),
            Palette(
                background: Color(hex: 0xCCF3EF),
                fill: Color(hex: 0x0FA899),
                face: Color(hex: 0x0C4A45),
                accent: Color(hex: 0x7BDCD2)
            ),
            Palette(
                background: Color(hex: 0xFFE2C8),
                fill: Color(hex: 0xE86A12),
                face: Color(hex: 0x6B2A0A),
                accent: Color(hex: 0xFFC089)
            ),
            Palette(
                background: Color(hex: 0xFFD6E4),
                fill: Color(hex: 0xE11D48),
                face: Color(hex: 0x6F1230),
                accent: Color(hex: 0xFF9BB8)
            ),
        ]
        return palettes[Int((seed / 6) % UInt64(palettes.count))]
    }
}

enum AgentCharacterKind: String, CaseIterable, Codable {
    case roundBlob
    case tallOval
    case softSquare
    case diamond
    case bean
    case petal
}

enum AgentCharacterAccessoryKind: String, CaseIterable, Codable {
    case none
    case ear
    case hat
    case cheekDot
}

private struct AgentCharacterShape: Shape {
    let kind: AgentCharacterKind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .roundBlob:
            path.addEllipse(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02))
        case .tallOval:
            path.addEllipse(in: CGRect(
                x: rect.minX + rect.width * 0.12,
                y: rect.minY,
                width: rect.width * 0.76,
                height: rect.height
            ))
        case .softSquare:
            path.addRoundedRect(
                in: rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04),
                cornerSize: CGSize(width: rect.width * 0.32, height: rect.height * 0.32)
            )
        case .diamond:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.02))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.02))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.midY))
            path.closeSubpath()
        case .bean:
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.12))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY + rect.height * 0.28),
                control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.08)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.maxY - rect.height * 0.12),
                control: CGPoint(x: rect.maxX + rect.width * 0.08, y: rect.midY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.maxY - rect.height * 0.16),
                control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.1)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.12),
                control: CGPoint(x: rect.minX - rect.width * 0.08, y: rect.midY)
            )
        case .petal:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.midY),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.midX, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.midY),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.midX, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        }
        return path
    }
}

private struct AgentCharacterAccessory: Shape {
    let kind: AgentCharacterAccessoryKind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .none:
            break
        case .ear:
            let ear = CGRect(
                x: rect.maxX - rect.width * 0.28,
                y: rect.minY + rect.height * 0.18,
                width: rect.width * 0.22,
                height: rect.height * 0.28
            )
            path.addEllipse(in: ear)
        case .hat:
            let brim = CGRect(
                x: rect.minX + rect.width * 0.12,
                y: rect.minY + rect.height * 0.08,
                width: rect.width * 0.76,
                height: rect.height * 0.1
            )
            path.addRoundedRect(in: brim, cornerSize: CGSize(width: brim.height * 0.4, height: brim.height * 0.4))
            let crown = CGRect(
                x: rect.minX + rect.width * 0.28,
                y: rect.minY,
                width: rect.width * 0.44,
                height: rect.height * 0.16
            )
            path.addRoundedRect(in: crown, cornerSize: CGSize(width: crown.width * 0.2, height: crown.height * 0.35))
        case .cheekDot:
            let dotRadius = max(2, rect.width * 0.055)
            path.addEllipse(in: CGRect(
                x: rect.midX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.62,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
        }
        return path
    }
}

/// Avoids re-decoding profile photos on every streaming publish.
enum AgentAvatarImageCache {
    static let shared = AgentAvatarImageCacheBox()
}

final class AgentAvatarImageCacheBox {
    private var cache: [URL: UIImage] = [:]
    private let lock = NSLock()

    func image(at url: URL) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[url] { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache[url] = image
        return image
    }

    func invalidate(url: URL) {
        lock.lock()
        cache.removeValue(forKey: url)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

#if DEBUG
/// Run with --avatar-gallery, or open the Xcode preview, to inspect the actual component.
struct AgentAvatarGallery: View {
    @State private var selectedState: AgentAvatarState = .thinking
    @State private var reducedMotion = false
    private let profiles = ["default", "research", "ops", "studio", "scout", "atlas"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Label("CONDUIT / CHARACTERS", systemImage: "sparkle")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.8).foregroundStyle(.secondary)
                    Spacer()
                    Circle().fill(Color(hex: 0x36A383)).frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("A little more alive.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Familiar faces. A language of motion.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 16) {
                    AgentAvatar(profileID: "research", displayName: "Research", photoURL: nil,
                                size: 148, state: selectedState, animates: !reducedMotion)
                    VStack(spacing: 4) {
                        Text("Research").font(.title3.weight(.semibold))
                        Text(stateDescription).font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach(AgentAvatarState.allCases, id: \.self) { state in
                            Button { selectedState = state } label: {
                                Text(state.label).font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .foregroundStyle(selectedState == state ? Color.white : Color.primary)
                                    .background(selectedState == state ? state.tint : Color.primary.opacity(0.05), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity).padding(24)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
                VStack(alignment: .leading, spacing: 18) {
                    Text("SIX STATES. ONE IDENTITY.")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        ForEach(AgentAvatarState.allCases, id: \.self) { state in
                            VStack(spacing: 9) {
                                AgentAvatar(profileID: "research", displayName: "Research", photoURL: nil, size: 43, state: state, animates: !reducedMotion)
                                Text(state.label).font(.system(size: 9, weight: .medium))
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    Text("A FAMILY OF INDIVIDUALS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 22) {
                        ForEach(profiles, id: \.self) { profile in
                            VStack(spacing: 8) {
                                AgentAvatar(profileID: profile, displayName: profile.capitalized, photoURL: nil,
                                            size: 76, state: selectedState, animates: !reducedMotion)
                                Text(profile.capitalized).font(.caption.weight(.medium))
                            }
                        }
                    }
                }
                Toggle("Reduce motion", isOn: $reducedMotion).font(.subheadline)
                Text("Native vector artwork · Stable profile identities · Motion follows activity")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var stateDescription: String {
        switch selectedState {
        case .idle: return "A quiet breath. Ready when you are."
        case .thinking: return "Looking up. Connecting the dots."
        case .working: return "In the rhythm. Making things happen."
        case .waiting: return "An attentive tilt. Your move."
        case .blocked: return "Needs a hand to keep going."
        case .done: return "A happy bounce. All taken care of."
        }
    }
}

#Preview("Character studio") {
    AgentAvatarGallery()
}
#endif
