import XCTest
@testable import OutdoorLog

final class WatchProtocolTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func record() -> PersonalWorkout {
    PersonalWorkout(title: "공원 근력 운동", kind: .strength, startedAt: now,
      endedAt: now.addingTimeInterval(1800), activeDurationSeconds: 1500,
      placeID: "park-1", placeName: "공원 철봉", healthWorkoutID: UUID(), healthExportState: .saved, origin: .watch)
  }

  func testCompletedWatchRecordRoundTripsWithStableIdentityAndSets() throws {
    var workout = record()
    workout.exercises = [ExerciseEntry(name: "턱걸이", sets: [ExerciseSet(repetitions: 8)])]
    let decoded = try WatchWire.decode(WatchWire.encode(WatchPacket(kind: .completed, workout: workout)))
    XCTAssertEqual(decoded.workout, workout)
    XCTAssertEqual(decoded.workout?.duration, 1500)
  }

  func testFailedHealthExportRemainsAValidPersonalRecord() throws {
    var workout = record()
    workout.healthWorkoutID = nil
    workout.healthExportState = .failed
    workout.healthExportMessage = "건강 저장 확인 필요"
    XCTAssertNoThrow(try WatchWire.encode(WatchPacket(kind: .completed, workout: workout)))
    workout.healthExportState = .saved
    XCTAssertThrowsError(try WatchWire.encode(WatchPacket(kind: .completed, workout: workout)))
    workout.healthExportState = .pending
    XCTAssertThrowsError(try WatchWire.encode(WatchPacket(kind: .completed, workout: workout)))
  }

  func testCommandLifetimeRejectsOldAndFutureRequests() {
    let state = WatchWorkoutState()
    let id = UUID()
    let valid = WatchCommand(action: .start, sessionID: id, issuedAt: now)
    XCTAssertNoThrow(try WatchWire.validateCommand(valid, state: state, now: now))
    var stale = valid
    stale.issuedAt = now.addingTimeInterval(-31)
    XCTAssertThrowsError(try WatchWire.validateCommand(stale, state: state, now: now))
    var future = valid
    future.issuedAt = now.addingTimeInterval(6)
    XCTAssertThrowsError(try WatchWire.validateCommand(future, state: state, now: now))
  }

  func testCommandsCannotControlAnotherOrFinishedSession() {
    let id = UUID()
    var state = WatchWorkoutState(sessionID: id, phase: .running)
    let finish = WatchCommand(action: .finish, sessionID: id, issuedAt: now)
    XCTAssertNoThrow(try WatchWire.validateCommand(finish, state: state, now: now))
    let wrong = WatchCommand(action: .finish, sessionID: UUID(), issuedAt: now)
    XCTAssertThrowsError(try WatchWire.validateCommand(wrong, state: state, now: now))
    let start = WatchCommand(action: .start, sessionID: UUID(), issuedAt: now)
    XCTAssertThrowsError(try WatchWire.validateCommand(start, state: state, now: now))
    state.phase = .finished
    XCTAssertThrowsError(try WatchWire.validateCommand(finish, state: state, now: now))
    let reused = WatchCommand(action: .start, sessionID: id, issuedAt: now)
    XCTAssertThrowsError(try WatchWire.validateCommand(reused, state: state, now: now))
  }

  func testPauseAndResumeEnforceExpectedPhase() {
    let id = UUID()
    let paused = WatchWorkoutState(sessionID: id, phase: .paused)
    XCTAssertNoThrow(try WatchWire.validateCommand(WatchCommand(action: .resume, sessionID: id, issuedAt: now), state: paused, now: now))
    XCTAssertThrowsError(try WatchWire.validateCommand(WatchCommand(action: .pause, sessionID: id, issuedAt: now), state: paused, now: now))
  }

  func testStaleStateCannotReplaceNewerWorkoutState() {
    let current = WatchWorkoutState(sessionID: UUID(), phase: .running, updatedAt: now)
    let stale = WatchWorkoutState(sessionID: UUID(), phase: .finished, updatedAt: now.addingTimeInterval(-1))
    XCTAssertFalse(WatchWire.shouldApply(stale, after: current))
    XCTAssertFalse(WatchWire.shouldApply(current, after: current))
    var newer = current
    newer.phase = .paused
    newer.updatedAt = now.addingTimeInterval(1)
    XCTAssertTrue(WatchWire.shouldApply(newer, after: current))
  }

  func testAcknowledgementMustMatchExactDurableRevision() throws {
    let original = record()
    let ack = WatchPacket(kind: .acknowledgement, workout: original, acknowledgedWorkoutID: original.id)
    XCTAssertTrue(WatchWire.matchesAcknowledgement(ack, workout: original))
    var updated = original
    updated.modifiedAt = original.modifiedAt.addingTimeInterval(1)
    updated.healthWorkoutID = UUID()
    XCTAssertFalse(WatchWire.matchesAcknowledgement(ack, workout: updated))
    XCTAssertThrowsError(try WatchWire.encode(WatchPacket(kind: .acknowledgement, acknowledgedWorkoutID: original.id)))
    let wrongID = WatchPacket(kind: .acknowledgement, workout: original, acknowledgedWorkoutID: UUID())
    XCTAssertThrowsError(try WatchWire.encode(wrongID))
  }

  func testMalformedVersionAndOversizedFramesAreRejectedBeforeUse() throws {
    XCTAssertThrowsError(try WatchWire.decode(Data(repeating: 0, count: WatchWire.maximumBytes + 1)))
    let unsupported = WatchPacket(version: 2, kind: .state, state: WatchWorkoutState())
    XCTAssertThrowsError(try WatchWire.decode(JSONEncoder().encode(unsupported)))
    XCTAssertThrowsError(try WatchWire.encode(WatchPacket(kind: .completed)))
    XCTAssertThrowsError(try WatchWire.encode(WatchPacket(kind: .command, command: WatchCommand(action: .finish))))
    var state = WatchWorkoutState()
    state.heartRate = -.infinity
    XCTAssertThrowsError(try WatchWire.validate(state))
  }

  func testMaximumWatchSetEntryFitsTransportLimit() throws {
    var workout = record()
    workout.exercises = (0..<15).map { index in
      ExerciseEntry(name: String(repeating: "가", count: 77) + "\(index)",
        sets: (0..<20).map { _ in ExerciseSet(repetitions: 100, weightKilograms: 2000) })
    }
    let data = try WatchWire.encode(WatchPacket(kind: .completed, workout: workout))
    XCTAssertLessThanOrEqual(data.count, WatchWire.maximumBytes)
  }

  func testReplyMustBeCorrelatedAndDoesNotConvertRejectionToSuccess() throws {
    let id = UUID()
    let reply = WatchCommandReply(commandID: id, accepted: false, state: WatchWorkoutState(), message: "다른 운동입니다.")
    let data = try reply.encoded()
    XCTAssertFalse(try WatchCommandReply.decode(data, commandID: id).accepted)
    XCTAssertThrowsError(try WatchCommandReply.decode(data, commandID: UUID()))
  }
}
