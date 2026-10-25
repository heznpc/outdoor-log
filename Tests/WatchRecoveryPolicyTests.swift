import XCTest
@testable import OutdoorLog

final class WatchRecoveryPolicyTests: XCTestCase {
  private func workout() -> PersonalWorkout {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    return PersonalWorkout(title: "Watch 운동", kind: .strength, startedAt: start,
      endedAt: start.addingTimeInterval(900), activeDurationSeconds: 700,
      healthExportState: .failed, origin: .watch)
  }

  func testPendingHealthSuccessMustBePersistedBeforeJournalRecovery() {
    // A local write failure leaves both pieces of state unchanged, so another activation
    // must choose the same completion instead of looking up and weakening its Health result.
    XCTAssertEqual(WatchRecoveryPolicy.activation(hasPendingCompletion: true, hasJournal: true), .persistCompletion)
    XCTAssertEqual(WatchRecoveryPolicy.activation(hasPendingCompletion: true, hasJournal: true), .persistCompletion)
    XCTAssertEqual(WatchRecoveryPolicy.activation(hasPendingCompletion: true, hasJournal: false), .persistCompletion)
    // Only a successful completion commit permits journal recovery or readiness.
    XCTAssertEqual(WatchRecoveryPolicy.activation(hasPendingCompletion: false, hasJournal: true), .recoverJournal)
    XCTAssertEqual(WatchRecoveryPolicy.activation(hasPendingCompletion: false, hasJournal: false), .ready)
  }

  func testSummaryUsesOnlyActualPausesThatExplainActiveDuration() {
    var record = workout()
    let pause = WorkoutPause(startedAt: record.startedAt.addingTimeInterval(100),
      endedAt: record.startedAt.addingTimeInterval(300))
    record.pauses = [pause]
    XCTAssertEqual(WatchRecoveryPolicy.summarySavePlan(for: record), .events)
    XCTAssertEqual(record.pauses, [pause])
    record.activeDurationSeconds = 600
    XCTAssertEqual(WatchRecoveryPolicy.summarySavePlan(for: record), .aggregate)
    XCTAssertEqual(record.pauses, [pause])
    record.pauses = []
    XCTAssertEqual(WatchRecoveryPolicy.summarySavePlan(for: record), .aggregate)
  }

  func testZeroActivityNeedsActualPausesCoveringTheEntireInterval() {
    var record = workout()
    record.activeDurationSeconds = 0
    XCTAssertEqual(WatchRecoveryPolicy.summarySavePlan(for: record), .unavailable)
    record.pauses = [WorkoutPause(startedAt: record.startedAt, endedAt: record.endedAt)]
    XCTAssertEqual(WatchRecoveryPolicy.summarySavePlan(for: record), .events)
    record.pauses[0].endedAt = record.endedAt.addingTimeInterval(-1)
    XCTAssertEqual(WatchRecoveryPolicy.summarySavePlan(for: record), .unavailable)
  }

  func testSummaryPlanRejectsNonfiniteActivityAndInvalidPauseIntervals() {
    var record = workout()
    for duration in [Double.nan, .infinity, -.infinity] {
      record.activeDurationSeconds = duration
      XCTAssertEqual(WatchRecoveryPolicy.summarySavePlan(for: record), .unavailable)
    }
    record.activeDurationSeconds = 700
    record.pauses = [WorkoutPause(startedAt: record.startedAt.addingTimeInterval(-1),
      endedAt: record.startedAt.addingTimeInterval(199))]
    XCTAssertEqual(WatchRecoveryPolicy.summarySavePlan(for: record), .unavailable)
  }

  func testCrashAfterDurableStopIntentFinishesRecoveredActiveSession() {
    XCTAssertEqual(WatchRecoveryPolicy.recovery(stage: .ending, session: .active), .finish)
    XCTAssertEqual(WatchRecoveryPolicy.recovery(stage: .recording, session: .active), .resume)
  }

  func testRecoveryAPIFailureIsNotTreatedAsAnAbsentSession() {
    let stages: [WatchSaveStage] = [.recording, .ending, .collectionEnded, .saveRequested, .saveRejected]
    for stage in stages {
      XCTAssertEqual(WatchRecoveryPolicy.recovery(stage: stage, session: .unavailable), .retryRecovery)
      XCTAssertEqual(WatchRecoveryPolicy.recovery(stage: stage, session: .absent), .preserve)
    }
  }

  func testUnconfirmedFinishIsNeverIssuedAgainOnActiveRecovery() {
    XCTAssertEqual(WatchRecoveryPolicy.recovery(stage: .saveRequested, session: .active), .preserve)
    let attempt = WatchHealthRetry(workoutID: UUID(), stage: .saveRequested)
    XCTAssertEqual(WatchRecoveryPolicy.retry(attempt, hasOriginalBuilder: true), .lookupOnly)
    XCTAssertEqual(WatchRecoveryPolicy.retry(attempt, hasOriginalBuilder: false), .lookupOnly)
  }

  func testDefiniteFailedSaveSurvivesCompletionAndRelaunch() throws {
    let failed = workout()
    let journal = WatchJournal(workout: failed, stage: .saveRejected)
    var state = WatchHealthRecoveryState()
    state.remember(WatchHealthRetry(workoutID: failed.id, stage: .saveRequested))
    state.complete(failed, journal: journal)
    let relaunched = try JSONDecoder().decode(WatchHealthRecoveryState.self,
      from: JSONEncoder().encode(state))
    XCTAssertEqual(relaunched.attempt(for: failed.id)?.stage, .saveRejected)
    XCTAssertEqual(WatchRecoveryPolicy.retry(relaunched.attempt(for: failed.id),
      hasOriginalBuilder: false), .summary)
  }

  func testOriginalBuilderRetainsPriorityWhileAvailable() {
    let stages: [WatchSaveStage] = [.ending, .collectionEnded, .saveRejected]
    for stage in stages {
      let attempt = WatchHealthRetry(workoutID: UUID(), stage: stage)
      XCTAssertEqual(WatchRecoveryPolicy.retry(attempt, hasOriginalBuilder: true), .originalBuilder)
      XCTAssertEqual(WatchRecoveryPolicy.retry(attempt, hasOriginalBuilder: false), .summary)
    }
  }

  func testRetryingOneWorkoutDoesNotLoseAnotherWorkoutsFailure() {
    let first = workout()
    var second = workout()
    second.id = UUID()
    var state = WatchHealthRecoveryState()
    state.complete(first, journal: WatchJournal(workout: first, stage: .saveRejected))
    state.complete(second, journal: WatchJournal(workout: second, stage: .collectionEnded))
    var saved = first
    saved.healthExportState = .saved
    saved.healthWorkoutID = UUID()
    state.complete(saved, journal: nil)
    XCTAssertNil(state.attempt(for: first.id))
    XCTAssertEqual(state.attempt(for: second.id)?.stage, .collectionEnded)
  }

  func testSummarySaveCrashRemainsLookupOnlyAfterRelaunch() throws {
    let failed = workout()
    var state = WatchHealthRecoveryState()
    state.remember(WatchHealthRetry(workoutID: failed.id, stage: .saveRequested, source: .summary))
    // An older original journal must not overwrite the newer summary request's uncertain result.
    state.complete(failed, journal: WatchJournal(workout: failed, stage: .saveRejected))
    let relaunched = try JSONDecoder().decode(WatchHealthRecoveryState.self,
      from: JSONEncoder().encode(state))
    XCTAssertEqual(WatchRecoveryPolicy.retry(relaunched.attempt(for: failed.id),
      hasOriginalBuilder: false), .lookupOnly)
  }

  func testDefinitelyRejectedSummaryCanBeRetriedWithoutSensorBuilder() {
    let attempt = WatchHealthRetry(workoutID: UUID(), stage: .saveRejected, source: .summary)
    XCTAssertEqual(WatchRecoveryPolicy.retry(attempt, hasOriginalBuilder: false), .summary)
  }

  func testLegacyFailuresWithoutSaveEvidenceRemainLookupOnly() {
    XCTAssertEqual(WatchRecoveryPolicy.retry(nil, hasOriginalBuilder: false), .lookupOnly)
  }

  func testSummaryRejectsZeroAndNegativeActivityInsteadOfExpandingToElapsedTime() {
    XCTAssertFalse(WatchRecoveryPolicy.canSaveSummary(duration: 0))
    XCTAssertFalse(WatchRecoveryPolicy.canSaveSummary(duration: -1))
  }

  func testSummaryRejectsNonfiniteActivity() {
    XCTAssertFalse(WatchRecoveryPolicy.canSaveSummary(duration: .nan))
    XCTAssertFalse(WatchRecoveryPolicy.canSaveSummary(duration: .infinity))
    XCTAssertFalse(WatchRecoveryPolicy.canSaveSummary(duration: -.infinity))
  }

  func testSummaryAcceptsPositiveActivityIncludingPartialSeconds() {
    XCTAssertTrue(WatchRecoveryPolicy.canSaveSummary(duration: 0.25))
    XCTAssertTrue(WatchRecoveryPolicy.canSaveSummary(duration: 700))
  }

  func testWatchLocalStartDoesNotInheritPreviousPlace() {
    let previous = WatchWorkoutState(sessionID: UUID(), phase: .finished, kind: .walking,
      placeID: "old-park", placeName: "이전 공원")
    let command = WatchRecoveryPolicy.localCommand(.start, state: previous, kind: .strength)
    XCTAssertNil(command.placeID)
    XCTAssertNil(command.placeName)
    XCTAssertNotEqual(command.sessionID, previous.sessionID)
    XCTAssertEqual(command.kind, .strength)
  }

  func testOngoingWatchCommandsKeepTheirExistingSession() {
    let current = WatchWorkoutState(sessionID: UUID(), phase: .running,
      placeID: "current-park", placeName: "현재 공원")
    let command = WatchRecoveryPolicy.localCommand(.pause, state: current)
    XCTAssertEqual(command.sessionID, current.sessionID)
    XCTAssertEqual(command.placeID, current.placeID)
  }
}
