//
//  DictationSettingsSection.swift
//  Conduit
//
//  Voice settings for the composer's dictate button: which engine turns
//  speech into text, and custom words it should expect.
//

import SwiftUI

struct DictationSettingsSection: View {
    @AppStorage(DictationEngine.preferenceKey) private var engineRaw = DictationEngine.apple.rawValue
    @State private var words = DictationCustomWords.load()
    @State private var draft = ""

    private var engine: DictationEngine {
        DictationEngine.resolved(engineRaw, isSupported: { $0.isSupportedOnThisDevice })
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Dictation"), symbol: "mic", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: engine.rawValue,
                choices: DictationEngine.available.map { (id: $0.rawValue, title: $0.title) },
                onSelect: select
            ) {
                Text("Engine").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("voice.dictationEngine")
            Text(verbatim: engine.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            customWords
        }
    }

    private var customWords: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom words")
                .font(.subheadline.weight(.semibold))
            Text(engine == .hermes
                 ? AppLocalization.string("Names and terms dictation should expect, written the way you want them. Hermes uses the words in its own speech to text settings (stt.prompt), not this list.")
                 : AppLocalization.string("Names and terms dictation should expect, written the way you want them: your company, people, products."))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(words, id: \.self) { word in
                HStack(spacing: 10) {
                    Text(verbatim: word)
                        .font(.subheadline)
                    Spacer()
                    Button {
                        save(words.filter { $0 != word })
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Delete \(word)"))
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 8) {
                TextField(AppLocalization.string("Add a word or name"), text: Binding(
                    get: { draft },
                    // Longer entries are cut, so the field shows what is kept.
                    set: { draft = String($0.prefix(DictationCustomWords.maximumLength)) }
                ))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .accessibilityIdentifier("voice.dictationWordField")
                Button(AppLocalization.string("Add"), action: add)
                    .disabled(DictationCustomWords.canonicalized(draft).isEmpty || words.count >= DictationCustomWords.maximumCount)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func select(_ raw: String) {
        engineRaw = raw
        if #available(iOS 26.0, *), raw == DictationEngine.appleSpeechAnalyzer.rawValue {
            // The model for your language, before the first dictation.
            Task { await SpeechAnalyzerDictationRecognizer.prepare() }
        }
    }

    private func add() {
        let word = DictationCustomWords.canonicalized(draft)
        guard !word.isEmpty, words.count < DictationCustomWords.maximumCount else { return }
        save(words + [word])
        draft = ""
    }

    private func save(_ updated: [String]) {
        DictationCustomWords.save(updated)
        words = DictationCustomWords.load()
    }
}
