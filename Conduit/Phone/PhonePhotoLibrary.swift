//
//  PhonePhotoLibrary.swift
//  Conduit
//
//  Photos for Hermes (notifier 0.161.0): what the phone says about each
//  photo in the library, made here with Apple's on-device Vision (labels
//  for what's in it, the words in it) and the town or area it was taken in,
//  never the picture. Hermes searches that on the host and asks for a photo
//  by id; the picture goes only once the user says yes on its card.
//
//  The newest PhoneSyncLimits.maxPhotos are described, newest first, a few
//  dozen on each sync pass, so the library is covered over a few days of
//  use without one long wait. The descriptions are kept on the phone (not
//  backed up) so each photo is described once.
//

import CoreLocation
import CryptoKit
import Foundation
import Photos
import UIKit
import Vision

enum PhonePhotoAccess: Equatable {
    case notAsked, denied, limited, full

    var canRead: Bool { self == .limited || self == .full }

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .limited: self = .limited
        case .notDetermined: self = .notAsked
        default: self = .denied
        }
    }
}

/// One photo as Hermes knows it: what Vision saw, the place, and when.
struct PhonePhotoEntry: Codable, Equatable {
    /// "ph_" and 16 hex digits of the photo's local identifier, hashed, so
    /// the host never sees the identifier itself.
    var id: String
    var localID: String
    var at: Date
    /// The time zone where it was taken, when the place says.
    var zone: String?
    var screenshot: Bool
    var favorite: Bool
    var labels: [String]
    var text: String?
    var place: String?
    var width: Int
    var height: Int
    var latitude: Double?
    var longitude: Double?
    /// Looked up already (found or not), so it isn't asked again.
    var placeLooked = false

    static func id(forLocal localID: String) -> String {
        let digest = SHA256.hash(data: Data(localID.utf8))
        return "ph_" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The host's limits (phone_store `_parse_photo`).
    static let labelsMax = 12
    static let labelChars = 40
    static let textChars = 300
    /// The host refuses times before 2000.
    static let earliest = Date(timeIntervalSince1970: 946_684_800)

    /// As `/phone/ingest`'s `photos` section takes it.
    var json: [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "at": PhoneDates.format(at, timeZone: zone.flatMap(TimeZone.init(identifier:)) ?? .current),
            "kind": screenshot ? "screenshot" : "photo",
            "favorite": favorite,
            "w": max(1, width),
            "h": max(1, height),
        ]
        if !labels.isEmpty { value["labels"] = Array(labels.prefix(Self.labelsMax)) }
        if let text, !text.isEmpty { value["text"] = String(text.prefix(Self.textChars)) }
        if let place, !place.isEmpty { value["place"] = String(place.prefix(100)) }
        return value
    }
}

/// The photo library as phone sync uses it.
@MainActor
protocol PhonePhotoSource: AnyObject {
    var access: PhonePhotoAccess { get }
    func requestAccess() async -> PhonePhotoAccess
    /// Describes up to `budget` photos not described yet, newest first,
    /// stopping at `deadline`; photos gone from the library are forgotten.
    func describeMore(budget: Int, until deadline: Date) async
    /// The photos described so far, as the host takes them.
    func descriptions() -> [[String: Any]]
    /// How many of the newest photos are described.
    var progress: (described: Int, total: Int) { get }
    /// A small copy for the card.
    func thumbnail(photoID: String, side: CGFloat) async -> UIImage?
    /// The picture to send, as a JPEG of at most `maxBytes`, or nil when
    /// it's no longer in the library.
    func jpeg(photoID: String, maxBytes: Int) async -> Data?
    /// Sharing turned off: the descriptions go.
    func forget()
}

/// The descriptions kept between runs.
struct PhonePhotoIndex: Codable, Equatable {
    var entries: [PhonePhotoEntry] = []
    /// Places looked up, by coordinates rounded to about a kilometre.
    var places: [String: PhonePhotoPlace] = [:]
    var total = 0

    static func placeKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f,%.2f", latitude, longitude)
    }
}

struct PhonePhotoPlace: Codable, Equatable {
    var name: String?
    var zone: String?
}

@MainActor
final class SystemPhotoLibrary: PhonePhotoSource {
    static let shared = SystemPhotoLibrary()

    private let url: URL
    private var index: PhonePhotoIndex?
    /// Counts forgets: a pass started before one never puts its copy back.
    private var generation = 0
    /// Writes and the forget's delete, in the order they were asked for, so
    /// a late write can't bring the descriptions back.
    private let disk = DispatchQueue(label: "conduit.phone-photos.index", qos: .utility)
    /// Place lookups per pass: Apple's geocoder answers a few a minute.
    static let placesPerPass = 10

    init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.url = url ?? base.appendingPathComponent("PhoneSync", isDirectory: true).appendingPathComponent("photos.json")
    }

    var access: PhonePhotoAccess { PhonePhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    func requestAccess() async -> PhonePhotoAccess {
        PhonePhotoAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    var progress: (described: Int, total: Int) {
        let index = loaded()
        return (index.entries.count, max(index.total, index.entries.count))
    }

    func descriptions() -> [[String: Any]] {
        loaded().entries.filter { $0.at >= PhonePhotoEntry.earliest }.map(\.json)
    }

    func forget() {
        generation += 1
        index = PhonePhotoIndex()
        let url = self.url
        disk.async { try? FileManager.default.removeItem(at: url) }
    }

    func describeMore(budget: Int, until deadline: Date) async {
        guard access.canRead else { return }
        let started = generation
        var index = loaded()
        let assets = await Task.detached(priority: .utility) { Self.newestAssets() }.value
        let known = Dictionary(index.entries.map { ($0.localID, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [PhonePhotoEntry] = []
        var waiting: [AssetInfo] = []
        for asset in assets {
            if var entry = known[asset.localID] {
                entry.favorite = asset.favorite
                kept.append(entry)
            } else {
                waiting.append(asset)
            }
        }
        index.total = assets.count
        for asset in waiting.prefix(budget) {
            guard Date() < deadline, !Task.isCancelled else { break }
            // A photo that couldn't be read (still in iCloud, Vision failed)
            // stays waiting for a later pass.
            guard let seen = await Task.detached(priority: .utility, operation: { Self.look(at: asset.localID) }).value
            else { continue }
            kept.append(PhonePhotoEntry(
                id: PhonePhotoEntry.id(forLocal: asset.localID), localID: asset.localID, at: asset.at, zone: nil,
                screenshot: asset.screenshot, favorite: asset.favorite, labels: seen.labels, text: seen.text,
                place: nil, width: asset.width, height: asset.height,
                latitude: asset.latitude, longitude: asset.longitude, placeLooked: asset.latitude == nil))
        }
        // Places last, from the ones already looked up where possible.
        var lookups = 0
        for position in kept.indices where !kept[position].placeLooked {
            guard let latitude = kept[position].latitude, let longitude = kept[position].longitude else {
                kept[position].placeLooked = true
                continue
            }
            let key = PhonePhotoIndex.placeKey(latitude: latitude, longitude: longitude)
            if index.places[key] == nil {
                guard lookups < Self.placesPerPass, Date() < deadline else { continue }
                lookups += 1
                index.places[key] = await Self.place(latitude: latitude, longitude: longitude)
            }
            kept[position].place = index.places[key]?.name
            kept[position].zone = index.places[key]?.zone
            kept[position].placeLooked = true
        }
        // Sharing turned off (and the descriptions forgotten) meanwhile.
        guard generation == started else { return }
        kept.sort { $0.at > $1.at }
        index.entries = kept
        self.index = index
        save(index)
    }

    func thumbnail(photoID: String, side: CGFloat) async -> UIImage? {
        guard let localID = localID(for: photoID) else { return nil }
        let pixels = side * max(2, UITraitCollection.current.displayScale)
        return await Task.detached(priority: .userInitiated) {
            Self.image(localID: localID, side: pixels)
        }.value
    }

    func jpeg(photoID: String, maxBytes: Int) async -> Data? {
        guard let localID = localID(for: photoID) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            for side in [2_048.0, 1_600.0, 1_200.0] as [CGFloat] {
                guard let image = Self.image(localID: localID, side: side) else { return nil }
                for quality in [0.8, 0.65, 0.5] as [CGFloat] {
                    if let data = image.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
                }
            }
            return nil
        }.value
    }

    // MARK: Library

    private func localID(for photoID: String) -> String? {
        loaded().entries.first { $0.id == photoID }?.localID
    }

    private func loaded() -> PhonePhotoIndex {
        if let index { return index }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PhonePhotoIndex.self, from: $0) }
        let found = read ?? PhonePhotoIndex()
        index = found
        return found
    }

    private func save(_ index: PhonePhotoIndex) {
        let url = self.url
        disk.async {
            guard let data = try? JSONEncoder().encode(index) else { return }
            var folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    struct AssetInfo: Sendable {
        var localID: String
        var at: Date
        var screenshot: Bool
        var favorite: Bool
        var width: Int
        var height: Int
        var latitude: Double?
        var longitude: Double?
    }

    nonisolated static func newestAssets() -> [AssetInfo] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = PhoneSyncLimits.maxPhotos
        options.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(with: options)
        var found: [AssetInfo] = []
        found.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard let at = asset.creationDate else { return }
            found.append(AssetInfo(localID: asset.localIdentifier, at: at,
                                   screenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                                   favorite: asset.isFavorite, width: asset.pixelWidth, height: asset.pixelHeight,
                                   latitude: asset.location?.coordinate.latitude,
                                   longitude: asset.location?.coordinate.longitude))
        }
        return found
    }

    /// A copy of the photo at most `side` pixels on its longer edge.
    nonisolated static func image(localID: String, side: CGFloat) -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let found = PhonePhotoBox<UIImage>()
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                              contentMode: .aspectFit, options: options) { image, _ in
            found.value = image
        }
        return found.value
    }

    /// What Vision sees in a photo: its labels, best first, and the words in it.
    /// Nil when the photo couldn't be read or looked at.
    nonisolated static func look(at localID: String) -> (labels: [String], text: String?)? {
        guard let cgImage = image(localID: localID, side: 1_024)?.cgImage else { return nil }
        let classify = VNClassifyImageRequest()
        let read = VNRecognizeTextRequest()
        read.recognitionLevel = .fast
        read.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([classify, read])
        } catch {
            return nil
        }
        return (labels(from: classify.results ?? []), text(from: read.results ?? []))
    }

    /// The labels Vision is fairly sure of, best first, as plain words.
    nonisolated static func labels(from observations: [VNClassificationObservation]) -> [String] {
        let pairs = observations.map { (identifier: $0.identifier, confidence: $0.confidence) }
        return labels(fromPairs: pairs)
    }

    nonisolated static func labels(fromPairs pairs: [(identifier: String, confidence: Float)]) -> [String] {
        var seen: Set<String> = []
        return pairs.filter { $0.confidence >= 0.3 }
            .sorted { $0.confidence > $1.confidence }
            .map { String($0.identifier.replacingOccurrences(of: "_", with: " ").prefix(PhonePhotoEntry.labelChars)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(PhonePhotoEntry.labelsMax)
            .map { $0 }
    }

    nonisolated static func text(from observations: [VNRecognizedTextObservation]) -> String? {
        let lines = observations.compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.4 }.map(\.string)
        return joined(lines)
    }

    /// Lines of text in a picture as one line, cut to what the host keeps.
    nonisolated static func joined(_ lines: [String]) -> String? {
        let text = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(PhonePhotoEntry.textChars))
    }

    /// The town or area and country, and its time zone; an empty place when
    /// the geocoder doesn't know or doesn't answer in time.
    nonisolated static func place(latitude: Double, longitude: Double) async -> PhonePhotoPlace {
        await withTaskGroup(of: PhonePhotoPlace?.self) { group in
            group.addTask {
                let geocoder = CLGeocoder()
                let location = CLLocation(latitude: latitude, longitude: longitude)
                let placemark = try? await withTaskCancellationHandler {
                    try await geocoder.reverseGeocodeLocation(location).first
                } onCancel: {
                    geocoder.cancelGeocode()
                }
                return placemark.map(Self.place(from:)) ?? PhonePhotoPlace()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? PhonePhotoPlace()
        }
    }

    nonisolated static func place(from placemark: CLPlacemark) -> PhonePhotoPlace {
        let area = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea
        let name = [area, placemark.country].compactMap { $0 }.joined(separator: ", ")
        return PhonePhotoPlace(name: name.isEmpty ? nil : name, zone: placemark.timeZone?.identifier)
    }
}

/// Saves pictures to an album called Hermes, made the first time.
enum PhonePhotoAlbum {
    static let title = "Hermes"

    enum Failure: Error { case noAccess, failed }

    static func save(fileURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        // Limited access can still add to an album Conduit made.
        guard status == .authorized || status == .limited else { throw Failure.noAccess }
        let album: PHAssetCollection
        if let existing = try await existingAlbum() {
            album = existing
        } else {
            album = try await createAlbum()
        }
        try await PHPhotoLibrary.shared().performChanges {
            guard let created = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL),
                  let placeholder = created.placeholderForCreatedAsset,
                  let request = PHAssetCollectionChangeRequest(for: album) else { return }
            request.addAssets([placeholder] as NSArray)
        }
    }

    private static func existingAlbum() async throws -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }

    private static func createAlbum() async throws -> PHAssetCollection {
        let created = PhonePhotoBox<String>()
        try await PHPhotoLibrary.shared().performChanges {
            created.value = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier = created.value,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { throw Failure.failed }
        return album
    }
}

/// A value a Photos callback hands back.
final class PhonePhotoBox<Value>: @unchecked Sendable {
    var value: Value?
}
