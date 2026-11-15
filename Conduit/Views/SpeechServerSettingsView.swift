//
//  SpeechServerSettingsView.swift
//  Conduit
//
//  Speech to text through the user's own speech server: its address, an
//  optional key, and a test the Hermes host runs against it. The settings
//  live in the profile's Hermes config (voice.speech_server), which the
//  notifier reads when it relays Conduit's audio.
//

import SwiftUI

struct SpeechServerSettingsView: View {
    @ObservedObject var service: HermesVoiceConfigurationService

    @State private var status: SpeechServerStatus?
    @State private var urlDraft = ""
    @State private var keyDraft = ""
    @State private var isSaving = false
    /// Live > Local's own model switch changed during a save: the page
    /// reads again once the save is done.
    @State private var statusOwed = false
    /// Counts saves, so a read that a whole save happened during is asked again.
    @State private var saves = 0
    @State private var isTesting = false
    @State private var testResult: SpeechServerTestResult?
    /// Why the last save or read failed, shown here rather than only at the
    /// top of the Voice screen.
    @State private var errorMessage: String?
    /// The profile whose saved values the drafts were loaded from.
    @State private var draftsProfile: String?
    /// The host answered this load. Until then the address and key shown
    /// are the ones kept on the phone, which may be stale, and a kept
    /// address has no user or password to write back (#1533).
    @State private var answered = false
    /// The last read failed: the page's next check (Check again) reads again.
    @State private var readFailed = false
    /// The switch as tapped, while its save is on the way: it shows the new
    /// position at once, and what the host says once that is read.
    @State private var driveTurnsDraft: Bool?
    /// The names a hosted server may need (voice.speech_server.model,
    /// .voice, .transcription_model), as typed or filled in by a preset.
    @State private var modelDraft = ""
    @State private var voiceDraft = ""
    @State private var transcriptionModelDraft = ""
    /// The servers the plugin knows by name, and the one picked: its
    /// example address is the field's prompt and its Hermes answers
    /// setting is saved with the rest.
    @State private var presets: [SpeechServerPreset] = []
    @State private var pickedPreset: SpeechServerPreset?
    /// The address the last picked preset filled in, so picking another
    /// replaces it and never an address the user typed.
    @State private var pickedURL: String?

    static let urlKey = "voice.speech_server.url"
    static let apiKeyKey = "voice.speech_server.api_key"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your voice is recognized by a server you run, such as Hugging Face speech-to-speech or the one Hermes Live Voice starts. Hermes connects to it for Conduit, so it can run on another machine on your network.", systemImage: "server.rack")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)

            if let status, status.pluginMissing {
                Text(status.reason ?? SpeechServerStatus.pluginMissingReason)
                    .scaledFont(.footnote)
                    .foregroundStyle(.orange)
            } else {
                if status?.namesItsModel == true, !presets.isEmpty {
                    Menu {
                        ForEach(presets) { preset in
                            Button(preset.name) { pick(preset) }
                        }
                    } label: {
                        Label(pickedPreset?.name ?? AppLocalization.string("Known servers", table: .voice), systemImage: "list.bullet")
                            .scaledFont(.subheadline)
                    }
                    .disabled(!answered || isSaving)
                    .accessibilityIdentifier("voice.speechServer.presets")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Server address").scaledFont(.subheadline.weight(.semibold))
                    TextField(text: $urlDraft, prompt: Text(verbatim: pickedPreset?.urlHint ?? "ws://192.168.1.20:8765/v1/realtime")) {
                        Text("Server address")
                    }
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { Task { await saveURL() } }
                        .disabled(!answered)
                        .accessibilityIdentifier("voice.speechServer.url")
                    if pickedPreset?.urlHint != nil, urlDraft.isEmpty {
                        Text(AppLocalization.string("Finish the address: put your own workspace or host in place of the example.", table: .voice))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Plain ws:// works for home network and Tailscale addresses. A server on the internet needs wss://.")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Key").scaledFont(.subheadline.weight(.semibold))
                        Spacer()
                        Text(status?.hasKey == true ? AppLocalization.string("Set") : AppLocalization.string("None"))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SecureField("Optional, for a server behind a login", text: $keyDraft)
                        .accessibilityLabel(Text("Key"))
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("voice.speechServer.key")
                }

                if status?.namesItsModel == true {
                    VStack(alignment: .leading, spacing: 4) {
                        nameField(AppLocalization.string("Model"), text: $modelDraft,
                                  example: "gpt-realtime", identifier: "voice.speechServer.model")
                        nameField(AppLocalization.string("Voice"), text: $voiceDraft,
                                  example: "marin", identifier: "voice.speechServer.voice")
                        nameField(AppLocalization.string("Transcription model", table: .voice), text: $transcriptionModelDraft,
                                  example: "gpt-4o-mini-transcribe", identifier: "voice.speechServer.transcriptionModel")
                        Text(AppLocalization.string("Optional. A hosted server may need its model, a voice and a transcription model named. Leave them empty for a server that needs none, such as speech-to-speech.", table: .voice))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let driveTurns = status?.driveTurns, status?.configured == true {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(AppLocalization.string("Hermes answers", table: .voice), isOn: Binding(
                            get: { driveTurnsDraft ?? presetDrivesTurns ?? driveTurns },
                            set: { on in
                                driveTurnsDraft = on
                                // The switch as tapped wins over a picked server's.
                                let picked = pickedPreset?.drivesTurns
                                pickedPreset?.drivesTurns = on
                                Task { await saveDriveTurns(on, pickedBefore: picked) }
                            }
                        ))
                        .disabled(!answered || isSaving)
                        .accessibilityIdentifier("voice.speechServer.driveTurns")
                        Text(AppLocalization.string("For a server with a model of its own, such as a hosted realtime model: it then only listens and reads Hermes' replies aloud. Leave it off for a server you point at Conduit, such as speech-to-speech.", table: .voice))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 16) {
                    Button("Save") { Task { await saveAll() } }
                        .disabled(!answered || isSaving || !hasChanges)
                    Button {
                        Task { await runTest(profile: draftsProfile) }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(isTesting || isSaving || status?.configured != true)
                    .accessibilityLabel(Text("Test connection"))
                    .accessibilityIdentifier("voice.speechServer.test")
                    Spacer()
                    if status?.hasKey == true {
                        Button("Remove key", role: .destructive) { Task { await removeKey() } }
                            .scaledFont(.footnote)
                            .disabled(!answered || isSaving)
                    }
                }
                .buttonStyle(.borderless)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("voice.speechServer.saveError")
                }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(testResult.connected ? .green : .orange)
                        .accessibilityIdentifier("voice.speechServer.testResult")
                    if testResult.connected, testResult.answersAlone == true, status?.driveTurns == false, status?.ownModel != true,
                       presetDrivesTurns != true {
                        Label(AppLocalization.string("This server has a model of its own. Turn on Hermes answers to have Hermes answer your calls on it.", table: .voice), systemImage: "person.wave.2")
                            .scaledFont(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("voice.speechServer.answersAlone")
                    }
                } else if let status, status.configured, !status.available, let reason = status.reason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("voice.speechServer.statusReason")
                }
            }
        }
        .onAppear(perform: showKept)
        .task(id: service.profile) { await load() }
        // Live > Local's own model switch changes what the Test connection
        // banner should say: the status follows it.
        .onChange(of: service.speechServerVoice?.ownModel) { _, _ in
            guard answered else { return }
            Task { await followOwnModel(clearingError: true) }
        }
        // A switch that landed during a save reads again once it's done.
        .onChange(of: isSaving) { _, saving in
            if saving { saves += 1 }
            guard !saving, statusOwed else { return }
            statusOwed = false
            // The save's own error, if it had one, stays.
            Task { await followOwnModel(clearingError: false) }
        }
        // After a read that failed, the page's next check (its Check again
        // too) asks the host again.
        .onChange(of: service.isLoading) { _, loading in
            guard !loading, readFailed else { return }
            Task { await read() }
        }
    }

    /// Reads the status after Live > Local's own model switch changed.
    private func followOwnModel(clearingError: Bool) async {
        // A save on the way reconciles the drafts against what it sent, so
        // a field typed meanwhile stays; the page reads again once it's
        // done, in case the save's own read came before the switch. Checked
        // before the read too: one asked mid-save could land after the save
        // with an answer from before it.
        guard !isSaving else {
            statusOwed = true
            return
        }
        let profile = draftsProfile
        let savesBefore = saves
        let loaded = await service.speechServerStatus()
        guard draftsProfile == profile else { return }
        // A save that started while this read was out, even one already
        // done, may have changed what it answered: read again after it.
        guard !isSaving, saves == savesBefore else {
            if isSaving {
                statusOwed = true
            } else {
                // The save's own error, if it had one, stays.
                Task { await followOwnModel(clearingError: false) }
            }
            return
        }
        // A read that fails is asked again on the page's next check; one
        // that answers takes away the error a failed read left.
        let errorWasRead = readFailed
        readFailed = loaded.readFailed
        guard !loaded.readFailed else {
            if errorMessage == nil { errorMessage = loaded.reason }
            return
        }
        // A save's own error stays when this read was owed to it.
        if clearingError || errorWasRead { errorMessage = nil }
        let before = status
        status = loaded
        follow(from: before, to: loaded)
    }

    private var savedURL: String { status?.url ?? "" }

    private var hasChanges: Bool {
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return url != savedURL || !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !changedNames.isEmpty || presetDrivesTurns != nil
    }

    /// The names that differ from what the host has, by their config key
    /// under voice.speech_server; an emptied one is removed.
    private var changedNames: [String: String] {
        guard status?.namesItsModel == true else { return [:] }
        var names: [String: String] = [:]
        for (key, draft, saved) in [("model", modelDraft, status?.model), ("voice", voiceDraft, status?.voice),
                                    ("transcription_model", transcriptionModelDraft, status?.transcriptionModel)] {
            let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if value != (saved ?? "") { names[key] = value }
        }
        return names
    }

    /// The picked preset's Hermes answers setting, where the host's differs.
    private var presetDrivesTurns: Bool? {
        guard let pickedPreset, let saved = status?.driveTurns, saved != pickedPreset.drivesTurns else { return nil }
        return pickedPreset.drivesTurns
    }

    private func nameField(_ title: String, text: Binding<String>, example: String, identifier: String) -> some View {
        HStack {
            Text(title).scaledFont(.subheadline.weight(.semibold))
            TextField(text: text, prompt: Text(verbatim: example)) { Text(title) }
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(!answered)
                .accessibilityIdentifier(identifier)
        }
    }

    /// A known server fills the fields in; Save writes them. One with only
    /// an example address leaves the address for the user to finish.
    private func pick(_ preset: SpeechServerPreset) {
        pickedPreset = preset
        if let url = preset.url {
            urlDraft = url
        } else if let pickedURL, urlDraft == pickedURL {
            // Only an address the last pick filled in gives way to the
            // example; one the user typed stays.
            urlDraft = ""
        }
        pickedURL = preset.url
        modelDraft = preset.model ?? ""
        voiceDraft = preset.voice ?? ""
        transcriptionModelDraft = preset.transcriptionModel ?? ""
        testResult = nil
    }

    private func showNames(_ status: SpeechServerStatus?) {
        modelDraft = status?.model ?? ""
        voiceDraft = status?.voice ?? ""
        transcriptionModelDraft = status?.transcriptionModel ?? ""
    }

    /// The status last read, kept on the phone, drawn before the first
    /// frame while the host is asked again (#1533).
    private func showKept() {
        guard status == nil else { return }
        status = service.speechServer
        urlDraft = status?.url ?? ""
        showNames(status)
    }

    /// A profile switch starts from that profile's saved values: the
    /// status last read, while the host is asked again.
    private func load() async {
        draftsProfile = service.profile
        driveTurnsDraft = nil
        statusOwed = false
        pickedPreset = nil
        pickedURL = nil
        status = service.speechServer
        urlDraft = status?.url ?? ""
        showNames(status)
        keyDraft = ""
        testResult = nil
        answered = false
        await read()
    }

    /// A read that fails keeps what's shown, says why, and the fields wait
    /// (#1533).
    private func read() async {
        let profile = draftsProfile
        errorMessage = nil
        let loaded = await service.speechServerStatus()
        // A newer profile switch replaced this read.
        guard !Task.isCancelled, draftsProfile == profile else { return }
        readFailed = loaded.readFailed
        guard !loaded.readFailed else {
            errorMessage = loaded.reason
            return
        }
        let before = status
        status = loaded
        // A read that answers a page already answered leaves what's typed,
        // and moves a field nobody touched to the host's newer value.
        if !answered {
            urlDraft = loaded.url ?? ""
            showNames(loaded)
        } else {
            follow(from: before, to: loaded)
        }
        answered = true
        if loaded.namesItsModel, presets.isEmpty {
            let listed = await service.speechServerPresets()
            guard draftsProfile == profile else { return }
            presets = listed
        }
    }

    private func saveURL() async {
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url != savedURL else { return }
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        errorMessage = nil
        let profile = draftsProfile
        let saved = await save(url, for: Self.urlKey, profile: profile)
        await refreshStatus(submittedURL: saved ? url : nil, profile: profile)
    }

    private func saveAll() async {
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        errorMessage = nil
        // The drafts belong to this profile. A switch during a save loads the
        // new profile's values; nothing after the switch may touch them, or
        // clearing a key that happens to match would empty the new profile's
        // draft. `draftsProfile` is view state, so it reads the profile now
        // on screen, not the one this call's copy of the view captured.
        let profile = draftsProfile
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var submitted: String?
        if url != savedURL {
            guard await save(url, for: Self.urlKey, profile: profile), draftsProfile == profile else { return }
            submitted = url
        }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            let saved = await save(key, for: Self.apiKeyKey, profile: profile)
            guard draftsProfile == profile else { return }
            guard saved else {
                // The address may have landed; show what the host has now.
                await refreshStatus(submittedURL: submitted, profile: profile)
                return
            }
            if keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == key {
                keyDraft = ""
            }
        }
        let names = changedNames
        let drivesTurns = presetDrivesTurns
        var sentNames: [String: String] = [:]
        if !names.isEmpty || drivesTurns != nil {
            let saved = await service.saveSpeechServer(names: names, drivesTurns: drivesTurns)
            guard draftsProfile == profile else { return }
            if saved {
                sentNames = names
                pickedPreset = nil
                pickedURL = nil
            } else {
                errorMessage = service.errorMessage ?? AppLocalization.string("Could not load voice settings to save this change.", table: .voice)
            }
        }
        await refreshStatus(submittedURL: submitted, submittedNames: sentNames, profile: profile)
        guard draftsProfile == profile else { return }
        if status?.available == true { await runTest(profile: profile) }
    }

    /// The switch saves by itself, like Remove key: true, or the setting
    /// removed, which is off.
    private func saveDriveTurns(_ on: Bool, pickedBefore: Bool? = nil) async {
        isSaving = true
        // Whatever happened, the switch goes back to what the host has.
        defer {
            isSaving = false
            driveTurnsDraft = nil
        }
        testResult = nil
        errorMessage = nil
        let profile = draftsProfile
        let saved = await service.saveSpeechServerDrivesTurns(on)
        if !saved, draftsProfile == profile {
            // The picked server's setting goes back too, so the switch
            // shows what the host still has.
            if let pickedBefore { pickedPreset?.drivesTurns = pickedBefore }
            errorMessage = service.errorMessage ?? AppLocalization.string("Could not load voice settings to save this change.", table: .voice)
        }
        await refreshStatus(submittedURL: nil, profile: profile)
    }

    private func removeKey() async {
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        errorMessage = nil
        let profile = draftsProfile
        _ = await save("", for: Self.apiKeyKey, profile: profile)
        await refreshStatus(submittedURL: nil, profile: profile)
    }

    // Each helper below writes view state only while the drafts still
    // belong to `profile`: after a switch, the old profile's error, status
    // or test result must not show under the new one (where a stale "Remove
    // key" would act on the new profile).

    /// Saves one value; on failure the service's reason is kept for this view.
    private func save(_ value: String, for key: String, profile: String?) async -> Bool {
        let saved = await service.save(value: value, for: key)
        if !saved, draftsProfile == profile {
            errorMessage = service.errorMessage ?? AppLocalization.string("Could not load voice settings to save this change.", table: .voice)
        }
        return saved
    }

    /// Every field still showing the old status takes the new one.
    private func follow(from before: SpeechServerStatus?, to now: SpeechServerStatus) {
        follow(&urlDraft, was: before?.url, sent: nil, now: now.url)
        follow(&modelDraft, was: before?.model, sent: nil, now: now.model)
        follow(&voiceDraft, was: before?.voice, sent: nil, now: now.voice)
        follow(&transcriptionModelDraft, was: before?.transcriptionModel, sent: nil, now: now.transcriptionModel)
    }

    private func follow(_ draft: inout String, was: String?, sent: String?, now: String?) {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name this save sent is compared with what it sent: typed back
        // to the old value meanwhile, it is a newer edit and stays.
        if typed == (sent ?? was ?? "") { draft = now ?? "" }
    }

    private func refreshStatus(submittedURL: String?, submittedNames: [String: String] = [:], profile: String?) async {
        let loaded = await service.speechServerStatus()
        guard draftsProfile == profile else { return }
        // A read that failed after a save leaves the old value shown: the
        // page's next check reads again, as after a failed first read.
        readFailed = loaded.readFailed
        // What's shown stays; a save's own error says more than the read's.
        guard !loaded.readFailed else {
            if errorMessage == nil { errorMessage = loaded.reason }
            return
        }
        // Each name follows the host unless the user has typed another
        // since: one that still reads as it was saved, or as this save
        // sent it, takes what the host has now.
        let before = status
        status = loaded
        follow(&modelDraft, was: before?.model, sent: submittedNames["model"], now: loaded.model)
        follow(&voiceDraft, was: before?.voice, sent: submittedNames["voice"], now: loaded.voice)
        follow(&transcriptionModelDraft, was: before?.transcriptionModel,
               sent: submittedNames["transcription_model"], now: loaded.transcriptionModel)
        // Show what the host will dial (http becomes ws, a bare host gets
        // the realtime path) once it accepted the address, unless the user
        // has typed something else since.
        if let submittedURL, let url = loaded.url,
           urlDraft.trimmingCharacters(in: .whitespacesAndNewlines) == submittedURL {
            urlDraft = url
        }
    }

    private func runTest(profile: String?) async {
        isTesting = true
        defer { isTesting = false }
        let result = await service.testSpeechServer()
        guard draftsProfile == profile else { return }
        testResult = result
    }
}
