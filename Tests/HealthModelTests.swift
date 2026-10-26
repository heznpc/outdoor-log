import XCTest
@testable import OutdoorLog

final class HealthModelTests: XCTestCase {
  func testMissingSamplesDoNotBecomeZero() {
    XCTAssertNil(HealthValues.readableTotal([nil, nil]))
    XCTAssertEqual(HealthValues.readableTotal([nil, 0, nil]), 0)
    XCTAssertEqual(HealthValues.readableTotal([120, nil, 230]), 350)
    XCTAssertNil(HealthValues.nonnegative(.infinity))
    XCTAssertNil(HealthValues.nonnegative(.nan))
    XCTAssertNil(HealthValues.nonnegative(-1))
    XCTAssertEqual(HealthValues.nonnegative(120_000), 120_000)
  }

  func testDayWindowUsesLocalCalendarAcrossSpringDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
    let window = try XCTUnwrap(HealthDateWindow(days: 3, now: now, calendar: calendar))
    XCTAssertEqual(window.days.count, 3)
    XCTAssertEqual(window.days.map { calendar.component(.day, from: $0) }, [7, 8, 9])
    XCTAssertEqual(window.days[2].timeIntervalSince(window.days[1]), 23 * 3600)
    XCTAssertTrue(window.days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
  }

  func testDayWindowUsesLocalCalendarAcrossAutumnDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
    let window = try XCTUnwrap(HealthDateWindow(days: 3, now: now, calendar: calendar))
    XCTAssertEqual(window.days.count, 3)
    XCTAssertEqual(window.days[2].timeIntervalSince(window.days[1]), 25 * 3600)
  }

  func testWindowHasNoEightDayHistoryRestriction() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 1)))
    let window = try XCTUnwrap(HealthDateWindow(days: 366, now: now, calendar: calendar))
    XCTAssertEqual(window.days.count, 366)
    XCTAssertEqual(window.days.last, calendar.startOfDay(for: now))
    XCTAssertEqual(window.calendar.timeZone.identifier, "Pacific/Auckland")
    XCTAssertNil(HealthDateWindow(days: 0, now: now, calendar: calendar))
  }

  func testExportIdentityIsStableAcrossRetryAndDistinguishesLocalRecords() {
    let id = UUID()
    XCTAssertEqual(HealthExportIdentity(localID: id).syncIdentifier, HealthExportIdentity(localID: id).syncIdentifier)
    XCTAssertNotEqual(HealthExportIdentity(localID: id).syncIdentifier, HealthExportIdentity(localID: UUID()).syncIdentifier)
    XCTAssertEqual(HealthExportIdentity.syncVersion, 1)
  }

  func testExportIdentityCanOnlyBeRecoveredFromOwnWellFormedMetadata() {
    let id = UUID()
    let identifier = HealthExportIdentity(localID: id).syncIdentifier
    XCTAssertEqual(HealthExportIdentity.localID(syncIdentifier: identifier, isCurrentApp: true), id)
    XCTAssertNil(HealthExportIdentity.localID(syncIdentifier: identifier, isCurrentApp: false))
    XCTAssertNil(HealthExportIdentity.localID(syncIdentifier: nil, isCurrentApp: true))
    XCTAssertNil(HealthExportIdentity.localID(syncIdentifier: "other-app.\(id.uuidString)", isCurrentApp: true))
    XCTAssertNil(HealthExportIdentity.localID(syncIdentifier: identifier + "-extra", isCurrentApp: true))
    XCTAssertNil(HealthExportIdentity.localID(syncIdentifier: identifier + " ", isCurrentApp: true))
    XCTAssertNil(HealthExportIdentity.localID(syncIdentifier: "outdoor-log.personal-workout.invalid", isCurrentApp: true))
  }

  func testReconciliationRejectsChangedIntervalAndTitle() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let workout = PersonalWorkout(title: "공원 철봉", kind: .strength,
      startedAt: start, endedAt: start.addingTimeInterval(1800))
    let stored = HealthWorkoutSummary(id: UUID(), kind: workout.kind, title: workout.title,
      startedAt: workout.startedAt, endedAt: workout.endedAt, sourceName: "Outdoor Log",
      duration: workout.duration, distanceMeters: nil, activeEnergyKilocalories: nil, manuallyEntered: true)
    XCTAssertTrue(HealthExportIdentity.matches(stored, workout: workout))
    var changed = workout
    changed.endedAt = workout.endedAt.addingTimeInterval(60)
    XCTAssertFalse(HealthExportIdentity.matches(stored, workout: changed))
    changed = workout
    changed.title = "다른 운동"
    XCTAssertFalse(HealthExportIdentity.matches(stored, workout: changed))
    changed = workout
    changed.notes = "기기 메모만 변경"
    XCTAssertTrue(HealthExportIdentity.matches(stored, workout: changed))
  }

  func testUncorrectedExportRequiresRealPauseIntervalsForReducedActiveDuration() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var workout = PersonalWorkout(title: "타이머 운동", kind: .strength,
      startedAt: start, endedAt: start.addingTimeInterval(1800), activeDurationSeconds: 1500)
    XCTAssertThrowsError(try HealthExportTimeline.validate(workout))
    workout.pauses = [WorkoutPause(startedAt: start.addingTimeInterval(600), endedAt: start.addingTimeInterval(900))]
    XCTAssertNoThrow(try HealthExportTimeline.validate(workout))
    workout.pauses[0].endedAt = start.addingTimeInterval(1000)
    XCTAssertThrowsError(try HealthExportTimeline.validate(workout))
  }

  func testExplicitManualCorrectionExportsAggregateDurationWithoutInventingPauses() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var workout = PersonalWorkout(title: "보정한 운동", kind: .strength,
      startedAt: start, endedAt: start.addingTimeInterval(1800), activeDurationSeconds: 1500,
      timingEditedLocally: true)
    XCTAssertEqual(try HealthExportTimeline.validate(workout), .manualDuration)
    XCTAssertTrue(workout.pauses.isEmpty)
    workout.timingEditedLocally = false
    XCTAssertThrowsError(try HealthExportTimeline.validate(workout))
    workout.timingEditedLocally = nil
    XCTAssertThrowsError(try HealthExportTimeline.validate(workout))
  }

  func testManualCorrectionCannotOverrideConflictingPauseIntervals() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var workout = PersonalWorkout(title: "휴식이 있는 보정 기록", kind: .strength,
      startedAt: start, endedAt: start.addingTimeInterval(1800), activeDurationSeconds: 1400,
      pauses: [WorkoutPause(startedAt: start.addingTimeInterval(600), endedAt: start.addingTimeInterval(900))],
      timingEditedLocally: true)
    XCTAssertThrowsError(try HealthExportTimeline.validate(workout))
    workout.activeDurationSeconds = 1500
    XCTAssertEqual(try HealthExportTimeline.validate(workout), .recordedTimeline)
  }

  func testManualDurationPathDoesNotAcceptWatchOrHealthLinkedRecords() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var workout = PersonalWorkout(title: "다른 출처 운동", kind: .strength,
      startedAt: start, endedAt: start.addingTimeInterval(1800), activeDurationSeconds: 1500,
      timingEditedLocally: true, origin: .watch)
    XCTAssertThrowsError(try HealthExportTimeline.validate(workout))
    workout.origin = .healthLink
    XCTAssertThrowsError(try HealthExportTimeline.validate(workout))
  }

  func testZeroAggregateDurationDoesNotBecomeFullElapsedTime() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let workout = PersonalWorkout(title: "활동하지 않은 기록", kind: .strength,
      startedAt: start, endedAt: start.addingTimeInterval(1800), activeDurationSeconds: 0,
      timingEditedLocally: true)
    XCTAssertThrowsError(try HealthExportTimeline.validate(workout)) { error in
      guard case HealthLibraryError.zeroManualDuration = error else {
        return XCTFail("Expected an explicit zero-duration rejection, received \(error)")
      }
    }
  }

  func testExportSeparatesTimelineReconciliationFromNewWriteFutureLimit() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var workout = PersonalWorkout(title: "보정한 운동", kind: .strength,
      startedAt: now.addingTimeInterval(-1200), endedAt: now.addingTimeInterval(301),
      activeDurationSeconds: 1000, timingEditedLocally: true)
    XCTAssertEqual(try HealthExportTimeline.validate(workout), .manualDuration)
    XCTAssertThrowsError(try workout.validateNewTiming(at: now))
    workout.endedAt = now.addingTimeInterval(300)
    XCTAssertNoThrow(try workout.validateNewTiming(at: now))
    XCTAssertEqual(try HealthExportTimeline.validate(workout), .manualDuration)
    workout.activeDurationSeconds = 1500
    XCTAssertEqual(try HealthExportTimeline.validate(workout), .recordedTimeline)
  }

  func testManualDurationReconciliationRejectsAChangedActiveDuration() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var workout = PersonalWorkout(title: "보정한 운동", kind: .strength,
      startedAt: start, endedAt: start.addingTimeInterval(1800), activeDurationSeconds: 1500,
      timingEditedLocally: true)
    let identity = HealthExportIdentity(localID: workout.id)
    let stored = HealthWorkoutSummary(id: UUID(), kind: workout.kind, title: workout.title,
      startedAt: workout.startedAt, endedAt: workout.endedAt, sourceName: "OutdoorLog",
      duration: 1500, distanceMeters: nil, activeEnergyKilocalories: nil, manuallyEntered: true)
    XCTAssertTrue(HealthExportIdentity.matches(stored, workout: workout))
    workout.activeDurationSeconds = 1200
    XCTAssertEqual(HealthExportIdentity(localID: workout.id), identity)
    XCTAssertFalse(HealthExportIdentity.matches(stored, workout: workout))
  }
}
