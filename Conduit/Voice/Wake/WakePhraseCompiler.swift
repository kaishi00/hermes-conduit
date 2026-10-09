//
//  WakePhraseCompiler.swift
//  Conduit
//

import Foundation

struct WakeProfileKey: Codable, Hashable, Equatable {
    let gatewayID: String
    let profileID: String

    init(gatewayID: String, profileID: String) {
        self.gatewayID = gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WakePhraseBinding: Codable, Equatable, Identifiable {
    let key: WakeProfileKey
    let phrase: String
    let startsFreshConversation: Bool

    var id: String { "\(key.gatewayID)|\(key.profileID)|\(normalizedPhrase)" }
    var normalizedPhrase: String { WakePhraseCompiler.normalize(phrase) }
}

struct CompiledWakePhrase: Equatable, Identifiable {
    let phrase: String
    let tokens: [String]
    let alias: String
    let profileKey: WakeProfileKey
    let startsFreshConversation: Bool

    var id: String { alias }
}

enum WakePhraseValidationError: LocalizedError, Equatable {
    case emptyPhrase
    case missingGatewayOrProfile
    case duplicatePhrase(String)
    case unsupportedEnglishWord(String)
    case unsupportedCharacter(String)
    case missingChinesePronunciation(String)

    var errorDescription: String? {
        switch self {
        case .emptyPhrase: return AppLocalization.string("Enter a wake phrase.")
        case .missingGatewayOrProfile: return AppLocalization.string("Wake phrases must belong to a gateway and profile.")
        case .duplicatePhrase(let phrase): return AppLocalization.string("The wake phrase ‘\(phrase)’ is already enabled.")
        case .unsupportedEnglishWord(let word): return AppLocalization.string("‘\(word)’ is not available in the English pronunciation lexicon.")
        case .unsupportedCharacter(let character): return AppLocalization.string("‘\(character)’ is not supported by the bundled wake model.")
        case .missingChinesePronunciation(let character): return AppLocalization.string("No pinyin token is available for ‘\(character)’.")
        }
    }
}

/// Kept injectable because the official `text2token` assets are not bundled
/// until the model packaging gate is cleared. Fixtures can use the exact
/// production tables when that happens.
struct WakeTokenizationTables: Equatable {
    let englishPronunciations: [String: [String]]
    let chinesePinyinTokens: [Character: String]

    init(englishPronunciations: [String: [String]], chinesePinyinTokens: [Character: String]) {
        self.englishPronunciations = englishPronunciations.mapKeys { $0.lowercased() }
        self.chinesePinyinTokens = chinesePinyinTokens
    }

    static let testFixtures = WakeTokenizationTables(
        englishPronunciations: [
            "hey": ["HH", "EY"], "conduit": ["K", "AA", "N", "D", "UW", "IH", "T"],
            "hermes": ["HH", "ER", "M", "IY", "Z"], "talk": ["T", "AO", "K"]
        ],
        chinesePinyinTokens: ["小": "xiao3", "爱": "ai4", "同": "tong2", "学": "xue2", "你": "ni3", "好": "hao3"]
    )

    /// The production app replaces this with tables extracted from the
    /// reviewed sherpa pack. It intentionally contains no unreviewed asset.
    static let unavailableProductionTables = WakeTokenizationTables(englishPronunciations: [:], chinesePinyinTokens: [:])
}

struct WakePhraseCompiler {
    let tables: WakeTokenizationTables

    init(tables: WakeTokenizationTables) { self.tables = tables }

    func compile(_ bindings: [WakePhraseBinding]) throws -> [CompiledWakePhrase] {
        var seen = Set<String>()
        return try bindings.map { binding in
            guard !binding.key.gatewayID.isEmpty, !binding.key.profileID.isEmpty else {
                throw WakePhraseValidationError.missingGatewayOrProfile
            }
            let phrase = binding.normalizedPhrase
            guard !phrase.isEmpty else { throw WakePhraseValidationError.emptyPhrase }
            guard seen.insert(phrase).inserted else { throw WakePhraseValidationError.duplicatePhrase(phrase) }
            let tokens = try tokens(for: phrase)
            return CompiledWakePhrase(
                phrase: phrase,
                tokens: tokens,
                alias: Self.stableAlias(for: binding.key, phrase: phrase),
                profileKey: binding.key,
                startsFreshConversation: binding.startsFreshConversation
            )
        }
    }

    func tokens(for phrase: String) throws -> [String] {
        var output: [String] = []
        var currentEnglish = ""

        func appendEnglishWord(_ word: String) throws {
            guard !word.isEmpty else { return }
            guard let pronunciation = tables.englishPronunciations[word.lowercased()], !pronunciation.isEmpty else {
                throw WakePhraseValidationError.unsupportedEnglishWord(word)
            }
            output.append(contentsOf: pronunciation)
        }

        for character in phrase {
            if character.isASCII, character.isLetter || character == "'" {
                currentEnglish.append(character)
            } else {
                try appendEnglishWord(currentEnglish)
                currentEnglish = ""
                if character.isWhitespace { continue }
                guard character.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }) else {
                    throw WakePhraseValidationError.unsupportedCharacter(String(character))
                }
                guard let pinyin = tables.chinesePinyinTokens[character], !pinyin.isEmpty else {
                    throw WakePhraseValidationError.missingChinesePronunciation(String(character))
                }
                output.append(pinyin)
            }
        }
        try appendEnglishWord(currentEnglish)
        guard !output.isEmpty else { throw WakePhraseValidationError.emptyPhrase }
        return output
    }

    static func normalize(_ phrase: String) -> String {
        phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    static func stableAlias(for key: WakeProfileKey, phrase: String) -> String {
        let source = "\(key.gatewayID)|\(key.profileID)|\(normalize(phrase))"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return "conduit-\(String(hash, radix: 16))"
    }
}

private extension Dictionary where Key == String {
    func mapKeys(_ transform: (String) -> String) -> [String: Value] {
        reduce(into: [:]) { result, item in result[transform(item.key)] = item.value }
    }
}
