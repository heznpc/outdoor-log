import Foundation
import Combine
import HealthKit

extension WorkoutKind {
  var watchActivityType: HKWorkoutActivityType {
    switch self {
    case .walking: return .walking
    case .running: return .running
    case .strength: return .traditionalStrengthTraining
    case .cycling: return .cycling
    case .flexibility: return .flexibility
    case .other: return .other
    }
  }
}

@MainActor
final class WatchWorkoutController: NSObject, ObservableObject {
  static let shared = WatchWorkoutController()

  @Published private(set) var state = WatchWorkoutState()
  @Published private(set) var exercises: [ExerciseEntry] = []
  @Published private(set) var history: [PersonalWorkout] = []
  @Published private(set) var pendingCount = 0
  @Published private(set) var isReady = false
  @Published private(set) var isBusy = false
  @Published private(set) var todaySteps: Double?
  @Published private(set) var stepsNotice: String?
  @Published private(set) var notice: String?

  private let healthStore = HKHealthStore()
  private let connection = WatchPhoneConnection()
  private var archive: WatchArchive?
  private var session: HKWorkoutSession?
  private var builder: HKLiveWorkoutBuilder?
  private var timer: Timer?
  private var tickCount = 0
  private var bootstrapping = false
  private var journal: WatchJournal?
  private var pendingCompletion: PersonalWorkout?
  private var transition: (HKWorkoutSessionState, CheckedContinuation<Void, Error>)?
  private var transitionTimeout: Task<Void, Never>?
  private var retryBuilder: HKLiveWorkoutBuilder?
  private var retryWorkoutID: UUID?
  private var retryStage: WatchSaveStage?
  private var collectionBegan = false
  private var finishInProgress = false

  private override init() {
    super.init()
    connection.onCommand = { [weak self] command in
      guard let self else {
        return WatchCommandReply(commandID: command.id, accepted: false, state: WatchWorkoutState(), message: "앱을 다시 열어 주세요.")
      }
      return await self.handle(command)
    }
    connection.onAcknowledgement = { [weak self] packet in
      guard let self else { return }
      do {
        try self.archive?.acknowledge(packet)
        self.refreshArchive()
        if packet.acknowledgedWorkoutID == self.state.sessionID, self.state.phase == .finished,
          self.archive?.pending.contains(where: { $0.id == self.state.sessionID }) == false {
          self.state.message = "Watch와 iPhone 기록 저장 완료"
          self.publish()
        }
      }
      catch { self.notice = error.localizedDescription }
    }
    connection.onReady = { [weak self] in self?.retryTransfer() }
    connection.onError = { [weak self] message in self?.notice = message }
  }

  func activate() async {
    guard !bootstrapping else { return }
    if isReady {
      connection.activate()
      retryTransfer()
      await refreshSteps()
      return
    }
    bootstrapping = true
    defer { bootstrapping = false }
    do {
      archive = try WatchArchive()
      journal = archive?.journal
      refreshArchive()
      connection.activate()
      if journal != nil { await recoverSession() }
      isReady = true
      publish()
      retryTransfer()
      await refreshSteps()
    } catch {
      // No replacement file is created if the existing archive is corrupt or locked.
      notice = error.localizedDescription
      isReady = false
    }
  }

  func recoverFromSystem() async {
    if !isReady { await activate(); return }
    guard session == nil, journal != nil else { return }
    await recoverSession()
  }

  func requestPermissions() async throws {
    guard HKHealthStore.isHealthDataAvailable() else {
      throw WatchWireError.rejected("이 기기에서는 건강 데이터를 사용할 수 없습니다.")
    }
    let share: Set<HKSampleType> = [HKObjectType.workoutType()]
    var read: Set<HKObjectType> = [HKObjectType.workoutType()]
    let identifiers: [HKQuantityTypeIdentifier] = [
      .heartRate, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling, .stepCount
    ]
    for identifier in identifiers {
      if let type = HKObjectType.quantityType(forIdentifier: identifier) { read.insert(type) }
    }
    try await healthStore.requestAuthorization(toShare: share, read: read)
    guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
      throw WatchWireError.rejected("건강 앱에 운동을 저장할 권한이 필요합니다. Watch 설정에서 건강 권한을 확인해 주세요.")
    }
  }

  func requestStepPermissions() async throws {
    guard HKHealthStore.isHealthDataAvailable(),
      let steps = HKObjectType.quantityType(forIdentifier: .stepCount) else {
      throw WatchWireError.rejected("이 기기에서는 걸음 데이터를 사용할 수 없습니다.")
    }
    // Reading steps is independent of permission to create workout samples.
    try await healthStore.requestAuthorization(toShare: [], read: [steps])
  }

  func perform(_ action: WatchCommand.Action, kind: WorkoutKind? = nil) async {
    let command = WatchCommand(action: action, sessionID: action == .start ? UUID() : state.sessionID,
      kind: kind ?? state.kind, placeID: state.placeID, placeName: state.placeName)
    let reply = await handle(command)
    if !reply.accepted { notice = reply.message }
  }

  func handle(_ command: WatchCommand) async -> WatchCommandReply {
    do {
      guard isReady, archive != nil else { throw WatchWireError.rejected("저장소를 준비하지 못했습니다. 안내를 확인하고 다시 열어 주세요.") }
      guard !isBusy, !finishInProgress else { throw WatchWireError.busy }
      _ = try WatchWire.encode(WatchPacket(kind: .command, command: command))
      try WatchWire.validateCommand(command, state: state)
      isBusy = true
      defer { isBusy = false }
      notice = nil
      switch command.action {
      case .start: try await start(command)
      case .pause:
        guard let session else { throw WatchWireError.wrongSession }
        try await awaitTransition(.paused) { session.pause() }
      case .resume:
        guard let session else { throw WatchWireError.wrongSession }
        try await awaitTransition(.running) { session.resume() }
      case .finish: try await finish()
      }
      return WatchCommandReply(commandID: command.id, accepted: true, state: state, message: state.message)
    } catch {
      notice = error.localizedDescription
      return WatchCommandReply(commandID: command.id, accepted: false, state: state, message: error.localizedDescription)
    }
  }

  private func start(_ command: WatchCommand) async throws {
    guard pendingCompletion == nil, journal == nil else {
      throw WatchWireError.rejected("이전 운동 기록을 먼저 저장해 주세요. ‘저장·전송 재시도’를 눌러 주세요.")
    }
    guard let id = command.sessionID, archive?.history.contains(where: { $0.id == id }) != true else {
      throw WatchWireError.wrongSession
    }
    try await requestPermissions()
    // A permission sheet can outlive the phone command; never start that stale request later.
    try WatchWire.validateCommand(command, state: state)
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = command.kind.watchActivityType
    configuration.locationType = [.walking, .running, .cycling].contains(command.kind) ? .outdoor : .unknown
    let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
    let builder = session.associatedWorkoutBuilder()
    let startedAt = Date()
    let workout = PersonalWorkout(id: id, title: command.kind.title, kind: command.kind,
      startedAt: startedAt, endedAt: startedAt, placeID: command.placeID, placeName: command.placeName,
      healthExportState: .pending, origin: .watch)
    let journal = WatchJournal(workout: workout)
    try archive?.saveJournal(journal)
    self.journal = journal
    self.session = session
    self.builder = builder
    retryBuilder = nil
    retryWorkoutID = nil
    retryStage = nil
    collectionBegan = false
    configure(session: session, builder: builder)
    state = WatchWorkoutState(sessionID: id, phase: .saving, kind: command.kind,
      startedAt: startedAt, placeID: command.placeID, placeName: command.placeName, message: "운동 센서 준비 중")
    exercises = []
    publish()
    do {
      try await addMetadata(builder, workoutID: id)
      session.startActivity(with: startedAt)
      try await beginCollection(builder, at: startedAt)
      collectionBegan = true
      guard session.state == .running || session.state == .paused else {
        throw WatchWireError.rejected("Watch 운동 세션이 시작되지 않았습니다.")
      }
      state.phase = session.state == .paused ? .paused : .running
      state.message = nil
      startTimer()
      publish()
    } catch {
      session.end()
      builder.discardWorkout()
      var failed = workout
      failed.endedAt = Date()
      failed.healthExportState = .failed
      failed.healthExportMessage = "운동 시작 실패: \(error.localizedDescription)"
      try storeCompletion(failed)
      throw error
    }
  }

  private func configure(session: HKWorkoutSession, builder: HKLiveWorkoutBuilder) {
    session.delegate = self
    builder.delegate = self
    builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
      workoutConfiguration: session.workoutConfiguration)
  }

  private func finish() async throws {
    guard let session, let builder, var journal, collectionBegan else { throw WatchWireError.wrongSession }
    finishInProgress = true
    defer { finishInProgress = false }
    journal.workout.endedAt = Date()
    journal.workout.exercises = exercises
    journal.workout.modifiedAt = Date()
    journal.elapsedSeconds = builder.elapsedTime
    journal.workout.activeDurationSeconds = min(builder.elapsedTime,
      journal.workout.endedAt.timeIntervalSince(journal.workout.startedAt))
    journal.stage = .ending
    // If storage is unavailable, leave the workout running and let the person retry.
    try archive?.saveJournal(journal)
    self.journal = journal
    // Once stopping has been requested, a failed local write must not keep the session alive.
    // This defer is deliberately registered after the pre-stop durable journal write.
    defer { session.end() }
    state.phase = .saving
    state.message = "Watch 기록과 건강 앱에 저장 중"
    publish()
    do {
      try await awaitTransition(.stopped) { session.stopActivity(with: journal.workout.endedAt) }
      try await endCollection(builder, at: journal.workout.endedAt)
      journal.stage = .collectionEnded
      rememberRetry(builder, journal: journal)
      try archive?.saveJournal(journal)
      try await saveHealthWorkout(builder, journal: journal)
    } catch {
      // saveHealthWorkout already committed a precise result if HealthKit completed.
      if let latest = self.journal, pendingCompletion == nil {
        rememberRetry(builder, journal: latest)
        var failed = latest.workout
        failed.healthExportState = .failed
        failed.healthExportMessage = "건강 앱 저장을 완료하지 못했습니다: \(error.localizedDescription)"
        try storeCompletion(failed)
      }
      throw error
    }
  }

  private func saveHealthWorkout(_ builder: HKLiveWorkoutBuilder, journal initial: WatchJournal) async throws {
    var journal = initial
    journal.stage = .saveRequested
    try archive?.saveJournal(journal)
    self.journal = journal
    var completed = journal.workout
    if completed.notes.isEmpty { completed.notes = summaryNotes() }
    do {
      let healthWorkout = try await finishBuilder(builder)
      if let healthWorkout {
        completed = applyingSavedWorkout(healthWorkout, to: completed)
        retryBuilder = nil
        retryStage = nil
      } else {
        // Apple documents nil/nil as a successful save while locked. Repeating finish would duplicate it.
        completed.healthExportState = .failed
        completed.healthExportMessage = "건강 앱 저장 응답은 받았지만 잠금 때문에 기록 ID를 확인하지 못했습니다. 잠금을 풀고 저장 상태를 확인해 주세요."
        retryBuilder = nil
        retryStage = .saveRequested
      }
    } catch {
      completed.healthExportState = .failed
      completed.healthExportMessage = "건강 앱 저장 실패: \(error.localizedDescription)"
      journal.stage = .saveRejected
      // Only a definite error permits retrying this same builder; ambiguous/crash outcomes are lookup-only.
      rememberRetry(builder, journal: journal)
      try archive?.saveJournal(journal)
    }
    completed.modifiedAt = Date()
    try storeCompletion(completed)
    if completed.healthExportState != .saved {
      throw WatchWireError.rejected(completed.healthExportMessage ?? "건강 앱 저장 확인이 필요합니다.")
    }
  }

  private func storeCompletion(_ workout: PersonalWorkout) throws {
    pendingCompletion = workout
    do {
      guard let archive else { throw LocalDataError.storageUnavailable }
      try archive.complete(workout)
      pendingCompletion = nil
      journal = nil
      timer?.invalidate()
      timer = nil
      state.sessionID = workout.id
      state.kind = workout.kind
      state.startedAt = workout.startedAt
      state.elapsedSeconds = workout.duration
      state.heartRate = nil
      state.activeEnergyKilocalories = nil
      state.distanceMeters = nil
      state.placeID = workout.placeID
      state.placeName = workout.placeName
      state.phase = workout.healthExportState == .saved ? .finished : .failed
      state.message = workout.healthExportState == .saved ? "Watch 저장 완료 · iPhone 전송 확인 대기" : workout.healthExportMessage
      refreshArchive()
      publish()
      retryTransfer()
    } catch {
      state.phase = .failed
      state.message = "기기에 저장하지 못했습니다. 앱을 닫기 전에 ‘저장·전송 재시도’를 눌러 주세요."
      notice = error.localizedDescription
      publish()
      throw error
    }
  }

  func addSet(name: String, repetitions: Int, weight: Double?) throws {
    guard [.running, .paused].contains(state.phase), !isBusy, var journal else { throw WatchWireError.busy }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 80, (0...1000).contains(repetitions),
      weight.map({ $0.isFinite && (0...2000).contains($0) }) ?? true else { throw LocalDataError.invalidRecord }
    var next = exercises
    let set = ExerciseSet(repetitions: repetitions, weightKilograms: weight)
    if let index = next.firstIndex(where: { $0.name == name }) {
      guard next[index].sets.count < 20 else { throw WatchWireError.rejected("한 동작에는 최대 20세트를 기록할 수 있습니다.") }
      next[index].sets.append(set)
    } else {
      guard next.count < 15 else { throw WatchWireError.rejected("한 운동에는 최대 15개 동작을 기록할 수 있습니다.") }
      next.append(ExerciseEntry(name: name, sets: [set]))
    }
    journal.workout.exercises = next
    journal.workout.endedAt = Date()
    journal.workout.modifiedAt = Date()
    try archive?.saveJournal(journal)
    self.journal = journal
    exercises = next
  }

  func retrySaveAndTransfer() async {
    guard !isBusy, !finishInProgress else { return }
    isBusy = true
    let sessionToEnd = session
    let shouldEndSession = pendingCompletion != nil || session?.state == .stopped
      || (journal.map { $0.stage != .recording } ?? false)
    if shouldEndSession { finishInProgress = true }
    defer {
      if shouldEndSession { sessionToEnd?.end(); finishInProgress = false }
      isBusy = false
    }
    do {
      if let pendingCompletion { try storeCompletion(pendingCompletion) }
      if let journal, session == nil || session?.state == .stopped || session?.state == .ended {
        if let builder { rememberRetry(builder, journal: journal) }
        var failed = journal.workout
        failed.healthExportState = .failed
        failed.healthExportMessage = "중단된 저장 결과를 확인해야 합니다. 기록의 ‘건강 저장 재시도·확인’을 눌러 주세요."
        try storeCompletion(failed)
      }
      retryTransfer()
    } catch { notice = error.localizedDescription }
  }

  func retryHealthSave(_ workout: PersonalWorkout) async {
    guard !isBusy, ![.running, .paused, .saving].contains(state.phase), pendingCompletion == nil else { return }
    isBusy = true
    finishInProgress = true
    defer { isBusy = false; finishInProgress = false }
    do {
      try await requestPermissions()
      if let existing = try await findSavedWorkout(id: workout.id) {
        var updated = applyingSavedWorkout(existing, to: workout)
        updated.modifiedAt = Date()
        try storeCompletion(updated)
        return
      }
      if retryWorkoutID == workout.id, let builder = retryBuilder,
        retryStage == .saveRejected || retryStage == .collectionEnded || retryStage == .ending {
        var retry = WatchJournal(workout: workout, stage: retryStage ?? .ending)
        if retry.stage == .ending {
          try await endCollection(builder, at: workout.endedAt)
          retry.stage = .collectionEnded
        }
        rememberRetry(builder, journal: retry)
        try await saveHealthWorkout(builder, journal: retry)
      } else {
        notice = "건강 기록을 찾지 못했거나 읽기 권한이 없습니다. 저장 여부가 불확실해 새 건강 기록은 만들지 않았습니다. Watch의 운동·세트 기록은 보관되어 있습니다."
      }
    } catch { notice = error.localizedDescription }
  }

  func retryTransfer() {
    guard let archive else { return }
    connection.transfer(archive.pending)
    refreshArchive()
  }

  private func refreshArchive() {
    history = archive?.history ?? []
    pendingCount = archive?.pending.count ?? 0
  }

  private func rememberRetry(_ builder: HKLiveWorkoutBuilder, journal: WatchJournal) {
    var recovered = journal
    if recovered.stage == .recording || recovered.stage == .ending {
      recovered.stage = builder.endDate == nil ? .ending : .collectionEnded
    }
    // HealthKit has already advanced, even if the next protected-file write fails.
    self.journal = recovered
    retryBuilder = builder
    retryWorkoutID = recovered.workout.id
    retryStage = recovered.stage
  }

  private func applyingSavedWorkout(_ saved: HKWorkout, to original: PersonalWorkout) -> PersonalWorkout {
    var updated = original
    updated.healthWorkoutID = saved.uuid
    updated.startedAt = saved.startDate
    updated.endedAt = saved.endDate
    updated.activeDurationSeconds = saved.duration
    // Preserve only complete known pause intervals inside the authoritative recovered interval.
    // Do not invent clipped pause boundaries from an interrupted local snapshot.
    updated.pauses = original.pauses.filter {
      $0.startedAt >= saved.startDate && $0.endedAt <= saved.endDate && $0.endedAt >= $0.startedAt
    }
    updated.healthExportState = .saved
    updated.healthExportMessage = nil
    return updated
  }

  private func recoverSession() async {
    guard let journal else { return }
    do {
      let recovered: HKWorkoutSession? = try await withCheckedThrowingContinuation { continuation in
        healthStore.recoverActiveWorkoutSession { session, error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume(returning: session) }
        }
      }
      if let recovered, [.running, .paused].contains(recovered.state), journal.stage == .recording {
        session = recovered
        builder = recovered.associatedWorkoutBuilder()
        guard let builder else { throw WatchWireError.unavailable }
        configure(session: recovered, builder: builder)
        collectionBegan = true
        exercises = journal.workout.exercises
        state = WatchWorkoutState(sessionID: journal.workout.id,
          phase: recovered.state == .paused ? .paused : .running, kind: journal.workout.kind,
          startedAt: journal.workout.startedAt, elapsedSeconds: builder.elapsedTime,
          placeID: journal.workout.placeID, placeName: journal.workout.placeName,
          message: "진행 중이던 운동을 복구했습니다.")
        startTimer()
        publish()
        return
      }
      // A stopped session can still provide its original builder for collection/save recovery.
      if let recovered, [.stopped, .ended].contains(recovered.state),
        journal.stage == .ending || journal.stage == .collectionEnded || journal.stage == .saveRejected {
        rememberRetry(recovered.associatedWorkoutBuilder(), journal: journal)
      }
      recovered?.end()
      try await preserveInterrupted(journal)
    } catch {
      // The journal is preserved if a protected file or HealthKit lookup cannot be read.
      notice = "운동 복구를 완료하지 못했습니다: \(error.localizedDescription)"
      do { try await preserveInterrupted(journal) }
      catch { notice = error.localizedDescription }
    }
  }

  private func preserveInterrupted(_ journal: WatchJournal) async throws {
    var workout = journal.workout
    let saved = try? await findSavedWorkout(id: workout.id)
    // The original journal can only be cleared by this session's completion.
    guard self.journal?.workout.id == workout.id else { return }
    if let saved {
      workout = applyingSavedWorkout(saved, to: workout)
    } else {
      workout.healthExportState = .failed
      workout.activeDurationSeconds = min(journal.elapsedSeconds,
        workout.endedAt.timeIntervalSince(workout.startedAt))
      workout.healthExportMessage = "운동이 중단되었습니다. 마지막으로 기기에 저장한 기록을 복구했으며 건강 앱 저장 완료는 확인되지 않았습니다."
    }
    workout.modifiedAt = Date()
    state.elapsedSeconds = journal.elapsedSeconds
    exercises = workout.exercises
    try storeCompletion(workout)
  }

  private func startTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }

  private func tick() {
    guard [.running, .paused].contains(state.phase), let builder else { return }
    state.elapsedSeconds = max(0, builder.elapsedTime)
    tickCount += 1
    if tickCount % 5 == 0 { publish() }
    if tickCount % 15 == 0, var journal, journal.stage == .recording {
      journal.workout.endedAt = Date()
      journal.elapsedSeconds = state.elapsedSeconds
      journal.workout.activeDurationSeconds = min(state.elapsedSeconds,
        journal.workout.endedAt.timeIntervalSince(journal.workout.startedAt))
      do { try archive?.saveJournal(journal); self.journal = journal }
      catch { notice = "운동 중간 저장 실패: \(error.localizedDescription)" }
    }
    if tickCount % 30 == 0 { retryTransfer() }
  }

  private func publish() {
    state.updatedAt = max(Date(), state.updatedAt.addingTimeInterval(0.001))
    if let message = state.message { state.message = String(message.prefix(2000)) }
    connection.publish(state)
  }

  private func summaryNotes() -> String {
    var parts = ["Watch 측정 운동 시간: \(Int(state.elapsedSeconds))초"]
    if let energy = state.activeEnergyKilocalories { parts.append("활동 에너지: \(Int(energy)) kcal") }
    if let distance = state.distanceMeters { parts.append("거리: \(Int(distance)) m") }
    return parts.joined(separator: "\n")
  }

  private func awaitTransition(_ target: HKWorkoutSessionState, action: () -> Void) async throws {
    guard transition == nil else { throw WatchWireError.busy }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      transition = (target, continuation)
      transitionTimeout = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        guard !Task.isCancelled else { return }
        self?.resolveTransition(.failure(WatchWireError.rejected("Watch 운동 상태 변경 응답이 늦습니다. 현재 상태를 확인해 주세요.")))
      }
      action()
    }
  }

  private func resolveTransition(_ result: Result<Void, Error>) {
    transitionTimeout?.cancel()
    transitionTimeout = nil
    let continuation = transition?.1
    transition = nil
    continuation?.resume(with: result)
  }

  private func beginCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      builder.beginCollection(withStart: date) { success, error in
        if success { continuation.resume() }
        else { continuation.resume(throwing: error ?? WatchWireError.rejected("운동 측정을 시작하지 못했습니다.")) }
      }
    }
  }

  private func endCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
    // endDate survives a successful HealthKit end even if our following journal write did not.
    guard builder.endDate == nil else { return }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      builder.endCollection(withEnd: date) { success, error in
        if success { continuation.resume() }
        else { continuation.resume(throwing: error ?? WatchWireError.rejected("운동 측정을 종료하지 못했습니다.")) }
      }
    }
  }

  private func addMetadata(_ builder: HKLiveWorkoutBuilder, workoutID: UUID) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      builder.addMetadata([
        HKMetadataKeyExternalUUID: workoutID.uuidString,
        HKMetadataKeySyncIdentifier: "outdoorlog.watch.\(workoutID.uuidString)",
        HKMetadataKeySyncVersion: NSNumber(value: 1)
      ]) { success, error in
        if success { continuation.resume() }
        else { continuation.resume(throwing: error ?? WatchWireError.rejected("운동 복구 정보를 저장하지 못했습니다.")) }
      }
    }
  }

  private func finishBuilder(_ builder: HKLiveWorkoutBuilder) async throws -> HKWorkout? {
    try await withCheckedThrowingContinuation { continuation in
      builder.finishWorkout { workout, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: workout) }
      }
    }
  }

  private func findSavedWorkout(id: UUID) async throws -> HKWorkout? {
    try await withCheckedThrowingContinuation { continuation in
      let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
        allowedValues: [id.uuidString])
      let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: samples?.first as? HKWorkout) }
      }
      healthStore.execute(query)
    }
  }

  func refreshSteps() async {
    guard HKHealthStore.isHealthDataAvailable(), let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return }
    do {
      let steps: Double? = try await withCheckedThrowingContinuation { continuation in
        let start = Calendar.current.startOfDay(for: Date())
        let query = HKStatisticsQuery(quantityType: type,
          quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate),
          options: .cumulativeSum) { _, result, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: .count())) }
          }
        healthStore.execute(query)
      }
      todaySteps = steps
      stepsNotice = steps == nil ? "읽을 수 있는 걸음 데이터가 없습니다. 권한 또는 Watch 동기화 상태를 확인해 주세요." : nil
    } catch {
      todaySteps = nil
      stepsNotice = error.localizedDescription
    }
  }

  private func sessionChanged(_ changedSession: HKWorkoutSession, to newState: HKWorkoutSessionState) {
    guard changedSession === session else { return }
    if transition?.0 == newState { resolveTransition(.success(())) }
    switch newState {
    case .running:
      if !finishInProgress, journal?.stage == .recording, pendingCompletion == nil { state.phase = .running }
    case .paused:
      if !finishInProgress, journal?.stage == .recording, pendingCompletion == nil { state.phase = .paused }
    case .stopped:
      if !finishInProgress, journal != nil {
        notice = "운동이 정지되었습니다. ‘저장·전송 재시도’로 기록을 보관해 주세요."
        state.phase = .failed
      }
    case .ended:
      if !finishInProgress, let journal, pendingCompletion == nil {
        resolveTransition(.failure(WatchWireError.rejected("운동 세션이 종료되었습니다. 저장 상태를 확인해 주세요.")))
        state.phase = .failed
        if !isBusy {
          Task {
            do { try await self.preserveInterrupted(journal) }
            catch { self.notice = error.localizedDescription }
          }
        }
      }
    default: break
    }
    publish()
  }

  private func sessionFailed(_ failedSession: HKWorkoutSession, error: Error) {
    guard failedSession === session else { return }
    resolveTransition(.failure(error))
    notice = error.localizedDescription
    guard !finishInProgress, let journal else { return }
    state.phase = .failed
    Task {
      do { try await preserveInterrupted(journal) }
      catch { notice = error.localizedDescription }
    }
  }

  private func collected(_ builder: HKLiveWorkoutBuilder, types: Set<HKSampleType>) {
    guard builder === self.builder, [.running, .paused, .saving].contains(state.phase) else { return }
    for type in types {
      guard let quantityType = type as? HKQuantityType, let statistics = builder.statistics(for: quantityType) else { continue }
      switch quantityType.identifier {
      case HKQuantityTypeIdentifier.heartRate.rawValue:
        state.heartRate = statistics.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
      case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
        state.activeEnergyKilocalories = statistics.sumQuantity()?.doubleValue(for: .kilocalorie())
      case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue, HKQuantityTypeIdentifier.distanceCycling.rawValue:
        state.distanceMeters = statistics.sumQuantity()?.doubleValue(for: .meter())
      default: break
      }
    }
    state.elapsedSeconds = max(0, builder.elapsedTime)
    publish()
  }
}

extension WatchWorkoutController: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
    from fromState: HKWorkoutSessionState, date: Date) {
    Task { @MainActor in self.sessionChanged(workoutSession, to: toState) }
  }

  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
    Task { @MainActor in self.sessionFailed(workoutSession, error: error) }
  }

  nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
    Task { @MainActor in self.collected(workoutBuilder, types: collectedTypes) }
  }

  nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
