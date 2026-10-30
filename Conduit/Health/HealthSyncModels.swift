//
//  HealthSyncModels.swift
//  Conduit
//
//  Health data for Hermes. The user turns on
//  sharing per category; Conduit reads Apple Health and sends it straight
//  to one Hermes profile on one dashboard, sealed end to end (see
//  HealthSyncCrypto for what that covers), never through the push relay. The notifier plugin keeps it for the read-only
//  `conduit_health` tool.
//
//  What leaves the phone by default is what Apple Health itself computes:
//  hourly and daily totals (iPhone and Watch merged by the user's source
//  priority), a summary per night of sleep, sleep stage segments and
//  workouts. Raw readings go only for categories where the user turns on
//  detailed readings.
//

import Foundation

/// A group of metrics the user shares or not, as one switch.
enum HealthCategory: String, CaseIterable, Identifiable, Codable {
    case activity
    case heart
    case sleep
    case workouts
    case body
    case vitals
    case fitness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return AppLocalization.string("Activity")
        case .heart: return AppLocalization.string("Heart")
        case .sleep: return AppLocalization.string("Sleep")
        case .workouts: return AppLocalization.string("Workouts")
        case .body: return AppLocalization.string("Body measurements")
        case .vitals: return AppLocalization.string("Vitals")
        case .fitness: return AppLocalization.string("Fitness")
        }
    }

    var summary: String {
        switch self {
        case .activity: return AppLocalization.string("Steps, distance, active energy, exercise and stand time, flights climbed")
        case .heart: return AppLocalization.string("Heart rate, resting and walking heart rate, heart rate variability")
        case .sleep: return AppLocalization.string("Time asleep and in bed, sleep stages")
        case .workouts: return AppLocalization.string("Each workout: type, time, duration, energy, distance, heart rate")
        case .body: return AppLocalization.string("Weight, body fat, height")
        case .vitals: return AppLocalization.string("Blood oxygen, respiratory rate, blood pressure, sleeping wrist temperature")
        case .fitness: return AppLocalization.string("Cardio fitness (VO2 max), walking speed, six-minute walk")
        }
    }

    var symbol: String {
        switch self {
        case .activity: return "figure.walk"
        case .heart: return "heart"
        case .sleep: return "bed.double"
        case .workouts: return "figure.run"
        case .body: return "scalemass"
        case .vitals: return "waveform.path.ecg"
        case .fitness: return "lungs"
        }
    }

    /// Whether raw readings exist to share for this category. Sleep and
    /// workouts are always sent as their own events.
    var hasDetailedReadings: Bool {
        switch self {
        case .sleep, .workouts: return false
        default: return true
        }
    }

    var metrics: [HealthMetric] { HealthMetric.allCases.filter { $0.category == self } }
}

/// How a metric's buckets are computed: a sum (cumulative) or
/// min/avg/max (discrete). HealthKit refuses the wrong one for a type.
enum HealthAggregation {
    case sum
    case stats
}

/// A metric Conduit sends as hourly and daily buckets. The raw values and
/// units must match METRICS in the notifier's health_store.py.
enum HealthMetric: String, CaseIterable, Codable {
    case steps
    case distanceWalkingRunning = "distance_walking_running"
    case distanceCycling = "distance_cycling"
    case activeEnergy = "active_energy"
    case exerciseTime = "exercise_time"
    case standTime = "stand_time"
    case flightsClimbed = "flights_climbed"
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case walkingHeartRateAverage = "walking_heart_rate_average"
    case heartRateVariability = "heart_rate_variability"
    case oxygenSaturation = "oxygen_saturation"
    case respiratoryRate = "respiratory_rate"
    case bloodPressureSystolic = "blood_pressure_systolic"
    case bloodPressureDiastolic = "blood_pressure_diastolic"
    case wristTemperature = "wrist_temperature"
    case bodyMass = "body_mass"
    case bodyFatPercentage = "body_fat_percentage"
    case height
    case vo2Max = "vo2_max"
    case walkingSpeed = "walking_speed"
    case sixMinuteWalkDistance = "six_minute_walk_distance"

    var category: HealthCategory {
        switch self {
        case .steps, .distanceWalkingRunning, .distanceCycling, .activeEnergy, .exerciseTime, .standTime, .flightsClimbed:
            return .activity
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .heartRateVariability:
            return .heart
        case .oxygenSaturation, .respiratoryRate, .bloodPressureSystolic, .bloodPressureDiastolic, .wristTemperature:
            return .vitals
        case .bodyMass, .bodyFatPercentage, .height:
            return .body
        case .vo2Max, .walkingSpeed, .sixMinuteWalkDistance:
            return .fitness
        }
    }

    var aggregation: HealthAggregation {
        category == .activity ? .sum : .stats
    }

    /// The unit the host stores, as health_store.py spells it.
    var unit: String {
        switch self {
        case .steps, .flightsClimbed: return "count"
        case .distanceWalkingRunning, .distanceCycling, .height, .sixMinuteWalkDistance: return "m"
        case .activeEnergy: return "kcal"
        case .exerciseTime, .standTime: return "min"
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .respiratoryRate: return "count/min"
        case .heartRateVariability: return "ms"
        case .oxygenSaturation, .bodyFatPercentage: return "%"
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "mmHg"
        case .wristTemperature: return "degC"
        case .bodyMass: return "kg"
        case .vo2Max: return "mL/(kg*min)"
        case .walkingSpeed: return "m/s"
        }
    }

    /// Hourly buckets are worth it where the hour says something (when the
    /// user moved, how their heart rate went); the rest is daily only.
    var hasHourlyBuckets: Bool {
        switch self {
        case .steps, .distanceWalkingRunning, .distanceCycling, .activeEnergy, .exerciseTime, .standTime,
             .flightsClimbed, .heartRate:
            return true
        default:
            return false
        }
    }
}

/// How far back the first sync reaches. Eric's choice (2026-10-13):
/// 30 days by default, up to everything.
enum HealthHistoryDepth: String, CaseIterable, Identifiable, Codable {
    case days30
    case days90
    case year
    case all

    static let `default`: HealthHistoryDepth = .days30

    var id: String { rawValue }

    var title: String {
        switch self {
        case .days30: return AppLocalization.string("30 days")
        case .days90: return AppLocalization.string("90 days")
        case .year: return AppLocalization.string("1 year")
        case .all: return AppLocalization.string("All history")
        }
    }

    /// Days before today, or nil for everything Health keeps.
    var days: Int? {
        switch self {
        case .days30: return 30
        case .days90: return 90
        case .year: return 365
        case .all: return nil
        }
    }
}

/// Hourly buckets reach back this far at most; older history is daily.
enum HealthSyncLimits {
    static let hourlyHistoryDays = 30
    /// Recent days are recomputed on every pass: the Watch often syncs late.
    static let recomputedDays = 3
    /// Items per sealed batch: well under the host's 6,000, and small
    /// enough for the dashboard page's fetch.
    static let maxItemsPerBatch = 2_000
    /// Days of history per backfill step.
    static let backfillChunkDays = 30
    /// The host refuses times before this (health_store.py's EARLIEST).
    static let hostEarliest = Date(timeIntervalSince1970: 946_684_800)

    /// The first day history may start on: a local midnight late enough
    /// that its sleep window, which opens at noon the day before, is still
    /// after `hostEarliest` in any time zone.
    static func oldestDay(calendar: Calendar) -> Date {
        calendar.startOfDay(for: hostEarliest.addingTimeInterval(2 * 86_400))
    }
    /// Raw readings per type per query page.
    static let samplesPerQuery = 1_000
}

/// Where health data goes: one profile on one saved dashboard, fixed when
/// the user turns sharing on. Changing it means turning sharing off and on.
struct HealthSyncDestination: Codable, Equatable {
    var dashboardID: UUID
    var profile: String
    /// The dashboard's address when sharing was turned on, for display.
    var host: String
}

/// The user's choices, kept in UserDefaults (no health data in them).
struct HealthSyncPreferences: Codable, Equatable {
    var destination: HealthSyncDestination?
    var categories: Set<HealthCategory> = []
    var detailed: Set<HealthCategory> = []
    var history: HealthHistoryDepth = .default
    /// Live voice modes the user lets read this data on a call
    /// (`LiveVoiceModeName.storageID`). Optional so preferences saved
    /// before it still decode; nil is none.
    var voiceReaders: [String]?

    var isOn: Bool { destination != nil && !categories.isEmpty }

    /// Whether a live call on `mode` may read the shared data.
    func letsVoiceRead(_ mode: LiveVoiceModeName) -> Bool {
        isOn && (voiceReaders ?? []).contains(mode.storageID)
    }

    mutating func setVoiceRead(_ mode: LiveVoiceModeName, allowed: Bool) {
        var readers = Set(voiceReaders ?? [])
        if allowed { readers.insert(mode.storageID) } else { readers.remove(mode.storageID) }
        voiceReaders = readers.isEmpty ? nil : readers.sorted()
    }

    static let storageKey = "conduit.healthSync.preferences.v1"

    static func load(from defaults: UserDefaults = .standard) -> HealthSyncPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(HealthSyncPreferences.self, from: data) else {
            return HealthSyncPreferences()
        }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// A deletion the user asked for while the host couldn't be reached: this
/// phone's data on that dashboard and profile, deleted on the next connect.
/// One may be owed on each of several dashboards.
struct HealthSyncPendingDeletion: Codable, Equatable {
    var dashboardID: UUID
    var profile: String
    var deviceID: String

    static let storageKey = "conduit.healthSync.pendingDeletions.v1"

    static func all(in defaults: UserDefaults = .standard) -> [HealthSyncPendingDeletion] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([HealthSyncPendingDeletion].self, from: $0) } ?? []
    }

    /// The deletion owed on a dashboard, if any.
    static func owed(on dashboardID: UUID, in defaults: UserDefaults = .standard) -> HealthSyncPendingDeletion? {
        all(in: defaults).first { $0.dashboardID == dashboardID }
    }

    func save(to defaults: UserDefaults = .standard) {
        Self.store(Self.all(in: defaults).filter { $0 != self } + [self], in: defaults)
    }

    func clear(from defaults: UserDefaults = .standard) {
        Self.store(Self.all(in: defaults).filter { $0 != self }, in: defaults)
    }

    private static func store(_ deletions: [HealthSyncPendingDeletion], in defaults: UserDefaults) {
        guard !deletions.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(deletions) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Why sharing is paused, in words the Health page shows.
enum HealthSyncPause: Codable, Equatable {
    /// The dashboard asked for sign-in; the next pass on screen catches up.
    case signInRequired
    /// The host's plugin doesn't serve health sync (missing or too old).
    case pluginMissing
    /// Another dashboard is in use; sharing waits for its own.
    case otherDashboard
    /// The host refused a batch for a reason a retry won't fix.
    case refused(String)

    var message: String {
        switch self {
        case .signInRequired:
            return AppLocalization.string("Paused: sign in to this dashboard again. Sharing catches up when you open Conduit.")
        case .pluginMissing:
            return AppLocalization.string("Paused: update the Conduit plugin on this host to share health data.")
        case .otherDashboard:
            return AppLocalization.string("Waiting: health data goes only to the dashboard it was turned on for. Switch back to it to sync.")
        case .refused(let detail):
            return AppLocalization.string("Paused: the host refused health data (\(detail)).")
        }
    }
}

/// What live voice calls read of the shared health data (or, under
/// `phoneStorageKey`, the calendar and phone status): when, which mode,
/// which kind of read. Never the values. Kept on this iPhone for a week and
/// shown in Settings > Health (Calendar & phone), since the phone makes
/// every voice read.
struct HealthVoiceReadLog: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var at: Date
        /// `LiveVoiceModeName.storageID` (a display name in entries from
        /// before it was stored).
        var mode: String
        /// The tool's action ("sleep", "daily").
        var action: String
        /// Two reads can share a timestamp; not stored.
        var id = UUID()

        private enum CodingKeys: String, CodingKey { case at, mode, action }

        /// The mode's name in the reads list.
        var modeName: String {
            LiveVoiceModeName.all.first { $0.storageID == mode }?.displayName ?? mode
        }
    }

    var entries: [Entry] = []

    static let storageKey = "conduit.healthSync.voiceReads.v1"
    static let phoneStorageKey = "conduit.phoneSync.voiceReads.v1"
    /// Live voice calls' maps lookups (MapsVoiceTool), listed in Settings >
    /// Location beside the host's reads.
    static let locationStorageKey = "conduit.location.voiceReads.v1"
    static let keptFor: TimeInterval = 7 * 24 * 3600
    static let maximumEntries = 200

    static func load(key: String = storageKey, from defaults: UserDefaults = .standard,
                     now: Date = Date()) -> HealthVoiceReadLog {
        guard let data = defaults.data(forKey: key),
              var log = try? JSONDecoder().decode(HealthVoiceReadLog.self, from: data) else {
            return HealthVoiceReadLog()
        }
        let count = log.entries.count
        log.entries.removeAll { now.timeIntervalSince($0.at) > keptFor }
        if log.entries.count != count, let data = try? JSONEncoder().encode(log) {
            defaults.set(data, forKey: key)
        }
        return log
    }

    static func record(mode: LiveVoiceModeName, action: String, key: String = storageKey,
                       in defaults: UserDefaults = .standard, now: Date = Date()) {
        var log = load(key: key, from: defaults, now: now)
        log.entries.append(Entry(at: now, mode: mode.storageID, action: String(action.prefix(40))))
        if log.entries.count > maximumEntries { log.entries.removeFirst(log.entries.count - maximumEntries) }
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: key) }
    }

    static func clear(key: String = storageKey, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
