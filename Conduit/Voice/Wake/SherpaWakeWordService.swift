//
//  SherpaWakeWordService.swift
//  Conduit
//
//  This adapter intentionally does not import sherpa-onnx. Supplying the
//  XCFramework and a reviewed model pack is an explicit integration step.
//

import Foundation

enum WakeWordServiceError: LocalizedError, Equatable {
    case unavailable(String)
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .notPrepared: return AppLocalization.string("Choose at least one valid wake phrase before listening.")
        }
    }
}

@MainActor
protocol SherpaWakeRuntime: AnyObject {
    var isListening: Bool { get }
    func configure(modelURL: URL, keywords: [CompiledWakePhrase]) throws
    func start(onDetection: @escaping (String) -> Void) throws
    func stop()
}

@MainActor
final class SherpaWakeWordService: WakeWordService {
    enum Availability: Equatable {
        case unavailable(String)
        case ready
    }

    private let descriptor: WakeModelDescriptor
    private let resolver: WakeModelPackResolving
    private let runtime: SherpaWakeRuntime?
    private var configuredPhrases: [CompiledWakePhrase] = []
    private var aliases: [String: CompiledWakePhrase] = [:]
    private var detectionHandler: ((CompiledWakePhrase) -> Void)?

    var isArmed: Bool { runtime?.isListening ?? false }

    var availability: Availability {
        guard descriptor.packagingStatus == .readyForBundling else {
            return .unavailable(descriptor.licenseReviewNote)
        }
        guard runtime != nil else {
            return .unavailable(AppLocalization.string("Wake-word runtime is not installed in this build."))
        }
        guard resolver.localURL(for: descriptor) != nil else {
            return .unavailable(AppLocalization.string("The reviewed wake model is not installed on this device."))
        }
        return .ready
    }

    init(
        descriptor: WakeModelDescriptor = .bundledBilingualPack,
        resolver: WakeModelPackResolving = BundledWakeModelPackResolver(),
        runtime: SherpaWakeRuntime? = nil
    ) {
        self.descriptor = descriptor
        self.resolver = resolver
        self.runtime = runtime
    }

    func prepare(_ phrases: [CompiledWakePhrase], onDetection: @escaping (CompiledWakePhrase) -> Void) throws {
        guard !phrases.isEmpty else { throw WakeWordServiceError.notPrepared }
        guard case .ready = availability, let runtime, let modelURL = resolver.localURL(for: descriptor) else {
            if case .unavailable(let reason) = availability { throw WakeWordServiceError.unavailable(reason) }
            throw WakeWordServiceError.unavailable(AppLocalization.string("Wake-word runtime is unavailable."))
        }
        configuredPhrases = phrases
        aliases = Dictionary(uniqueKeysWithValues: phrases.map { ($0.alias, $0) })
        detectionHandler = onDetection
        try runtime.configure(modelURL: modelURL, keywords: phrases)
    }

    func arm() throws {
        guard case .ready = availability, let runtime else {
            if case .unavailable(let reason) = availability { throw WakeWordServiceError.unavailable(reason) }
            throw WakeWordServiceError.unavailable(AppLocalization.string("Wake-word runtime is unavailable."))
        }
        guard !configuredPhrases.isEmpty else { throw WakeWordServiceError.notPrepared }
        guard !runtime.isListening else { return }
        try runtime.start { [weak self] alias in
            guard let phrase = self?.aliases[alias] else { return }
            self?.detectionHandler?(phrase)
        }
    }

    func disarm() {
        runtime?.stop()
    }
}
