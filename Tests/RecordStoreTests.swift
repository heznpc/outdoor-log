import XCTest
@testable import OutdoorLog

@MainActor final class RecordStoreTests: XCTestCase {
  private func directory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: path) }
    return path
  }

  private func workout(origin: WorkoutOrigin = .phone) -> PersonalWorkout {
    let now = Date()
    return PersonalWorkout(title: "철봉", kind: .strength,
      startedAt: now.addingTimeInterval(-600), endedAt: now, origin: origin)
  }

  func testWatchDeliveryDoesNotReplaceEditedRecord() throws {
    let store = RecordStore(directory: try directory())
    let incoming = workout(origin: .watch)
    XCTAssertTrue(store.acceptWatch(incoming))
    var edited = incoming
    edited.notes = "개인 메모"
    try store.save(edited)
    XCTAssertTrue(store.acceptWatch(incoming))
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(store.records.first?.notes, "개인 메모")
  }

  func testDeletedWatchDeliveryRemainsDeletedAfterRelaunch() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    let incoming = workout(origin: .watch)
    XCTAssertTrue(store.acceptWatch(incoming))
    try store.remove(incoming.id)
    let reopened = RecordStore(directory: directory)
    XCTAssertTrue(reopened.acceptWatch(incoming))
    XCTAssertTrue(reopened.records.isEmpty)
  }

  func testCorruptArchiveIsNotOverwrittenOrAcknowledged() throws {
    let directory = try directory()
    let file = directory.appendingPathComponent("personal-workouts.json")
    let original = Data("invalid".utf8)
    try original.write(to: file)
    let store = RecordStore(directory: directory)
    XCTAssertFalse(store.ready)
    XCTAssertFalse(store.acceptWatch(workout(origin: .watch)))
    XCTAssertThrowsError(try store.save(workout()))
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  func testImportDoesNotOverwriteExistingRecord() throws {
    let store = RecordStore(directory: try directory())
    let record = workout()
    try store.save(record)
    var changed = record
    changed.title = "外部"
    let archive = RecordArchive(records: [changed])
    try store.importData(JSONEncoder().encode(archive))
    XCTAssertEqual(store.records.first?.title, record.title)
  }

  func testLateWatchHealthSavePreservesLocalNotes() throws {
    let store = RecordStore(directory: try directory())
    var record = workout(origin: .watch)
    XCTAssertTrue(store.acceptWatch(record))
    var edited = record
    edited.notes = "메모 보존"
    try store.save(edited)
    record.healthWorkoutID = UUID()
    record.healthExportState = .saved
    XCTAssertTrue(store.acceptWatch(record))
    XCTAssertEqual(store.records.first?.healthWorkoutID, record.healthWorkoutID)
    XCTAssertEqual(store.records.first?.notes, "메모 보존")
  }

  func testActiveDurationAndOverlappingPauseValidation() throws {
    var record = workout()
    record.activeDurationSeconds = 400
    record.pauses = [WorkoutPause(startedAt: record.startedAt.addingTimeInterval(100),
      endedAt: record.startedAt.addingTimeInterval(300))]
    XCTAssertNoThrow(try record.validate())
    record.pauses.append(WorkoutPause(startedAt: record.startedAt.addingTimeInterval(200),
      endedAt: record.startedAt.addingTimeInterval(350)))
    XCTAssertThrowsError(try record.validate())
  }

  func testOversizedSavePreservesReadableArchive() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory, maximumArchiveBytes: 2_000)
    let first = workout()
    try store.save(first)
    let before = try store.exportData()
    var large = workout()
    large.notes = String(repeating: "a", count: 2_000)
    XCTAssertThrowsError(try store.save(large))
    XCTAssertEqual(try store.exportData(), before)
    let reopened = RecordStore(directory: directory, maximumArchiveBytes: 2_000)
    XCTAssertTrue(reopened.ready)
    XCTAssertEqual(reopened.records.map(\.id), [first.id])
  }

  func testStaleEditorPreservesLateWatchHealthResult() throws {
    let store = RecordStore(directory: try directory())
    let original = workout(origin: .watch)
    XCTAssertTrue(store.acceptWatch(original))
    var edited = original
    edited.notes = "편집 중인 메모"
    var completed = original
    completed.healthWorkoutID = UUID()
    completed.healthExportState = .saved
    XCTAssertTrue(store.acceptWatch(completed))
    try store.saveEdited(edited, original: original)
    XCTAssertEqual(store.records.first?.healthWorkoutID, completed.healthWorkoutID)
    XCTAssertEqual(store.records.first?.healthExportState, .saved)
    XCTAssertEqual(store.records.first?.notes, edited.notes)
  }

  func testHealthLinkAndDelayedWatchDeliveryBecomeOneRecord() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    var linked = workout(origin: .healthLink)
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    linked.notes = "건강에서 연결한 메모"
    try store.save(linked)
    var incoming = workout(origin: .watch)
    incoming.healthWorkoutID = linked.healthWorkoutID
    incoming.healthExportState = .saved
    incoming.exercises = [ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 5)])]
    XCTAssertTrue(store.acceptWatch(incoming))
    var edited = linked
    edited.title = "제목 변경"
    try store.saveEdited(edited, original: linked)
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(store.records.first?.id, linked.id)
    XCTAssertEqual(store.records.first?.notes, linked.notes)
    XCTAssertEqual(store.records.first?.exercises, incoming.exercises)
    XCTAssertEqual(store.records.first?.origin, .watch)
    let reopened = RecordStore(directory: directory)
    XCTAssertTrue(reopened.acceptWatch(incoming))
    XCTAssertEqual(reopened.records.count, 1)
    try reopened.remove(linked.id)
    let deleted = RecordStore(directory: directory)
    XCTAssertTrue(deleted.acceptWatch(incoming))
    XCTAssertTrue(deleted.records.isEmpty)
  }

  func testLateHealthIDCoalescesPreviouslySeparateRecords() throws {
    let store = RecordStore(directory: try directory())
    var incoming = workout(origin: .watch)
    incoming.notes = "워치 기록 메모"
    XCTAssertTrue(store.acceptWatch(incoming))
    var linked = workout(origin: .healthLink)
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    linked.notes = "건강 연결 메모"
    try store.save(linked)
    incoming.healthWorkoutID = linked.healthWorkoutID
    incoming.healthExportState = .saved
    XCTAssertTrue(store.acceptWatch(incoming))
    XCTAssertEqual(store.records.count, 1)
    XCTAssertTrue(store.records[0].notes.contains(linked.notes))
    XCTAssertTrue(store.records[0].notes.contains(incoming.notes))
    XCTAssertTrue(store.acceptWatch(incoming))
    XCTAssertEqual(store.records.count, 1)
  }

  func testEditorMergesNewWatchExercisesAndConcurrentNotes() throws {
    let store = RecordStore(directory: try directory())
    var linked = workout(origin: .healthLink)
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    try store.save(linked)
    var draft = linked
    draft.notes = "편집기 메모"
    draft.exercises = [ExerciseEntry(name: "스쿼트")]
    var incoming = workout(origin: .watch)
    incoming.healthWorkoutID = linked.healthWorkoutID
    incoming.healthExportState = .saved
    incoming.notes = "워치 메모"
    incoming.exercises = [ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 5)])]
    XCTAssertTrue(store.acceptWatch(incoming))
    try store.saveEdited(draft, original: linked)
    XCTAssertEqual(Set(store.records[0].exercises.map(\.name)), Set(["스쿼트", "철봉"]))
    XCTAssertTrue(store.records[0].notes.contains(draft.notes))
    XCTAssertTrue(store.records[0].notes.contains(incoming.notes))
  }

  func testRecoveredWatchTimingUpdatesOnlyUneditedMeasurements() throws {
    let store = RecordStore(directory: try directory())
    let original = workout(origin: .watch)
    XCTAssertTrue(store.acceptWatch(original))
    var recovered = original
    recovered.healthWorkoutID = UUID()
    recovered.healthExportState = .saved
    recovered.endedAt = original.endedAt.addingTimeInterval(20)
    recovered.activeDurationSeconds = 620
    XCTAssertTrue(store.acceptWatch(recovered))
    XCTAssertEqual(store.records[0].endedAt, recovered.endedAt)
    XCTAssertEqual(store.records[0].activeDurationSeconds, 620)

    let editedStore = RecordStore(directory: try directory())
    XCTAssertTrue(editedStore.acceptWatch(original))
    var edited = original
    edited.endedAt = original.endedAt.addingTimeInterval(-60)
    try editedStore.saveEdited(edited, original: original)
    XCTAssertTrue(editedStore.acceptWatch(recovered))
    XCTAssertEqual(editedStore.records[0].endedAt, edited.endedAt)
    XCTAssertEqual(editedStore.records[0].healthWorkoutID, recovered.healthWorkoutID)
  }

  func testCoalescingPreservesEditedWatchFieldsAndLinkedAlternatives() throws {
    let store = RecordStore(directory: try directory())
    var incoming = workout(origin: .watch)
    XCTAssertTrue(store.acceptWatch(incoming))
    var edited = incoming
    edited.title = "내가 정한 제목"
    edited.kind = .flexibility
    edited.endedAt = incoming.endedAt.addingTimeInterval(-30)
    edited.placeID = "watch-place"
    edited.placeName = "첫 장소"
    try store.saveEdited(edited, original: incoming)
    var linked = workout(origin: .healthLink)
    linked.title = "다른 기록 제목"
    linked.placeID = "health-place"
    linked.placeName = "다른 장소"
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    try store.save(linked)
    incoming.healthWorkoutID = linked.healthWorkoutID
    incoming.healthExportState = .saved
    XCTAssertTrue(store.acceptWatch(incoming))
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(store.records[0].title, edited.title)
    XCTAssertEqual(store.records[0].kind, edited.kind)
    XCTAssertEqual(store.records[0].endedAt, edited.endedAt)
    XCTAssertEqual(store.records[0].placeID, edited.placeID)
    XCTAssertTrue(store.records[0].notes.contains(linked.title))
    XCTAssertTrue(store.records[0].notes.contains(linked.placeName!))
  }

  func testImportRestoresDeletionHistoryWithoutResurrectingWatchRecord() throws {
    let source = RecordStore(directory: try directory())
    let record = workout(origin: .watch)
    XCTAssertTrue(source.acceptWatch(record))
    try source.remove(record.id)
    let destination = RecordStore(directory: try directory())
    try destination.importData(source.exportData())
    XCTAssertTrue(destination.acceptWatch(record))
    XCTAssertTrue(destination.records.isEmpty)
  }

  func testImportedDeletionDoesNotDeleteALiveRecordOrItsAlias() throws {
    let destination = RecordStore(directory: try directory())
    var record = workout(origin: .watch)
    let sourceID = UUID()
    record.watchSourceIDs = [sourceID]
    try destination.save(record)
    let archive = RecordArchive(deletedIDs: [record.id, sourceID])
    try destination.importData(JSONEncoder().encode(archive))
    XCTAssertEqual(destination.records, [record])
    let exported = try JSONDecoder().decode(RecordArchive.self, from: destination.exportData())
    XCTAssertTrue(exported.deletedIDs.isEmpty)
  }

  func testImportSkipsMergedAliasAndStillAddsUnrelatedRecords() throws {
    let destination = RecordStore(directory: try directory())
    let watch = workout(origin: .watch)
    try destination.save(watch)
    var merged = workout(origin: .watch)
    merged.watchSourceIDs = [watch.id]
    merged.healthWorkoutID = UUID()
    merged.healthExportState = .saved
    let unrelated = workout()
    let archive = RecordArchive(records: [merged, unrelated])
    try destination.importData(JSONEncoder().encode(archive))
    XCTAssertEqual(Set(destination.records.map(\.id)), [watch.id, unrelated.id])
  }

  func testImportSkipsAnAliasOfDeletedRecordAndStillAddsUnrelatedRecords() throws {
    let destination = RecordStore(directory: try directory())
    let deletedID = UUID()
    try destination.remove(deletedID)
    var merged = workout(origin: .watch)
    merged.watchSourceIDs = [deletedID]
    let unrelated = workout()
    try destination.importData(JSONEncoder().encode(RecordArchive(records: [merged, unrelated])))
    XCTAssertEqual(destination.records.map(\.id), [unrelated.id])
  }

  func testClockRollbackDoesNotBlockArchiveReadOrMetadataEdit() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    let now = Date()
    var previouslySaved = workout()
    previouslySaved.startedAt = now.addingTimeInterval(600)
    previouslySaved.endedAt = now.addingTimeInterval(1200)
    // Structure remains valid even when today's corrected clock precedes this record.
    XCTAssertNoThrow(try previouslySaved.validate())
    XCTAssertThrowsError(try previouslySaved.validateNewTiming(at: now))
    try store.save(previouslySaved)
    let reopened = RecordStore(directory: directory)
    XCTAssertTrue(reopened.ready)
    var edited = previouslySaved
    edited.notes = "시계가 보정된 뒤 추가한 메모"
    try reopened.saveEdited(edited, original: previouslySaved)
    XCTAssertEqual(reopened.records.first?.notes, edited.notes)
    XCTAssertNoThrow(try reopened.exportData())
  }

  func testNewOrChangedFutureTimingStillRequiresCorrection() throws {
    let store = RecordStore(directory: try directory())
    var future = workout()
    future.startedAt = Date().addingTimeInterval(3600)
    future.endedAt = future.startedAt.addingTimeInterval(600)
    XCTAssertThrowsError(try store.saveEdited(future, original: future))
    let original = workout()
    try store.save(original)
    future.id = original.id
    XCTAssertThrowsError(try store.saveEdited(future, original: original))
    XCTAssertEqual(store.records, [original])
  }

  func testStructuralValidationStillRejectsNonfiniteDates() throws {
    let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
    var record = workout()
    record.modifiedAt = invalid
    XCTAssertThrowsError(try record.validate())
    record = workout()
    record.startedAt = Date(timeIntervalSinceReferenceDate: -.infinity)
    XCTAssertThrowsError(try record.validateInProgress())
    record = workout()
    record.endedAt = invalid
    record.activeDurationSeconds = 1
    XCTAssertThrowsError(try record.validate())
    record = workout()
    record.pauses = [WorkoutPause(startedAt: record.startedAt, endedAt: invalid)]
    XCTAssertThrowsError(try record.validate())
  }
}
