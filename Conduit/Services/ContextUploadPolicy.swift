//
//  ContextUploadPolicy.swift
//  Conduit
//
//  When the phone's context (calendar and phone status, Apple Health, the
//  location sent with a message) goes to Hermes again. Each feed rides
//  moments Conduit runs anyway: a message sent, coming to the foreground,
//  Apple Health's wakes, a background refresh. These rules keep those
//  moments from sending again what the host already has, and hold back
//  what can wait in Low Power or Low Data Mode.
//
//  What the user asks for (Sync now, turning sharing on, answering a
//  change) and what Hermes asks for (a push, an on-demand locate) is never
//  held back here.
//

import CryptoKit
import CoreLocation
import Foundation

enum ContextUploadPolicy {
    /// How many times longer routine passes wait. Low Power Mode wins over
    /// Low Data; a metered path alone doesn't count, since these uploads
    /// are small and Low Data Mode is how the user says data matters.
    static func stretch(_ conditions: DeviceConditions) -> Double {
        if conditions.lowPowerMode { return 3 }
        if conditions.lowDataMode { return 2 }
        return 1
    }

    /// Whether a pass may run, `spacing` after the last one started. A
    /// clock that moved back doesn't hold passes off.
    static func isDue(lastAttempt: Date?, spacing: TimeInterval, now: Date) -> Bool {
        guard spacing > 0, let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= spacing
    }

    /// How long until a pass is due, or nil when it is.
    static func remainingSpacing(lastAttempt: Date?, spacing: TimeInterval, now: Date) -> TimeInterval? {
        guard !isDue(lastAttempt: lastAttempt, spacing: spacing, now: now), let lastAttempt else { return nil }
        return spacing - now.timeIntervalSince(lastAttempt)
    }

    // MARK: Calendar and phone

    /// Messages, foregrounds and calendar bursts are frequent and rarely news.
    static let phoneRoutineSpacing: TimeInterval = 30
    /// An upload with nothing new still goes this often while the user is
    /// there (Conduit open, a message, a call). Only an upload moves the
    /// host's `last_seen`: it's the "as_of" Hermes reads, the calendar skill
    /// tells it the phone syncs after every message, and with several
    /// phones the host picks the one seen last.
    static let phoneKeepaliveWhilePresent: TimeInterval = 15 * 60
    /// The same in the background (refresh, a calendar change, Focus).
    static let phoneKeepalive: TimeInterval = 3 * 3600

    /// How old the last upload may be before a pass for `reason` sends one
    /// with nothing new. Zero: always (the user asked).
    static func phoneKeepalive(for reason: PhoneSyncReason) -> TimeInterval {
        switch reason {
        case .manual, .turnedOn: return 0
        case .foreground, .messageSent, .voiceCall, .connected, .answered: return phoneKeepaliveWhilePresent
        case .calendarChanged, .focusChanged, .backgroundRefresh, .push: return phoneKeepalive
        }
    }

    static func phoneSpacing(for reason: PhoneSyncReason, conditions: DeviceConditions) -> TimeInterval {
        switch reason {
        case .foreground, .messageSent, .calendarChanged, .backgroundRefresh:
            return phoneRoutineSpacing * stretch(conditions)
        case .voiceCall:
            // A call reads what's there when it asks: not stretched.
            return phoneRoutineSpacing
        case .connected, .focusChanged, .push, .answered, .manual, .turnedOn:
            return 0
        }
    }

    /// Whether a phone upload goes. `carriesNews`: the batch has a section
    /// to send (events, reminders, status, Focus, alarms, people,
    /// calendars). `frame`: the time zone and sharing it would report,
    /// hashed. Without `hostReportsPending` (an older plugin's status), the
    /// upload's answer is the only way to learn of changes Hermes is
    /// waiting on, so it goes.
    static func phoneIngestNeeded(carriesNews: Bool, frame: String, lastFrame: String?, lastPosted: Date?,
                                  hostReportsPending: Bool, keepalive: TimeInterval = phoneKeepalive, now: Date) -> Bool {
        if carriesNews || !hostReportsPending || frame != lastFrame { return true }
        guard let lastPosted else { return true }
        let elapsed = now.timeIntervalSince(lastPosted)
        return elapsed < 0 || elapsed >= keepalive
    }

    // MARK: Health

    /// Coming back to the app: Apple Health's own wakes cover the rest.
    static let healthForegroundSpacing: TimeInterval = 180
    /// Apple Health wakes once per shared type, often together.
    static let healthWakeSpacing: TimeInterval = 60
    /// Recent days go whole this often even when nothing in them changed,
    /// so a host that lost a window gets it back.
    static let healthWholeResend: TimeInterval = 6 * 3600
    /// A pass that had nothing to send still posts an empty batch this
    /// often: only an upload moves the host's `last_seen` ("last_sync" for
    /// Hermes), as for the phone.
    static let healthKeepalive: TimeInterval = 15 * 60

    /// Whether a pass that posted nothing posts an empty batch.
    static func healthNeedsKeepalive(lastPosted: Date?, now: Date) -> Bool {
        guard let lastPosted else { return true }
        let elapsed = now.timeIntervalSince(lastPosted)
        return elapsed < 0 || elapsed >= healthKeepalive
    }

    /// Apple Health's wake waits for its turn when it's this close (out of
    /// a background wake's half minute): its data then goes in this wake.
    /// Otherwise the next pass, for any reason, runs without waiting.
    static let healthTrailingWait: TimeInterval = 10

    static func healthSpacing(for reason: HealthSyncReason, conditions: DeviceConditions) -> TimeInterval {
        switch reason {
        case .foreground:
            return healthForegroundSpacing * stretch(conditions)
        case .healthChanged, .backgroundRefresh:
            return healthWakeSpacing * stretch(conditions)
        case .voiceCall:
            // A pass in the last three minutes has what the call reads.
            return healthForegroundSpacing
        case .connected, .manual, .turnedOn:
            return 0
        }
    }

    static func healthPass(for reason: HealthSyncReason, conditions: DeviceConditions) -> HealthPassOptions {
        let asked = reason == .manual || reason == .turnedOn
        return HealthPassOptions(
            resendRecent: asked,
            // Low Data Mode: only what changed, and older history waits.
            lowData: conditions.lowDataMode && !asked
        )
    }

    /// Whether this pass sends every recent window again, changed or not.
    static func healthResendsRecent(_ options: HealthPassOptions, lastWhole: Date?, now: Date) -> Bool {
        if options.resendRecent { return true }
        if options.lowData { return false }
        guard let lastWhole else { return true }
        let elapsed = now.timeIntervalSince(lastWhole)
        return elapsed < 0 || elapsed >= healthWholeResend
    }

    // MARK: Location sent with a message

    /// A fix iOS already has answers a message when it's this recent and
    /// the phone wasn't moving faster than a walk.
    static let messageFixReuseAge: TimeInterval = 5 * 60
    /// What iOS's own cache answers anyway (LocationFixProvider's maxAge
    /// for a message).
    static let messageFixFreshAge: TimeInterval = 30
    static let walkingSpeed: CLLocationSpeed = 2
    /// A fix with no speed can't say it was still: reused only younger and
    /// sharper than this.
    static let messageFixUnknownSpeedAge: TimeInterval = 2 * 60
    static let messageFixUnknownSpeedAccuracy: CLLocationAccuracy = 65
    /// The same place again goes no more often than this (stretched in Low
    /// Power and Low Data Mode, up to `messageFixRepeatLongest`, well under
    /// the hour after which the host stops trusting a message's fix).
    static let messageFixRepeat: TimeInterval = 10 * 60
    static let messageFixRepeatLongest: TimeInterval = 30 * 60
    /// A move smaller than this, or than either fix's accuracy, isn't one.
    static let messageFixMove: CLLocationDistance = 100

    /// Whether a fix iOS already has can go with a message instead of a new
    /// one. `speed` below zero is unknown.
    static func reusesFix(age: TimeInterval, accuracy: CLLocationAccuracy, speed: CLLocationSpeed,
                          wanted: CLLocationAccuracy) -> Bool {
        guard age >= 0, accuracy >= 0,
              accuracy <= LocationFixProvider.acceptableCachedAccuracy(for: wanted) else { return false }
        if age <= messageFixFreshAge { return true }
        if speed >= 0 { return age <= messageFixReuseAge && speed <= walkingSpeed }
        // Speed unknown: only a sharp, recent fix (Wi-Fi indoors, say).
        return age <= messageFixUnknownSpeedAge && accuracy <= messageFixUnknownSpeedAccuracy
    }

    /// Whether a message's fix tells the host something the last one sent
    /// with a message or a call didn't.
    static func messageFixIsNews(_ fix: LocationRawFix, precision: LocationPrecision, host: LocationTalkingUpload.Host,
                                 last: LocationTalkingUpload?, now: Date, conditions: DeviceConditions) -> Bool {
        guard let last, last.precision == precision, last.host == host else { return true }
        let elapsed = now.timeIntervalSince(last.sentAt)
        let repeatAfter = min(messageFixRepeat * stretch(conditions), messageFixRepeatLongest)
        if elapsed < 0 || elapsed >= repeatAfter { return true }
        // Much sharper than the last one (a GPS fix after a cell one).
        if last.fix.accuracy > messageFixMove, fix.accuracy < last.fix.accuracy / 2 { return true }
        let distance = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
            .distance(from: CLLocation(latitude: last.fix.latitude, longitude: last.fix.longitude))
        return distance > max(messageFixMove, fix.accuracy, last.fix.accuracy)
    }
}

/// What a health pass may leave out.
struct HealthPassOptions: Equatable {
    /// Send every recent window, changed or not (the user asked).
    var resendRecent = false
    /// Low Data Mode: only windows that changed, no older history.
    var lowData = false

    /// Whether a pass with these options does all a pass with `other` would.
    func covers(_ other: HealthPassOptions) -> Bool {
        (resendRecent || !other.resendRecent) && (!lowData || other.lowData)
    }
}

/// A short hash of a JSON value, for telling whether something changed
/// since it was sent. Keys are sorted; anything JSON can't spell hashes by
/// its description, never all to the same empty value.
enum ContextFingerprint {
    static func of(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            ?? Data(String(describing: value).utf8)
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// The last fix that reached the host with a message or a call. In memory
/// only: the state file never holds a location.
struct LocationTalkingUpload: Equatable {
    /// The host's copy it went to: a new key or store drops the latest fix.
    struct Host: Equatable {
        var keyAgreements: Int
        var generation: String?
    }

    var fix: LocationRawFix
    var precision: LocationPrecision
    var host: Host
    var sentAt: Date
}
