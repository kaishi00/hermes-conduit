//
//  SpeechServerVoiceSettingsView.swift
//  Conduit
//
//  Replies spoken by the user's own speech server, the one Classic listens
//  through. The server's LLM setting points at the notifier's model address
//  so it reads Hermes' replies back word for word; this view shows that
//  address, its key and the flags to start the server with.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SpeechServerVoiceSettingsView: View {
    @ObservedObject var service: HermesVoiceConfigurationService
    /// Classic's line about the server speaking replies; Local Live's
    /// section says it its own way.
    var showsIntro = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var status: SpeechServerVoiceStatus?
    @State private var isRotating = false
    @State private var rotateError: String?
    /// Bumped by each load (a profile switch), so a rotate that finishes
    /// later doesn't show the old profile's status.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsIntro {
                Label(AppLocalization.string("Your speech server speaks the replies in its own voice, so one server listens and speaks. It uses the address set under Speech to text."), systemImage: "server.rack")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let status {
                if let address = status.modelAddress, let key = status.apiKey {
                    Text(AppLocalization.string("On the speech server, set its language model to this address and key, with the model name \(status.modelName). It then reads Hermes' replies aloud instead of writing its own."))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let setup = status.agentSetupText {
                        agentSetupButton(setup)
                    }
                    copyRow(title: AppLocalization.string("Model address"), value: address, identifier: "voice.speechServerVoice.address")
                    copyRow(title: AppLocalization.string("Key"), value: key, identifier: "voice.speechServerVoice.key")
                    if let flags = status.serverFlags {
                        copyRow(title: AppLocalization.string("Flags for speech-to-speech"), value: flags, identifier: "voice.speechServerVoice.flags")
                    }
                    Text(AppLocalization.string("Run it with two pipelines so it can listen and speak at once."))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    lastAskedRow(status.lastRequestAt)
                    HStack {
                        Button(role: .destructive) { Task { await rotate() } } label: {
                            if isRotating {
                                ProgressView().accessibilityLabel(Text(AppLocalization.string("Making a new key…")))
                            } else { Text(AppLocalization.string("Make a new key")) }
                        }
                        .accessibilityLabel(Text(AppLocalization.string("Make a new key")))
                        .disabled(isRotating)
                        .accessibilityIdentifier("voice.speechServerVoice.rotate")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .scaledFont(.footnote)
                }
                if !status.available || status.modelAddress == nil {
                    Label(status.reason ?? AppLocalization.string("Your Hermes host didn't send a key."), systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice.speechServerVoice.reason")
                }
                if let rotateError {
                    Label(rotateError, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                }
            } else {
                ProgressView()
                    .accessibilityLabel(Text(AppLocalization.string("Loading profile voice settings…")))
            }
        }
        .task(id: service.profile) { await load() }
        // After a read that failed, the page's next check (its Check again
        // too) asks the host again.
        .onChange(of: service.isLoading) { _, loading in
            guard !loading, status?.readFailed == true, !isRotating else { return }
            Task { await read() }
        }
    }

    /// Everything above as one block, for an agent or whoever sets up the
    /// server, rather than commands a person runs one by one.
    private func agentSetupButton(_ setup: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Self.copy(setup)
                UIAccessibility.post(notification: .announcement, argument: AppLocalization.string("Copied"))
            } label: {
                Label(AppLocalization.string("Copy setup for your agent"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.settingsPrimary)
            .accessibilityIdentifier("voice.speechServerVoice.copySetup")
            Text(AppLocalization.string("One block with the address, key and flags, written for whoever sets up the server, such as your Hermes agent."))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The key is a credential: what this screen copies leaves the
    /// clipboard after ten minutes, time enough to paste it on the server.
    private static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.expirationDate: Date().addingTimeInterval(600)])
    }

    private func copyRow(title: String, value: String, identifier: String) -> some View {
        // At accessibility text sizes the button goes under the title.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout())
        return VStack(alignment: .leading, spacing: 4) {
            layout {
                Text(verbatim: title).scaledFont(.subheadline.weight(.semibold))
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Button(AppLocalization.string("Copy")) {
                    Self.copy(value)
                    UIAccessibility.post(notification: .announcement, argument: AppLocalization.string("Copied"))
                }
                .buttonStyle(.borderless)
                .scaledFont(.footnote)
                .accessibilityLabel(Text(AppLocalization.string("Copy \(title)")))
                .accessibilityIdentifier(identifier)
            }
            Text(verbatim: value)
                .scaledFont(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func lastAskedRow(_ date: Date?) -> some View {
        if let date {
            Label(AppLocalization.string("Your speech server last asked for words \(date.formatted(.relative(presentation: .named))). It's pointed here."), systemImage: "checkmark.circle.fill")
                .scaledFont(.caption)
                .foregroundStyle(.green)
        } else {
            Label(AppLocalization.string("Your speech server hasn't asked for words yet. Set the address and key on it, then restart it."), systemImage: "clock")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A profile switch starts from that profile's status.
    private func load() async {
        status = nil
        rotateError = nil
        await read()
    }

    private func read() async {
        generation += 1
        let started = generation
        let loaded = await service.speechServerVoiceStatus()
        // A rotate meanwhile shows the new key, not this older read.
        guard !Task.isCancelled, generation == started else { return }
        status = loaded
    }

    private func rotate() async {
        generation += 1
        let started = generation
        isRotating = true
        defer { isRotating = false }
        rotateError = nil
        let rotated = await service.rotateSpeechServerVoiceKey()
        // Read now: later work on the service can replace its message.
        let failure = rotated ? nil : service.errorMessage
        let loaded = await service.speechServerVoiceStatus()
        // A profile switch meanwhile loads that profile's own status.
        guard generation == started else { return }
        rotateError = failure
        // A read that fails keeps what's shown while its key still works
        // (#1533); after a new key, the one shown would be wrong.
        if rotated || !loaded.readFailed { status = loaded }
    }
}
