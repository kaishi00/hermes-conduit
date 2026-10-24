import Foundation

/// Generated pictures for bots and group chats, through the gateway's own
/// image generation (`image.generate`, upstream `avatar-image.ts`). Hermes
/// generates with whatever backend its owner set up; Conduit only asks.
enum PictureGeneration {
    /// One render often takes 40 to 60 seconds on a remote backend; the
    /// generic request deadline would drop pictures that then finished.
    /// Desktop's bound.
    static let timeoutSeconds: TimeInterval = 90
    static let probeTimeoutSeconds: TimeInterval = 15

    static let probeParams: [String: Any] = ["probe": true]

    static func params(prompt: String) -> [String: Any] {
        ["prompt": prompt, "aspect_ratio": "square"]
    }

    /// What a probe answer says about the gateway's backend: nil when it
    /// gave no answer (an older gateway without the method, a failed
    /// call), so only an explicit `available: false` reads as none set up.
    static func isAvailable(probe result: AnyCodable?) -> Bool? {
        result?.objectValue?["available"]?.boolValue
    }

    /// Desktop's prompt for a bot picture from its name and description.
    static func botPrompt(name: String, description: String) -> String {
        let who = [name, description]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return "Cute minimal robot avatar for an AI agent named \"\(who.isEmpty ? "agent" : who)\". "
            + "Friendly simple mascot face, bold flat vector style, solid color background, centered, no text."
    }

    /// A group chat's picture from its name and members.
    static func groupPrompt(name: String, members: [String]) -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let crew = members.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var prompt = "Simple group chat picture for a team of AI agents"
        if !title.isEmpty { prompt += " named \"\(title)\"" }
        if !crew.isEmpty { prompt += " (\(crew.prefix(6).joined(separator: ", ")))" }
        return prompt + ". Bold flat vector style, solid color background, centered, no text."
    }

    /// The user's own description, framed as Desktop frames it.
    static func customPrompt(_ description: String, forGroup: Bool) -> String? {
        let custom = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return nil }
        let subject = forGroup ? "Picture for a group chat of AI agents" : "Avatar for an AI agent"
        return "\(custom). \(subject): centered, bold flat vector style, solid color background, no text."
    }

    enum Outcome: Equatable {
        /// Image bytes, from the inline data URL.
        case image(Data)
        /// A web address to download, when the gateway couldn't inline it.
        case remote(URL)
        /// The gateway's reason, if it gave one.
        case failed(String?)
    }

    /// An `image.generate` answer: `image_data` (a data URL) when the
    /// gateway could inline the picture, else `image`, the backend's own
    /// reference, usable here only as a web address.
    static func outcome(of result: AnyCodable) -> Outcome {
        let object = result.objectValue ?? [:]
        guard object["success"]?.boolValue == true else {
            let reason = object["error"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason?.isEmpty == false ? reason : nil)
        }
        if let dataURL = object["image_data"]?.stringValue, let data = imageData(fromDataURL: dataURL) {
            return .image(data)
        }
        if let reference = object["image"]?.stringValue, let data = imageData(fromDataURL: reference) {
            return .image(data)
        }
        if let reference = object["image"]?.stringValue,
           let url = URL(string: reference),
           url.scheme == "https" || url.scheme == "http" {
            return .remote(url)
        }
        return .failed(nil)
    }

    /// The bytes of a base64 `data:image/...` URL.
    static func imageData(fromDataURL string: String) -> Data? {
        guard string.hasPrefix("data:image/"),
              let comma = string.firstIndex(of: ","),
              string[..<comma].hasSuffix(";base64") else { return nil }
        guard let data = Data(base64Encoded: String(string[string.index(after: comma)...]), options: .ignoreUnknownCharacters),
              !data.isEmpty else { return nil }
        return data
    }
}

/// A picture generation that didn't produce a usable image.
struct PictureGenerationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
