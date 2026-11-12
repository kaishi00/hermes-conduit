//
//  AttachmentHelper.swift
//  Conduit
//
//  Reads a picked or shared file into an attachment. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

enum AttachmentHelper {
    static func toBase64(_ attachment: Attachment) async -> String {
        guard let data = data(for: attachment) else { return "" }
        return data.base64EncodedString()
    }

    static func toDataUrl(_ attachment: Attachment) async -> String {
        guard let data = data(for: attachment) else { return "" }
        return dataUrl(base64: data.base64EncodedString(), for: attachment)
    }

    static func dataUrl(base64: String, for attachment: Attachment) -> String {
        dataUrl(base64: base64, mimeType: attachment.mimeType)
    }

    static func dataUrl(base64: String, mimeType: String?) -> String {
        let mimeType = mimeType.flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
        return "data:\(mimeType);base64,\(base64)"
    }

    /// A picture as a message sends it to Hermes: resized when it is larger
    /// than a model takes (`PictureUpload`), else as it is. Nil when the
    /// file can't be read. Off the main actor: decoding a photo is slow.
    typealias PictureForHermes = (base64: String, filename: String, mimeType: String?)

    static func pictureForHermes(_ attachment: Attachment) async -> PictureForHermes? {
        await Task.detached(priority: .userInitiated) { () -> PictureForHermes? in
            guard let data = AttachmentHelper.data(for: attachment) else { return nil }
            if let resized = PictureUpload.resized(data, filename: attachment.name) {
                return (resized.data.base64EncodedString(), resized.filename, resized.mimeType)
            }
            return (data.base64EncodedString(), attachment.name, attachment.mimeType)
        }.value
    }

    static func data(for attachment: Attachment) -> Data? {
        guard let url = URL(string: attachment.uri), url.isFileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}

enum AttachmentError: LocalizedError {
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let name): return AppLocalization.string("Could not read \(name).")
        }
    }
}
