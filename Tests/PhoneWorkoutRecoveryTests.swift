import XCTest
@testable import OutdoorLog

@MainActor final class PhoneWorkoutRecoveryTests: XCTestCase {
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  func testLongPlaceNameCanStartAndKeepsFullPlaceMetadata() throws {
    let directory = try directory()
    let controller = PhoneWorkoutController(directory: directory)
    let name = String(repeating: "긴 장소명", count: 50)
    try controller.start(kind: .strength, placeID: "long-name-place", placeName: name)
    let saved = try XCTUnwrap(controller.draft?.workout)
    XCTAssertLessThanOrEqual(saved.title.count, 160)
    XCTAssertTrue(saved.title.hasSuffix(WorkoutKind.strength.title))
    XCTAssertEqual(saved.placeName, name)
    XCTAssertEqual(PhoneWorkoutController(directory: directory).draft?.workout, saved)
  }

  func testOverdueDraftCanBeReopenedAndSavedWithActualTimes() throws {
    let directory = try directory()
    let start = Date().addingTimeInterval(-8 * 24 * 3600)
    var clock = start
    let controller = PhoneWorkoutController(directory: directory, now: { clock })
    let store = RecordStore(directory: directory)
    try controller.start(kind: .strength)
    try controller.addSet(exercise: "철봉", repetitions: 5)
    clock = start.addingTimeInterval(8 * 24 * 3600)
    try controller.pause()
    let reopened = PhoneWorkoutController(directory: directory, now: { clock })
    XCTAssertTrue(reopened.ready)
    XCTAssertThrowsError(try reopened.finish(into: store))
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertNotNil(reopened.draft)
    try reopened.finishCorrecting(startedAt: start, endedAt: start.addingTimeInterval(3600),
      activeDurationSeconds: 2400, resetPauses: true, into: store)
    XCTAssertNil(reopened.draft)
    XCTAssertEqual(store.records.first?.duration, 2400)
    XCTAssertEqual(store.records.first?.exercises.first?.sets.first?.repetitions, 5)
    XCTAssertTrue(store.records.first?.pauses.isEmpty == true)
  }

  func testClockRollbackDraftCanBeReopenedAndCorrected() throws {
    let directory = try directory()
    let originalClock = Date()
    var clock = originalClock
    let controller = PhoneWorkoutController(directory: directory, now: { clock })
    try controller.start(kind: .walking)
    clock = originalClock.addingTimeInterval(600)
    try controller.addSet(exercise: "걷기", repetitions: 1)
    clock = originalClock.addingTimeInterval(-600)
    let reopened = PhoneWorkoutController(directory: directory, now: { clock })
    let store = RecordStore(directory: directory)
    XCTAssertTrue(reopened.ready)
    XCTAssertThrowsError(try reopened.finish(into: store))
    try reopened.finishCorrecting(startedAt: clock.addingTimeInterval(-1800), endedAt: clock,
      activeDurationSeconds: 1800, resetPauses: false, into: store)
    XCTAssertEqual(store.records.first?.endedAt, clock)
    XCTAssertNil(reopened.draft)
  }

  func testDiscardReleasesDraftAndAllowsAnotherWorkout() throws {
    let directory = try directory()
    let controller = PhoneWorkoutController(directory: directory)
    try controller.start(kind: .walking)
    try controller.discard()
    XCTAssertNil(controller.draft)
    XCTAssertFalse(controller.canDiscard)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("active-phone-workout.json").path))
    XCTAssertNoThrow(try controller.start(kind: .strength))
  }

  func testUnreadableDraftHasAnExplicitDiscardRecovery() throws {
    let directory = try directory()
    try Data("broken draft".utf8).write(to: directory.appendingPathComponent("active-phone-workout.json"))
    let controller = PhoneWorkoutController(directory: directory)
    XCTAssertFalse(controller.ready)
    XCTAssertTrue(controller.canDiscard)
    try controller.discard()
    XCTAssertTrue(controller.ready)
    XCTAssertNoThrow(try controller.start(kind: .walking))
  }

  func testCorrectionRequiresConsentToRemovePauseHistory() throws {
    let directory = try directory()
    let start = Date().addingTimeInterval(-3600)
    var clock = start
    let controller = PhoneWorkoutController(directory: directory, now: { clock })
    let store = RecordStore(directory: directory)
    try controller.start(kind: .strength)
    clock = start.addingTimeInterval(600)
    try controller.pause()
    clock = start.addingTimeInterval(900)
    XCTAssertThrowsError(try controller.finishCorrecting(startedAt: start, endedAt: clock,
      activeDurationSeconds: 600, resetPauses: false, into: store))
    XCTAssertNotNil(controller.draft?.pausedAt)
    XCTAssertTrue(store.records.isEmpty)
  }

  func testSevenDayLimitAppliesToCompletionButNotAnUnfinishedDraft() throws {
    let end = Date()
    let record = PersonalWorkout(title: "미종료 운동", kind: .walking,
      startedAt: end.addingTimeInterval(-8 * 24 * 3600), endedAt: end)
    XCTAssertNoThrow(try PhoneWorkoutDraft(workout: record).validate())
    XCTAssertThrowsError(try record.validate())
    XCTAssertThrowsError(try PhoneWorkoutDraft(workout: record, finishedAt: end).validate())
  }

  private func measuredWorkout() -> PersonalWorkout {
    let start = Date().addingTimeInterval(-7200)
    return PersonalWorkout(title: "휴식이 있는 운동", kind: .strength, startedAt: start,
      endedAt: start.addingTimeInterval(3600), activeDurationSeconds: 2400,
      pauses: [WorkoutPause(startedAt: start.addingTimeInterval(1200), endedAt: start.addingTimeInterval(2400))])
  }

  func testReturningToOriginalTimesRestoresMeasuredActivityAndPauses() throws {
    let original = measuredWorkout()
    var draft = original
    draft.startedAt = original.startedAt.addingTimeInterval(-60)
    draft.startedAt = original.startedAt
    draft.activeDurationSeconds = nil
    draft.pauses = []
    let restored = try WorkoutTimingCorrection.applying(to: draft, original: original,
      activeDurationSeconds: 3600, resetPauses: true)
    XCTAssertEqual(restored.activeDurationSeconds, original.activeDurationSeconds)
    XCTAssertEqual(restored.pauses, original.pauses)
  }

  func testEditedTimesPreserveChosenActivityAndRequirePauseResetConsent() throws {
    let original = measuredWorkout()
    var draft = original
    draft.startedAt = original.startedAt.addingTimeInterval(-60)
    XCTAssertThrowsError(try WorkoutTimingCorrection.applying(to: draft, original: original,
      activeDurationSeconds: 2400, resetPauses: false))
    let corrected = try WorkoutTimingCorrection.applying(to: draft, original: original,
      activeDurationSeconds: 2400, resetPauses: true)
    XCTAssertEqual(corrected.duration, 2400)
    XCTAssertTrue(corrected.pauses.isEmpty)
    XCTAssertEqual(corrected.timingEditedLocally, true)
    XCTAssertThrowsError(try WorkoutTimingCorrection.applying(to: draft, original: original,
      activeDurationSeconds: 5000, resetPauses: true))
  }
}
