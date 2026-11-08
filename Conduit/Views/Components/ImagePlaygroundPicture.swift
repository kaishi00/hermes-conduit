import SwiftUI
import UIKit
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Apple's Image Playground as a picture source for a bot, a profile or a
/// group chat: the system's own sheet, on the device (Private Cloud Compute
/// from iOS 27), with no Hermes backend, key or cost. It starts from the
/// name and what the bot is about; the person edits it there and picks one,
/// which is then saved like a chosen photo.
enum ImagePlaygroundPicture {
    /// What the picture buttons offer.
    enum Availability: Equatable {
        /// Image Playground can make a picture now.
        case available
        /// This device could, once Apple Intelligence is on (or has finished
        /// setting up, or Siri's language is one it supports): the system
        /// doesn't say which, so the hint names the setting.
        case canTurnOn
        /// It never can here: an older OS or a device without Apple
        /// Intelligence.
        case unavailable
    }

    /// Every Apple Intelligence device has 8 GB of memory or more, and every
    /// iPhone without it has 6 GB or less; an 8 GB device reports a little
    /// under 8 GiB.
    static let capableMemory: UInt64 = 7_000_000_000

    /// The longest name the sheet is handed as one idea.
    static let maxNameLength = 100

    /// The longest description the sheet is handed to pick ideas from.
    static let maxExtractedLength = 2_000

    /// `supported` is the system's `supportsImagePlayground`; `osSupports`
    /// whether this OS has Image Playground at all (iOS 18.1).
    static func availability(
        supported: Bool,
        osSupports: Bool,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Availability {
        guard osSupports else { return .unavailable }
        if supported { return .available }
        return physicalMemory >= capableMemory ? .canTurnOn : .unavailable
    }

    /// The system's answer now, for a menu built as it opens (the editors
    /// follow it live with readsImagePlaygroundAvailability).
    @MainActor
    static var current: Availability {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *) {
            return availability(supported: ImagePlaygroundViewController.isAvailable, osSupports: true)
        }
        #endif
        return .unavailable
    }

    /// What the sheet starts from: the name as one idea, and the longer
    /// text (a bot's description and SOUL, a group's members) for the
    /// system to pick ideas out of. The person can change all of it there.
    struct Prompt: Equatable {
        var name: String
        var details: String

        init(name: String, details: [String] = []) {
            self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ImagePlaygroundPicture.maxNameLength))
            let joined = details
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            self.details = String(joined.prefix(ImagePlaygroundPicture.maxExtractedLength))
        }
    }

    /// The made picture, read from the file the sheet hands over (a
    /// temporary one in the app's container, removed once read).
    static func image(at url: URL) -> UIImage? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

extension View {
    /// Keeps `availability` in step with the system's answer, which changes
    /// while the app runs (Apple Intelligence turned on in Settings).
    @ViewBuilder
    func readsImagePlaygroundAvailability(_ availability: Binding<ImagePlaygroundPicture.Availability>) -> some View {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *) {
            modifier(ImagePlaygroundAvailabilityReader(availability: availability))
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Image Playground's sheet, opened by `isPresented`, starting from
    /// `prompt` and `source` (the current picture, which the person can
    /// drop). `onImage` gets the picked picture; `onFailure` runs if its
    /// file couldn't be read.
    @ViewBuilder
    func imagePlaygroundPicture(
        isPresented: Binding<Bool>,
        prompt: ImagePlaygroundPicture.Prompt,
        source: UIImage? = nil,
        onImage: @escaping (UIImage) -> Void,
        onFailure: @escaping () -> Void = {}
    ) -> some View {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *) {
            modifier(ImagePlaygroundPictureSheet(
                isPresented: isPresented,
                prompt: prompt,
                source: source,
                onImage: onImage,
                onFailure: onFailure
            ))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if canImport(ImagePlayground)
@available(iOS 18.1, *)
private struct ImagePlaygroundAvailabilityReader: ViewModifier {
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @Binding var availability: ImagePlaygroundPicture.Availability

    func body(content: Content) -> some View {
        content
            .onAppear(perform: update)
            .onChange(of: supportsImagePlayground) { _, _ in update() }
    }

    private func update() {
        let now = ImagePlaygroundPicture.availability(supported: supportsImagePlayground, osSupports: true)
        if availability != now { availability = now }
    }
}

@available(iOS 18.1, *)
private struct ImagePlaygroundPictureSheet: ViewModifier {
    @Binding var isPresented: Bool
    let prompt: ImagePlaygroundPicture.Prompt
    let source: UIImage?
    let onImage: (UIImage) -> Void
    let onFailure: () -> Void

    private var concepts: [ImagePlaygroundConcept] {
        var concepts: [ImagePlaygroundConcept] = []
        if !prompt.name.isEmpty { concepts.append(.text(prompt.name)) }
        if !prompt.details.isEmpty {
            concepts.append(.extracted(from: prompt.details, title: prompt.name.isEmpty ? nil : prompt.name))
        }
        return concepts
    }

    func body(content: Content) -> some View {
        styled(content.imagePlaygroundSheet(
            isPresented: $isPresented,
            concepts: concepts,
            sourceImage: source.map { Image(uiImage: $0) }
        ) { url in
            if let image = ImagePlaygroundPicture.image(at: url) {
                onImage(image)
            } else {
                onFailure()
            }
        })
    }

    /// Opens on Animation, the style that reads best as a small round face;
    /// every other style stays a tap away.
    @ViewBuilder
    private func styled(_ view: some View) -> some View {
        if #available(iOS 18.4, *) {
            view.imagePlaygroundGenerationStyle(.animation)
        } else {
            view
        }
    }
}
#endif
