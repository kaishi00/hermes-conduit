//
//  HealthKitSource.swift
//  Conduit
//
//  Reads Apple Health for health sync: totals through HealthKit's own
//  statistics (so iPhone and Watch merge the way the Health app shows
//  them), and workouts, sleep and raw readings through anchored queries,
//  which also report deletions. Read-only: Conduit never writes to Health.
//
//  HealthKit can't be read while the phone is locked with data protection
//  on; those reads fail with `errorDatabaseInaccessible`, which the engine
//  treats as "later", never as a failure.
//

import Foundation
import HealthKit
import os

/// What the sync engine needs from Apple Health. Tests use a fake.
protocol HealthDataSource: AnyObject {
    var isAvailable: Bool { get }
    /// Detailed readings read the same types as the summaries, so `detailed`
    /// asks for nothing more today; it's passed for sources that differ.
    func requestAuthorization(for categories: Set<HealthCategory>, detailed: Set<HealthCategory>) async throws
    /// Hourly or daily buckets for `metric` in [from, to).
    func buckets(_ metric: HealthMetric, grain: HealthGrain, from: Date, to: Date, calendar: Calendar) async throws -> [HealthBucket]
    func sleepSegments(from: Date, to: Date) async throws -> [HealthSleepSegment]
    /// New and deleted events since `anchor` for one stream, starting no
    /// earlier than `since`. `anchor` is opaque and goes back unchanged.
    func changes(_ stream: HealthEventStream, since: Date, anchor: Data?, limit: Int) async throws -> HealthEventChanges
    /// The earliest date Health keeps, for "All history".
    func earliestDate() -> Date
    /// When the oldest reading the history walk would send for these
    /// categories (their metrics and sleep) starts; nil when there is none.
    func oldestReading(in categories: Set<HealthCategory>) async throws -> Date?
    /// Wakes Conduit in the background when these streams change.
    func observe(_ categories: Set<HealthCategory>, onChange: @escaping (_ done: @escaping () -> Void) -> Void) async
    func stopObserving() async
}

/// A stream of events with its own anchor.
enum HealthEventStream: Hashable {
    case workouts
    case sleep
    case samples(HealthMetric)

    var key: String {
        switch self {
        case .workouts: return "workouts"
        case .sleep: return "sleep"
        case .samples(let metric): return "samples.\(metric.rawValue)"
        }
    }
}

struct HealthEventChanges {
    var added: [HealthEvent]
    var deleted: [String]
    var anchor: Data?
    /// More waits behind this page.
    var more: Bool
}

enum HealthDataSourceError: Error {
    /// Locked phone: Health is unreadable until the user unlocks it.
    case locked
    case unavailable
}

final class HealthKitDataSource: HealthDataSource {
    private static let log = Logger(subsystem: "com.milim.relay", category: "health-sync")
    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    /// Bumped by every stop, so an `observe` overtaken by a later stop or
    /// observe leaves nothing running.
    private var generation = 0
    private let lock = NSLock()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Types

    static func quantityType(_ metric: HealthMetric) -> HKQuantityType {
        switch metric {
        case .steps: return HKQuantityType(.stepCount)
        case .distanceWalkingRunning: return HKQuantityType(.distanceWalkingRunning)
        case .distanceCycling: return HKQuantityType(.distanceCycling)
        case .activeEnergy: return HKQuantityType(.activeEnergyBurned)
        case .exerciseTime: return HKQuantityType(.appleExerciseTime)
        case .standTime: return HKQuantityType(.appleStandTime)
        case .flightsClimbed: return HKQuantityType(.flightsClimbed)
        case .heartRate: return HKQuantityType(.heartRate)
        case .restingHeartRate: return HKQuantityType(.restingHeartRate)
        case .walkingHeartRateAverage: return HKQuantityType(.walkingHeartRateAverage)
        case .heartRateVariability: return HKQuantityType(.heartRateVariabilitySDNN)
        case .oxygenSaturation: return HKQuantityType(.oxygenSaturation)
        case .respiratoryRate: return HKQuantityType(.respiratoryRate)
        case .bloodPressureSystolic: return HKQuantityType(.bloodPressureSystolic)
        case .bloodPressureDiastolic: return HKQuantityType(.bloodPressureDiastolic)
        case .wristTemperature: return HKQuantityType(.appleSleepingWristTemperature)
        case .bodyMass: return HKQuantityType(.bodyMass)
        case .bodyFatPercentage: return HKQuantityType(.bodyFatPercentage)
        case .height: return HKQuantityType(.height)
        case .vo2Max: return HKQuantityType(.vo2Max)
        case .walkingSpeed: return HKQuantityType(.walkingSpeed)
        case .sixMinuteWalkDistance: return HKQuantityType(.sixMinuteWalkTestDistance)
        }
    }

    /// The HealthKit unit for `metric`, and the factor to the host's unit
    /// (HealthKit's percent is a fraction).
    static func unit(_ metric: HealthMetric) -> (HKUnit, Double) {
        switch metric.unit {
        case "count": return (.count(), 1)
        case "m": return (.meter(), 1)
        case "kcal": return (.kilocalorie(), 1)
        case "min": return (.minute(), 1)
        case "count/min": return (.count().unitDivided(by: .minute()), 1)
        case "ms": return (.secondUnit(with: .milli), 1)
        case "%": return (.percent(), 100)
        case "mmHg": return (.millimeterOfMercury(), 1)
        case "degC": return (.degreeCelsius(), 1)
        case "kg": return (.gramUnit(with: .kilo), 1)
        case "mL/(kg*min)": return (HKUnit(from: "ml/kg*min"), 1)
        case "m/s": return (.meter().unitDivided(by: .second()), 1)
        default: return (.count(), 1)
        }
    }

    static func readTypes(for categories: Set<HealthCategory>) -> Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        for category in categories {
            for metric in category.metrics { types.insert(quantityType(metric)) }
            switch category {
            case .sleep: types.insert(HKCategoryType(.sleepAnalysis))
            case .workouts:
                types.insert(HKObjectType.workoutType())
                // A workout's energy, distance and heart rate.
                types.insert(HKQuantityType(.activeEnergyBurned))
                types.insert(HKQuantityType(.distanceWalkingRunning))
                types.insert(HKQuantityType(.distanceCycling))
                types.insert(HKQuantityType(.distanceSwimming))
                types.insert(HKQuantityType(.heartRate))
            default: break
            }
        }
        return types
    }

    // MARK: HealthDataSource

    func requestAuthorization(for categories: Set<HealthCategory>, detailed: Set<HealthCategory>) async throws {
        guard isAvailable else { throw HealthDataSourceError.unavailable }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes(for: categories))
    }

    func buckets(_ metric: HealthMetric, grain: HealthGrain, from: Date, to: Date, calendar: Calendar) async throws -> [HealthBucket] {
        let type = Self.quantityType(metric)
        let (unit, factor) = Self.unit(metric)
        let options: HKStatisticsOptions = metric.aggregation == .sum
            ? .cumulativeSum
            : [.discreteMin, .discreteAverage, .discreteMax]
        let interval = grain == .hour ? DateComponents(hour: 1) : DateComponents(day: 1)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: options,
            anchorDate: calendar.startOfDay(for: from),
            intervalComponents: interval
        )
        let collection: HKStatisticsCollection
        do {
            collection = try await descriptor.result(for: store)
        } catch {
            throw Self.mapped(error)
        }
        var buckets: [HealthBucket] = []
        collection.enumerateStatistics(from: from, to: to) { statistics, _ in
            guard statistics.startDate >= from, statistics.startDate < to else { return }
            var bucket = HealthBucket(start: statistics.startDate, end: statistics.endDate)
            if metric.aggregation == .sum {
                guard let sum = statistics.sumQuantity() else { return }
                bucket.sum = sum.doubleValue(for: unit) * factor
            } else {
                guard let avg = statistics.averageQuantity() else { return }
                bucket.avg = avg.doubleValue(for: unit) * factor
                bucket.min = statistics.minimumQuantity().map { $0.doubleValue(for: unit) * factor }
                bucket.max = statistics.maximumQuantity().map { $0.doubleValue(for: unit) * factor }
            }
            buckets.append(bucket)
        }
        return buckets
    }

    func sleepSegments(from: Date, to: Date) async throws -> [HealthSleepSegment] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        do {
            return try await descriptor.result(for: store).compactMap(Self.segment)
        } catch {
            throw Self.mapped(error)
        }
    }

    func changes(_ stream: HealthEventStream, since: Date, anchor: Data?, limit: Int) async throws -> HealthEventChanges {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        let previous = anchor.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        do {
            switch stream {
            case .workouts:
                let descriptor = HKAnchoredObjectQueryDescriptor(
                    predicates: [.workout(predicate)], anchor: previous, limit: limit)
                let result = try await descriptor.result(for: store)
                return HealthEventChanges(
                    added: result.addedSamples.map(Self.event),
                    deleted: result.deletedObjects.map { $0.uuid.uuidString },
                    anchor: Self.archived(result.newAnchor),
                    more: result.addedSamples.count + result.deletedObjects.count >= limit)
            case .sleep:
                let descriptor = HKAnchoredObjectQueryDescriptor(
                    predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                    anchor: previous, limit: limit)
                let result = try await descriptor.result(for: store)
                return HealthEventChanges(
                    added: result.addedSamples.compactMap(Self.segment).map(Self.event),
                    deleted: result.deletedObjects.map { $0.uuid.uuidString },
                    anchor: Self.archived(result.newAnchor),
                    more: result.addedSamples.count + result.deletedObjects.count >= limit)
            case .samples(let metric):
                let descriptor = HKAnchoredObjectQueryDescriptor(
                    predicates: [.quantitySample(type: Self.quantityType(metric), predicate: predicate)],
                    anchor: previous, limit: limit)
                let result = try await descriptor.result(for: store)
                let (unit, factor) = Self.unit(metric)
                return HealthEventChanges(
                    added: result.addedSamples.map { sample in
                        HealthEvent(id: sample.uuid.uuidString, kind: .sample, metric: metric.rawValue,
                                    start: sample.startDate, end: sample.endDate,
                                    value: sample.quantity.doubleValue(for: unit) * factor, unit: metric.unit,
                                    source: sample.sourceRevision.source.name)
                    },
                    deleted: result.deletedObjects.map { $0.uuid.uuidString },
                    anchor: Self.archived(result.newAnchor),
                    more: result.addedSamples.count + result.deletedObjects.count >= limit)
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    func earliestDate() -> Date { store.earliestPermittedSampleDate() }

    func oldestReading(in categories: Set<HealthCategory>) async throws -> Date? {
        var predicates: [HKSamplePredicate<HKSample>] = categories.flatMap(\.metrics).map { .sample(type: Self.quantityType($0)) }
        if categories.contains(.sleep) { predicates.append(.sample(type: HKCategoryType(.sleepAnalysis))) }
        guard !predicates.isEmpty else { return nil }
        // One query across the types, sorted, so only the oldest comes back.
        let descriptor = HKSampleQueryDescriptor(predicates: predicates, sortDescriptors: [SortDescriptor(\.startDate)], limit: 1)
        do {
            return try await descriptor.result(for: store).first?.startDate
        } catch {
            throw Self.mapped(error)
        }
    }

    func observe(_ categories: Set<HealthCategory>, onChange: @escaping (_ done: @escaping () -> Void) -> Void) async {
        let mine = await stopAll()
        var types: [HKSampleType] = []
        for category in categories {
            switch category {
            case .sleep: types.append(HKCategoryType(.sleepAnalysis))
            case .workouts: types.append(HKObjectType.workoutType())
            default:
                // One type per category is enough to wake Conduit: a pass
                // reads every shared metric. Steps and heart rate change
                // most often.
                guard let metric = category.metrics.first(where: { $0 == .steps || $0 == .heartRate })
                    ?? category.metrics.first else { continue }
                types.append(Self.quantityType(metric))
            }
        }
        // Another stop or observe ran meanwhile: the latest one wins.
        guard lock.withLock({ generation == mine }) else { return }
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                // An error means no data came with this call; HealthKit
                // retries later. Finish it so it isn't held open.
                guard error == nil else {
                    completion()
                    return
                }
                onChange { completion() }
            }
            // Recorded as it starts, so a stop running meanwhile sees it.
            let current = lock.withLock { () -> Bool in
                guard generation == mine else { return false }
                observers.append(query)
                return true
            }
            guard current else { return }
            store.execute(query)
            // Hourly is the most HealthKit allows for steps anyway, and an
            // agent gains nothing from minute-by-minute wakes.
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .hourly)
            } catch {
                // Without it only foreground and background-refresh passes run.
                Self.log.error("Health background delivery failed: \(LogRedaction.message(error), privacy: .public)")
            }
            if lock.withLock({ generation != mine }) {
                // Stopped while this was being turned on. The stop may have
                // run before the query did, so stop it again here. Delivery
                // stays on if a newer observe already owns it.
                store.stop(query)
                if lock.withLock({ observers.isEmpty }) {
                    try? await store.disableBackgroundDelivery(for: type)
                }
                return
            }
        }
    }

    func stopObserving() async {
        await stopAll()
    }

    /// The generation this stop started; a later stop or observe bumps it.
    @discardableResult
    private func stopAll() async -> Int {
        let (running, mine) = lock.withLock { () -> ([HKObserverQuery], Int) in
            generation += 1
            defer { observers = [] }
            return (observers, generation)
        }
        for query in running { store.stop(query) }
        try? await store.disableAllBackgroundDelivery()
        return mine
    }

    // MARK: Mapping

    private static func archived(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private static func mapped(_ error: Error) -> Error {
        if let error = error as? HKError, error.code == .errorDatabaseInaccessible { return HealthDataSourceError.locked }
        return error
    }

    static func segment(_ sample: HKCategorySample) -> HealthSleepSegment? {
        let stage: HealthSleepStage
        switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
        case .inBed: stage = .inBed
        case .asleepUnspecified: stage = .asleep
        case .awake: stage = .awake
        case .asleepCore: stage = .core
        case .asleepDeep: stage = .deep
        case .asleepREM: stage = .rem
        default: return nil
        }
        let revision = sample.sourceRevision
        return HealthSleepSegment(
            id: sample.uuid.uuidString, stage: stage, start: sample.startDate, end: sample.endDate,
            source: revision.source.name, fromWatch: revision.productType?.hasPrefix("Watch") == true)
    }

    static func event(_ segment: HealthSleepSegment) -> HealthEvent {
        HealthEvent(id: segment.id, kind: .sleep, metric: "sleep", start: segment.start, end: segment.end,
                    data: ["stage": .text(segment.stage.rawValue)], source: segment.source)
    }

    static func event(_ workout: HKWorkout) -> HealthEvent {
        var data: [String: HealthValue] = [
            "activity": .text(activityName(workout.workoutActivityType)),
            "duration_min": .number((workout.duration / 60 * 10).rounded() / 10),
        ]
        if let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
            data["energy_kcal"] = .number(energy.doubleValue(for: .kilocalorie()).rounded())
        }
        let distances: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
        let meters = distances.compactMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter()) }
            .reduce(0, +)
        if meters > 0 { data["distance_m"] = .number(meters.rounded()) }
        let heartRate = workout.statistics(for: HKQuantityType(.heartRate))
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        if let average = heartRate?.averageQuantity() {
            data["avg_heart_rate"] = .number(average.doubleValue(for: perMinute).rounded())
        }
        if let maximum = heartRate?.maximumQuantity() {
            data["max_heart_rate"] = .number(maximum.doubleValue(for: perMinute).rounded())
        }
        return HealthEvent(id: workout.uuid.uuidString, kind: .workout, metric: "workout",
                           start: workout.startDate, end: workout.endDate, data: data,
                           source: workout.sourceRevision.source.name)
    }

    static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .traditionalStrengthTraining: return "strength_training"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .highIntensityIntervalTraining: return "hiit"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stair_climbing"
        case .cardioDance, .socialDance: return "dance"
        case .coreTraining: return "core_training"
        case .pilates: return "pilates"
        case .soccer: return "soccer"
        case .basketball: return "basketball"
        case .tennis: return "tennis"
        case .golf: return "golf"
        case .crossTraining: return "cross_training"
        case .mixedCardio: return "mixed_cardio"
        case .mindAndBody: return "mind_and_body"
        case .cooldown: return "cooldown"
        case .flexibility: return "flexibility"
        case .climbing: return "climbing"
        case .martialArts: return "martial_arts"
        case .boxing, .kickboxing: return "boxing"
        case .downhillSkiing, .crossCountrySkiing: return "skiing"
        case .snowboarding: return "snowboarding"
        case .paddleSports: return "paddling"
        case .surfingSports: return "surfing"
        case .wheelchairWalkPace, .wheelchairRunPace: return "wheelchair"
        default: return "other_\(type.rawValue)"
        }
    }
}
