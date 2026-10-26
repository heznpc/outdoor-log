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

  func testPauseSurvivesJournalRelaunchUntilActualResumeArrives() throws {
    var journal = WatchJournal(workout: workout(), elapsedSeconds: 700)
    let pause = journal.workout.startedAt.addingTimeInterval(100)
    let resume = journal.workout.startedAt.addingTimeInterval(300)
    journal.capturePauses([WatchPauseEvent(date: pause, paused: true)], through: journal.workout.endedAt)
    XCTAssertEqual(journal.pauseStartedAt, pause)
    XCTAssertTrue(journal.workout.pauses.isEmpty)
    var restored = try JSONDecoder().decode(WatchJournal.self, from: JSONEncoder().encode(journal))
    restored.capturePauses([WatchPauseEvent(date: resume, paused: false)], through: restored.workout.endedAt)
    XCTAssertEqual(restored.workout.pauses, [WorkoutPause(startedAt: pause, endedAt: resume)])
    XCTAssertNil(restored.pauseStartedAt)
    try restored.validate()
  }

  func testLateDuplicateBuilderEventsUseEventTimesWithoutDuplicatingPauses() {
    var journal = WatchJournal(workout: workout())
    let start = journal.workout.startedAt
    let pause = WatchPauseEvent(date: start.addingTimeInterval(100), paused: true)
    let resume = WatchPauseEvent(date: start.addingTimeInterval(300), paused: false)
    journal.capturePauses([pause, resume], through: journal.workout.endedAt)
    journal.capturePauses([resume, pause, resume, pause], through: journal.workout.endedAt)
    XCTAssertEqual(journal.workout.pauses, [WorkoutPause(startedAt: pause.date, endedAt: resume.date)])
    XCTAssertNil(journal.pauseStartedAt)
  }

  func testFinishWhilePausedClosesOnlyAtKnownWorkoutEnd() {
    var journal = WatchJournal(workout: workout())
    let pause = journal.workout.startedAt.addingTimeInterval(700)
    journal.capturePauses([WatchPauseEvent(date: pause, paused: true)],
      through: journal.workout.endedAt, ending: true)
    XCTAssertEqual(journal.workout.pauses, [WorkoutPause(startedAt: pause, endedAt: journal.workout.endedAt)])
    XCTAssertNil(journal.pauseStartedAt)
  }

  func testStoppedJournalKeepsItsEndAcrossLateEventsAndRelaunch() throws {
    var journal = WatchJournal(workout: workout())
    let start = journal.workout.startedAt
    let stoppedAt = start.addingTimeInterval(600)
    journal.captureTiming(at: stoppedAt, elapsedSeconds: 550, ending: true)
    XCTAssertEqual(journal.stage, .ending)
    XCTAssertEqual(journal.workout.endedAt, stoppedAt)

    var restored = try JSONDecoder().decode(WatchJournal.self, from: JSONEncoder().encode(journal))
    restored.captureTiming(at: stoppedAt.addingTimeInterval(120), elapsedSeconds: 550)
    restored.capturePauses([
      WatchPauseEvent(date: start.addingTimeInterval(100), paused: true),
      WatchPauseEvent(date: start.addingTimeInterval(150), paused: false),
      WatchPauseEvent(date: stoppedAt.addingTimeInterval(10), paused: true)
    ], through: restored.workout.endedAt, ending: true)
    XCTAssertEqual(restored.workout.endedAt, stoppedAt)
    XCTAssertEqual(restored.elapsedSeconds, 550)
    XCTAssertEqual(restored.workout.activeDurationSeconds, 550)
    XCTAssertEqual(restored.workout.pauses, [WorkoutPause(startedAt: start.addingTimeInterval(100),
      endedAt: start.addingTimeInterval(150))])
    XCTAssertNil(restored.pauseStartedAt)
    try restored.validate()
  }

  func testRepeatedEndingCannotExtendStopOrLateOpenPause() throws {
    var journal = WatchJournal(workout: workout())
    let start = journal.workout.startedAt
    let stoppedAt = start.addingTimeInterval(600)
    journal.captureTiming(at: stoppedAt, elapsedSeconds: 500, ending: true)
    journal.captureTiming(at: stoppedAt.addingTimeInterval(300), elapsedSeconds: 500, ending: true)
    journal.capturePauses([
      WatchPauseEvent(date: start.addingTimeInterval(500), paused: true),
      WatchPauseEvent(date: stoppedAt.addingTimeInterval(100), paused: false)
    ], through: journal.workout.endedAt, ending: true)
    XCTAssertEqual(journal.workout.endedAt, stoppedAt)
    XCTAssertEqual(journal.workout.pauses, [WorkoutPause(startedAt: start.addingTimeInterval(500), endedAt: stoppedAt)])
    XCTAssertNil(journal.pauseStartedAt)
    try journal.validate()
  }

  func testPauseRecoveryDoesNotInventMissingBoundariesOrUseFutureEvents() {
    let record = workout()
    let timeline = WatchPauseTimeline(events: [
      WatchPauseEvent(date: record.startedAt.addingTimeInterval(-1), paused: true),
      WatchPauseEvent(date: record.startedAt.addingTimeInterval(50), paused: false),
      WatchPauseEvent(date: record.startedAt.addingTimeInterval(200), paused: true),
      WatchPauseEvent(date: record.endedAt.addingTimeInterval(1), paused: false)
    ], startedAt: record.startedAt, through: record.endedAt)
    XCTAssertTrue(timeline.pauses.isEmpty)
    XCTAssertEqual(timeline.pauseStartedAt, record.startedAt.addingTimeInterval(200))
  }

  func testLegacyJournalWithoutOpenPauseStillDecodes() throws {
    let journal = WatchJournal(workout: workout())
    let data = try JSONEncoder().encode(journal)
    let restored = try JSONDecoder().decode(WatchJournal.self, from: data)
    XCTAssertNil(restored.pauseStartedAt)
    try restored.validate()
  }

  func testJournalRejectsInvalidElapsedAndOverlappingOpenPause() {
    var journal = WatchJournal(workout: workout(), elapsedSeconds: .infinity)
    XCTAssertThrowsError(try journal.validate())
    journal.elapsedSeconds = -1
    XCTAssertThrowsError(try journal.validate())
    journal.elapsedSeconds = 700
    journal.workout.pauses = [WorkoutPause(startedAt: journal.workout.startedAt.addingTimeInterval(100),
      endedAt: journal.workout.startedAt.addingTimeInterval(300))]
    journal.pauseStartedAt = journal.workout.startedAt.addingTimeInterval(200)
    XCTAssertThrowsError(try journal.validate())
  }
}
