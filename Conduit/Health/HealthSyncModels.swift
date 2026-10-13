//
//  HealthSyncModels.swift
//  Conduit
//
//  Health data for Hermes (designs/health-sync.md). The user turns on
//  sharing per category; Conduit reads Apple Health and sends it straight
//  to one Hermes profile on one dashboard, sealed end to end, never through
//  the push relay. The notifier plugin keeps it for the read-only
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

    /// Deeper reaches further back.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
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

    var isOn: Bool { destination != nil && !categories.isEmpty }

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
