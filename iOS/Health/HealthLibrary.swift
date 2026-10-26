import Foundation
import HealthKit
import Observation

@MainActor @Observable
final class HealthLibrary {
  var available: Bool { HKHealthStore.isHealthDataAvailable() }
  private(set) var loading = false
  private(set) var notice: String?
  private(set) var lastRefresh: Date?
  private(set) var dailyMetrics: [HealthDailyMetrics] = []
  private(set) var workouts: [HealthWorkoutSummary] = []
  private(set) var metricStates: [HealthMetric: HealthReadState] = [:]
  private(set) var workoutState: HealthReadState = .notRequested
  private(set) var readRequested: Bool

  @ObservationIgnored private let store = HKHealthStore()
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var cancelReads: [UUID: () -> Void] = [:]
  @ObservationIgnored private var exporting: Set<UUID> = []
  private static let requestedKey = "outdoor-log.health.read-requested"
  private static let titleKey = "OutdoorLogWorkoutTitle"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.readRequested = defaults.bool(forKey: Self.requestedKey)
  }

  func requestReadAccess() async throws {
    guard available else { throw HealthLibraryError.unavailable }
    let types: Set<HKObjectType> = [HKObjectType.workoutType(),
      HKQuantityType(.stepCount), HKQuantityType(.distanceWalkingRunning),
      HKQuantityType(.distanceCycling), HKQuantityType(.activeEnergyBurned), HKQuantityType(.heartRate)]
    try await store.requestAuthorization(toShare: [], read: types)
    // This records that the system sheet completed, never that reading was allowed.
    readRequested = true
    defaults.set(true, forKey: Self.requestedKey)
  }

  func clearReadResults() {
    generation = UUID()
    let cancellations = Array(cancelReads.values)
    cancelReads.removeAll()
    cancellations.forEach { $0() }
    dailyMetrics = []
    workouts = []
    metricStates = [:]
    workoutState = .notRequested
    loading = false
    lastRefresh = nil
    notice = nil
  }

  func refresh(days: Int) async {
    clearReadResults()
    guard available else { notice = HealthLibraryError.unavailable.localizedDescription; return }
    guard readRequested else { return }
    guard let window = HealthDateWindow(days: days, now: Date()) else {
      notice = HealthLibraryError.invalidPeriod.localizedDescription
      return
    }
    let current = generation
    loading = true
    workoutState = .loading
    metricStates = Dictionary(uniqueKeysWithValues: HealthMetric.allCases.map { ($0, .loading) })
    defer {
      if generation == current {
        loading = false
        if Task.isCancelled { clearReadResults() }
      }
    }

    async let steps = outcome(generation: current) { try await self.readDaily(.stepCount, unit: .count(), window: window) }
    async let distance = outcome(generation: current) { try await self.readDaily(.distanceWalkingRunning, unit: .meter(), window: window) }
    async let energy = outcome(generation: current) { try await self.readDaily(.activeEnergyBurned, unit: .kilocalorie(), window: window) }
    async let history = outcome(generation: current) { try await self.readWorkouts(predicate: HKQuery.predicateForSamples(
      withStart: window.start, end: window.end, options: .strictStartDate)) }
    let results = await (steps, distance, energy, history)
    guard generation == current, !Task.isCancelled else { return }

    let stepValues = values(results.0, metric: .steps)
    let distanceValues = values(results.1, metric: .distance)
    let energyValues = values(results.2, metric: .energy)
    dailyMetrics = window.days.map { date in
      HealthDailyMetrics(date: date, steps: stepValues[date], distanceMeters: distanceValues[date],
        activeEnergyKilocalories: energyValues[date])
    }
    switch results.3 {
    case .success(let samples):
      workouts = samples.map(Self.summary)
      workoutState = samples.isEmpty ? .noReadableData : .readable
    case .failure(let error): workoutState = .failed(Self.message(error))
    }
    lastRefresh = Date()
    let failures = metricStates.values.contains { if case .failed = $0 { return true }; return false }
    let workoutFailed: Bool
    if case .failed = workoutState { workoutFailed = true } else { workoutFailed = false }
    if failures || workoutFailed {
      notice = "일부 건강 데이터를 조회하지 못했습니다. 기기 잠금을 해제하고 다시 시도해 주세요. 표시된 값은 이번 조회에서 읽은 항목만 포함합니다."
    }
  }

  func detail(id: UUID) async throws -> HealthWorkoutDetail {
    guard available, readRequested else { throw HealthLibraryError.unreadableWorkout }
    let current = generation
    let samples = try await readWorkouts(predicate: HKQuery.predicateForObject(with: id))
    guard generation == current else { throw CancellationError() }
    guard let sample = samples.first else { throw HealthLibraryError.unreadableWorkout }
    var heartRate = HealthHeartRate(average: nil, minimum: nil, maximum: nil)
    var heartNotice: String?
    do { heartRate = try await readHeartRate(workout: sample) }
    catch is CancellationError { throw CancellationError() }
    catch { heartNotice = Self.message(error) }
    try Task.checkCancellation()
    guard generation == current else { throw CancellationError() }
    return HealthWorkoutDetail(workout: Self.summary(sample), heartRate: heartRate, heartRateNotice: heartNotice)
  }

  func save(workout: PersonalWorkout) async throws -> UUID {
    guard available else { throw HealthLibraryError.unavailable }
    guard workout.origin != .healthLink else { throw HealthLibraryError.importedWorkout }
    // A Watch workout already carries its Health UUID; never create another copy.
    if let existing = workout.healthWorkoutID { return existing }
    guard workout.origin != .watch else { throw HealthLibraryError.watchExportPending }
    let timeline = try HealthExportTimeline.validate(workout)
    guard exporting.insert(workout.id).inserted else { throw HealthLibraryError.saveInProgress }
    defer { exporting.remove(workout.id) }
    try Task.checkCancellation()
    // Write permission is requested only in this explicit export action, for workouts only.
    try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
    guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
      throw HealthLibraryError.writeDenied
    }
    let identity = HealthExportIdentity(localID: workout.id)
    if let existing = try await exportedWorkout(identity: identity) {
      guard HealthExportIdentity.matches(Self.summary(existing), workout: workout) else {
        throw HealthLibraryError.previouslyExportedDifferentRecord
      }
      return existing.uuid
    }
    // A retry may reconcile a sample stored before the clock changed. Only a new
    // Health write is subject to the current future-date limit.
    try workout.validateNewTiming()
    try Task.checkCancellation()
    // Keep both export paths on the same stable identity so an uncertain retry
    // cannot create another copy after the first save loses its callback.
    let metadata: [String: Any] = [
      HKMetadataKeyWasUserEntered: true,
      HKMetadataKeySyncIdentifier: identity.syncIdentifier,
      HKMetadataKeySyncVersion: HealthExportIdentity.syncVersion,
      Self.titleKey: workout.title
    ]
    switch timeline {
    case .manualDuration:
      // The deprecated initializer can preserve an explicitly corrected aggregate
      // duration without inventing pause timestamps or sensor measurements.
      let sample = HKWorkout(activityType: workout.kind.healthActivityType,
        start: workout.startedAt, end: workout.endedAt, duration: workout.duration,
        totalEnergyBurned: nil, totalDistance: nil, metadata: metadata)
      try await store.save(sample)
    case .recordedTimeline:
      let configuration = HKWorkoutConfiguration()
      configuration.activityType = workout.kind.healthActivityType
      // A manual builder has no live sensor data source and adds no quantity samples.
      let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: nil)
      do {
        try await builder.beginCollection(withStart: workout.startedAt)
        try await builder.addMetadata(metadata)
        let events = workout.pauses.filter { $0.endedAt > $0.startedAt }.flatMap { pause in
          [HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pause.startedAt, duration: 0), metadata: nil),
           HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: pause.endedAt, duration: 0), metadata: nil)]
        }
        if !events.isEmpty { try await builder.addWorkoutEvents(events) }
        try await builder.endCollection(withEnd: workout.endedAt)
        try Task.checkCancellation()
        _ = try await builder.finishWorkout()
      } catch {
        builder.discardWorkout()
        throw error
      }
    }
    guard let saved = try await exportedWorkout(identity: identity) else {
      throw HealthLibraryError.saveUnconfirmed
    }
    guard HealthExportIdentity.matches(Self.summary(saved), workout: workout) else {
      throw HealthLibraryError.previouslyExportedDifferentRecord
    }
    return saved.uuid
  }

  private func exportedWorkout(identity: HealthExportIdentity) async throws -> HKWorkout? {
    let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
        allowedValues: [identity.syncIdentifier]),
      HKQuery.predicateForObjects(from: HKSource.default())
    ])
    return try await readWorkouts(predicate: predicate, cancellableRead: false).first
  }

  private func values(_ result: Result<[Date: Double], Error>, metric: HealthMetric) -> [Date: Double] {
    switch result {
    case .success(let values):
      metricStates[metric] = values.isEmpty ? .noReadableData : .readable
      return values
    case .failure(let error): metricStates[metric] = .failed(Self.message(error)); return [:]
    }
  }

  private func outcome<T>(generation current: UUID, _ body: () async throws -> T) async -> Result<T, Error> {
    do {
      guard generation == current else { throw CancellationError() }
      return .success(try await body())
    } catch { return .failure(error) }
  }

  private func readDaily(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
    window: HealthDateWindow) async throws -> [Date: Double] {
    try await execute { finish in
      var interval = DateComponents(day: 1)
      interval.calendar = window.calendar
      interval.timeZone = window.calendar.timeZone
      let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end)
      let query = HKStatisticsCollectionQuery(quantityType: HKQuantityType(identifier),
        quantitySamplePredicate: predicate, options: .cumulativeSum,
        anchorDate: window.start, intervalComponents: interval)
      query.initialResultsHandler = { _, collection, error in
        if let error { finish(.failure(error)); return }
        var result: [Date: Double] = [:]
        collection?.enumerateStatistics(from: window.start, to: window.end) { statistics, _ in
          if let value = HealthValues.nonnegative(statistics.sumQuantity()?.doubleValue(for: unit)) {
            result[window.calendar.startOfDay(for: statistics.startDate)] = value
          }
        }
        finish(.success(result))
      }
      return query
    }
  }

  private func readWorkouts(predicate: NSPredicate, cancellableRead: Bool = true) async throws -> [HKWorkout] {
    try await execute(cancellableRead: cancellableRead) { finish in
      HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
        if let error { finish(.failure(error)) }
        else { finish(.success(samples as? [HKWorkout] ?? [])) }
      }
    }
  }

  private func readHeartRate(workout: HKWorkout) async throws -> HealthHeartRate {
    try await execute { finish in
      HKStatisticsQuery(quantityType: HKQuantityType(.heartRate),
        quantitySamplePredicate: HKQuery.predicateForObjects(from: workout),
        options: [.discreteAverage, .discreteMin, .discreteMax]) { _, statistics, error in
        if let error { finish(.failure(error)); return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        finish(.success(HealthHeartRate(
          average: HealthValues.nonnegative(statistics?.averageQuantity()?.doubleValue(for: unit)),
          minimum: HealthValues.nonnegative(statistics?.minimumQuantity()?.doubleValue(for: unit)),
          maximum: HealthValues.nonnegative(statistics?.maximumQuantity()?.doubleValue(for: unit)))))
      }
    }
  }

  private func execute<T>(cancellableRead: Bool = true,
    makeQuery: (@escaping (Result<T, Error>) -> Void) -> HKQuery) async throws -> T {
    try Task.checkCancellation()
    let operation = HealthQueryOperation<T>()
    let id = UUID()
    let healthStore = store
    if cancellableRead {
      cancelReads[id] = {
        if let query = operation.query { healthStore.stop(query) }
        operation.finish(.failure(CancellationError()))
      }
    }
    defer {
      if let query = operation.query { store.stop(query) }
      operation.query = nil
      cancelReads[id] = nil
    }
    let value: T = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        operation.continuation = continuation
        let query = makeQuery { result in
          Task { @MainActor in operation.finish(result) }
        }
        operation.query = query
        if Task.isCancelled { operation.finish(.failure(CancellationError())) }
        else { store.execute(query) }
      }
    } onCancel: {
      Task { @MainActor in
        if let query = operation.query { healthStore.stop(query) }
        operation.finish(.failure(CancellationError()))
      }
    }
    try Task.checkCancellation()
    return value
  }

  private static func summary(_ workout: HKWorkout) -> HealthWorkoutSummary {
    let kind = WorkoutKind(healthActivityType: workout.workoutActivityType)
    let storedTitle = workout.metadata?[titleKey] as? String
    let title = storedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? workout.workoutActivityType.displayTitle
    return HealthWorkoutSummary(id: workout.uuid, kind: kind, title: title,
      startedAt: workout.startDate, endedAt: workout.endDate,
      sourceName: workout.sourceRevision.source.name, duration: workout.duration,
      distanceMeters: HealthValues.nonnegative(workout.totalDistance?.doubleValue(for: .meter())),
      activeEnergyKilocalories: HealthValues.nonnegative(workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
        .sumQuantity()?.doubleValue(for: .kilocalorie()) ?? workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())),
      manuallyEntered: (workout.metadata?[HKMetadataKeyWasUserEntered] as? Bool) == true,
      pauses: pauses(in: workout),
      exportedLocalID: HealthExportIdentity.localID(
        syncIdentifier: workout.metadata?[HKMetadataKeySyncIdentifier] as? String,
        isCurrentApp: workout.sourceRevision.source == HKSource.default()))
  }

  private static func pauses(in workout: HKWorkout) -> [WorkoutPause] {
    var start: Date?
    var result: [WorkoutPause] = []
    for event in workout.workoutEvents ?? [] {
      if event.type == .pause { start = event.dateInterval.start }
      if event.type == .resume, let began = start {
        let ended = event.dateInterval.start
        if ended > began { result.append(WorkoutPause(startedAt: began, endedAt: ended)) }
        start = nil
      }
    }
    if let start, workout.endDate > start {
      result.append(WorkoutPause(startedAt: start, endedAt: workout.endDate))
    }
    return result
  }

  private static func message(_ error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == HKErrorDomain && nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue {
      return "기기가 잠겨 건강 데이터를 읽을 수 없습니다. 잠금을 해제한 뒤 다시 시도해 주세요."
    }
    return "조회하지 못했습니다. \(error.localizedDescription)"
  }
}

@MainActor private final class HealthQueryOperation<Value> {
  var query: HKQuery?
  var continuation: CheckedContinuation<Value, Error>?
  func finish(_ result: Result<Value, Error>) {
    let pending = continuation
    continuation = nil
    pending?.resume(with: result)
  }
}

extension WorkoutKind {
  var healthActivityType: HKWorkoutActivityType {
    switch self {
    case .walking: return .walking
    case .running: return .running
    case .strength: return .traditionalStrengthTraining
    case .cycling: return .cycling
    case .flexibility: return .flexibility
    case .other: return .other
    }
  }

  init(healthActivityType: HKWorkoutActivityType) {
    switch healthActivityType {
    case .walking, .hiking: self = .walking
    case .running: self = .running
    case .traditionalStrengthTraining, .functionalStrengthTraining: self = .strength
    case .cycling: self = .cycling
    case .flexibility, .yoga, .pilates: self = .flexibility
    default: self = .other
    }
  }
}

private extension HKWorkoutActivityType {
  var displayTitle: String {
    switch self {
    case .hiking: return "하이킹"
    case .yoga: return "요가"
    case .pilates: return "필라테스"
    case .swimming: return "수영"
    case .highIntensityIntervalTraining: return "고강도 인터벌 운동"
    case .dance, .cardioDance, .socialDance: return "댄스"
    case .elliptical: return "일립티컬"
    case .rowing: return "로잉"
    case .stairClimbing, .stairs: return "계단 운동"
    case .mindAndBody: return "심신 운동"
    case .cooldown: return "정리 운동"
    case .mixedCardio: return "혼합 유산소 운동"
    default: return WorkoutKind(healthActivityType: self).title
    }
  }
}
