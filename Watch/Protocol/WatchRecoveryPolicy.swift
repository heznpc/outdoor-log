import Foundation

enum WatchSaveStage: String, Codable {
  case recording, ending, collectionEnded, saveRequested, saveRejected
}

struct WatchJournal: Codable {
  var workout: PersonalWorkout
  var stage: WatchSaveStage = .recording
  var elapsedSeconds: Double = 0
  // Kept separately until resume/finish, so a relaunch never invents a resume time.
  var pauseStartedAt: Date?

  func validate() throws {
    try workout.validateInProgress()
    guard workout.origin == .watch, elapsedSeconds.isFinite, elapsedSeconds >= 0,
      elapsedSeconds <= workout.endedAt.timeIntervalSince(workout.startedAt) + 1,
      pauseStartedAt.map({
        $0.timeIntervalSinceReferenceDate.isFinite && $0 >= workout.startedAt && $0 <= workout.endedAt
          && $0 >= (workout.pauses.last?.endedAt ?? workout.startedAt)
      }) ?? true else { throw LocalDataError.invalidRecord }
  }

  mutating func captureTiming(at date: Date, elapsedSeconds: TimeInterval, ending: Bool = false) {
    // The first stop fixes the workout boundary. Event delivery, retries and
    // relaunches may improve its contents, but cannot extend that boundary.
    if stage == .recording {
      workout.endedAt = max(workout.startedAt, ending ? date : max(workout.endedAt, date))
      if ending { stage = .ending }
    }
    self.elapsedSeconds = min(max(0, elapsedSeconds), workout.endedAt.timeIntervalSince(workout.startedAt))
    workout.activeDurationSeconds = self.elapsedSeconds
  }

  mutating func capturePauses(_ events: [WatchPauseEvent], through date: Date, ending: Bool = false) {
    let previous = workout.pauses.flatMap {
      [WatchPauseEvent(date: $0.startedAt, paused: true), WatchPauseEvent(date: $0.endedAt, paused: false)]
    } + (pauseStartedAt.map { [WatchPauseEvent(date: $0, paused: true)] } ?? [])
    let timeline = WatchPauseTimeline(events: previous + events, startedAt: workout.startedAt, through: date)
    workout.pauses = timeline.pauses
    pauseStartedAt = timeline.pauseStartedAt
    if ending, let start = pauseStartedAt {
      workout.pauses.append(WorkoutPause(startedAt: start, endedAt: date))
      pauseStartedAt = nil
    }
  }
}

struct WatchPauseEvent: Hashable {
  var date: Date
  var paused: Bool
}

/// Uses HealthKit event times, including events delivered after suspension or recovery.
struct WatchPauseTimeline {
  private(set) var pauses: [WorkoutPause] = []
  private(set) var pauseStartedAt: Date?

  init(events: [WatchPauseEvent], startedAt: Date, through end: Date) {
    var seen = Set<WatchPauseEvent>()
    let ordered = events.enumerated().filter {
      $0.element.date.timeIntervalSinceReferenceDate.isFinite
        && $0.element.date >= startedAt && $0.element.date <= end && seen.insert($0.element).inserted
    }.sorted {
      $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date
    }
    for (_, event) in ordered {
      if event.paused {
        if pauseStartedAt == nil { pauseStartedAt = event.date }
      } else if let start = pauseStartedAt {
        pauses.append(WorkoutPause(startedAt: start, endedAt: event.date))
        pauseStartedAt = nil
      }
    }
  }
}

struct WatchHealthRetry: Codable, Equatable {
  enum Source: String, Codable { case original, summary }
  var workoutID: UUID
  var stage: WatchSaveStage
  var source: Source = .original
}

/// Kept independently of the live journal and phone outbox, including after acknowledgement.
struct WatchHealthRecoveryState: Codable, Equatable {
  private(set) var attempts: [WatchHealthRetry] = []

  func attempt(for id: UUID) -> WatchHealthRetry? { attempts.first { $0.workoutID == id } }

  mutating func remember(_ attempt: WatchHealthRetry) {
    attempts.removeAll { $0.workoutID == attempt.workoutID }
    attempts.append(attempt)
  }

  mutating func complete(_ workout: PersonalWorkout, journal: WatchJournal?) {
    if workout.healthExportState == .saved {
      attempts.removeAll { $0.workoutID == workout.id }
    } else if let journal, journal.workout.id == workout.id,
      attempt(for: workout.id)?.source != .summary {
      // Completion can atomically persist a definitive callback after an earlier journal write failed.
      remember(WatchHealthRetry(workoutID: workout.id, stage: journal.stage))
    }
  }
}

enum WatchRecoveryPolicy {
  enum Session { case active, stopped, absent, unavailable }
  enum Action: Equatable { case resume, finish, preserve, retryRecovery }
  enum RetryAction: Equatable { case originalBuilder, summary, lookupOnly }
  enum ActivationAction: Equatable { case persistCompletion, recoverJournal, ready }
  enum SummarySavePlan: Equatable { case events, aggregate, unavailable }

  static func activation(hasPendingCompletion: Bool, hasJournal: Bool) -> ActivationAction {
    // A confirmed Health result in memory is stronger evidence than an older journal or empty query.
    if hasPendingCompletion { return .persistCompletion }
    return hasJournal ? .recoverJournal : .ready
  }

  static func summarySavePlan(for workout: PersonalWorkout) -> SummarySavePlan {
    do { try workout.validate() } catch { return .unavailable }
    let elapsed = workout.endedAt.timeIntervalSince(workout.startedAt)
    let paused = workout.pauses.reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
    // Only the original intervals may explain the active duration. Never fill an unknown gap.
    if !workout.pauses.isEmpty, elapsed - paused == workout.duration { return .events }
    return canSaveSummary(duration: workout.duration) ? .aggregate : .unavailable
  }

  static func recovery(stage: WatchSaveStage, session: Session) -> Action {
    switch session {
    case .unavailable: return .retryRecovery
    case .absent, .stopped: return .preserve
    case .active:
      switch stage {
      case .recording: return .resume
      case .ending, .collectionEnded, .saveRejected: return .finish
      case .saveRequested: return .preserve
      }
    }
  }

  static func retry(_ attempt: WatchHealthRetry?, hasOriginalBuilder: Bool) -> RetryAction {
    guard let attempt, attempt.stage != .saveRequested else { return .lookupOnly }
    if hasOriginalBuilder, attempt.source == .original, attempt.stage != .recording {
      return .originalBuilder
    }
    return .summary
  }

  static func canSaveSummary(duration: TimeInterval) -> Bool {
    // HKWorkout's duration initializer treats zero as the entire start/end interval.
    duration.isFinite && duration > 0
  }

  static func localCommand(_ action: WatchCommand.Action, state: WatchWorkoutState,
    kind: WorkoutKind? = nil) -> WatchCommand {
    WatchCommand(action: action, sessionID: action == .start ? UUID() : state.sessionID,
      kind: kind ?? state.kind, placeID: action == .start ? nil : state.placeID,
      placeName: action == .start ? nil : state.placeName)
  }
}
