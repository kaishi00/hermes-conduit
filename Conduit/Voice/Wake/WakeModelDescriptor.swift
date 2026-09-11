//
//  WakeModelDescriptor.swift
//  Conduit
//
//  Metadata only. The runtime/framework and model assets remain deliberately
//  absent until their redistribution terms and checksums have been reviewed.
//

import Foundation

struct WakeModelAssetDescriptor: Codable, Equatable, Identifiable {
    enum ChecksumStatus: String, Codable, Equatable {
        case notRecorded
        case verified
    }

    var id: String { relativePath }
    let relativePath: String
    let purpose: String
    /// Nil means Conduit has not yet accepted a checksum for redistribution.
    let sha256: String?
    let checksumStatus: ChecksumStatus
}

struct WakeModelDescriptor: Codable, Equatable, Identifiable {
    enum PackagingStatus: String, Codable, Equatable {
        case blockedPendingLicenseReview
        case readyForBundling
    }

    let id: String
    let displayName: String
    let sherpaONNXVersion: String
    let modelRelease: String
    let sourceURL: URL
    let documentationURL: URL
    /// Published by GitHub for the complete, reviewed upstream archive. Asset
    /// hashes remain nil until the archive is approved for redistribution.
    let archiveSHA256: String
    let packagingStatus: PackagingStatus
    let licenseReviewNote: String
    let assets: [WakeModelAssetDescriptor]

    /// The only v1 pack. Its metadata is present so settings and tests can
    /// describe it without pretending that model bytes are bundled.
    static let bundledBilingualPack = WakeModelDescriptor(
        id: "sherpa-onnx-kws-zipformer-zh-en-3m-chunk8",
        displayName: String(localized: "English + Chinese wake phrases"),
        sherpaONNXVersion: "1.13.2",
        modelRelease: "2025-12-20",
        sourceURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2")!,
        documentationURL: URL(string: "https://k2-fsa.github.io/sherpa/onnx/kws/pretrained_models/index.html")!,
        archiveSHA256: "68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6",
        packagingStatus: .blockedPendingLicenseReview,
        licenseReviewNote: "Model redistribution terms and upstream SHA-256 values must be verified before assets are downloaded or committed.",
        assets: [
            .init(relativePath: "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx", purpose: String(localized: "quantized encoder"), sha256: nil, checksumStatus: .notRecorded),
            .init(relativePath: "decoder-epoch-13-avg-2-chunk-8-left-64.onnx", purpose: "decoder", sha256: nil, checksumStatus: .notRecorded),
            .init(relativePath: "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx", purpose: String(localized: "quantized joiner"), sha256: nil, checksumStatus: .notRecorded),
            .init(relativePath: "tokens.txt", purpose: String(localized: "keyword tokens"), sha256: nil, checksumStatus: .notRecorded),
            .init(relativePath: "en.phone", purpose: String(localized: "English pronunciation lexicon"), sha256: nil, checksumStatus: .notRecorded)
        ]
    )
}

/// A future downloaded pack can conform to this contract without changing the
/// lifecycle or routing layers. v1 exposes only `bundledBilingualPack`.
protocol WakeModelPackResolving {
    func localURL(for descriptor: WakeModelDescriptor) -> URL?
}

struct BundledWakeModelPackResolver: WakeModelPackResolving {
    func localURL(for descriptor: WakeModelDescriptor) -> URL? { nil }
}
