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

  private func healthSummary(_ workout: PersonalWorkout, healthID: UUID, exportedLocalID: UUID? = nil) -> HealthWorkoutSummary {
    HealthWorkoutSummary(id: healthID, kind: workout.kind, title: workout.title,
      startedAt: workout.startedAt, endedAt: workout.endedAt, sourceName: "OutdoorLog",
      duration: workout.duration, distanceMeters: nil, activeEnergyKilocalories: nil,
      manuallyEntered: true, pauses: workout.pauses, exportedLocalID: exportedLocalID)
  }

  func testConflictingWatchHealthIdentityDoesNotMergeOrAcknowledge() throws {
    let store = RecordStore(directory: try directory())
    var original = workout(origin: .watch)
    original.healthWorkoutID = UUID()
    original.healthExportState = .saved
    XCTAssertTrue(store.acceptWatch(original))
    var linked = workout(origin: .healthLink)
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    linked.notes = "이 기록은 별도로 유지"
    try store.save(linked)
    let before = try store.exportData()
    var conflict = original
    conflict.healthWorkoutID = linked.healthWorkoutID
    XCTAssertFalse(store.acceptWatch(conflict))
    XCTAssertEqual(try store.exportData(), before)
    XCTAssertNotNil(store.notice)
  }

  func testDeletedHealthLinkCannotBeResurrectedByFirstWatchDeliveryOrBackup() throws {
    let folder = try directory()
    let store = RecordStore(directory: folder)
    var linked = workout(origin: .healthLink)
    linked.healthWorkoutID = UUID(); linked.healthExportState = .saved
    try store.save(linked)
    try store.remove(linked.id)
    let reopened = RecordStore(directory: folder)
    var watch = linked
    watch.id = UUID(); watch.origin = .watch
    XCTAssertTrue(reopened.acceptWatch(watch))
    XCTAssertTrue(reopened.records.isEmpty)
    var olderDelivery = watch
    olderDelivery.healthWorkoutID = nil; olderDelivery.healthExportState = .failed
    XCTAssertTrue(reopened.acceptWatch(olderDelivery))
    XCTAssertTrue(reopened.records.isEmpty)
    try reopened.importData(JSONEncoder().encode(RecordArchive(records: [watch])))
    XCTAssertTrue(reopened.records.isEmpty)
    let restored = RecordStore(directory: try directory())
    try restored.importData(reopened.exportData())
    XCTAssertTrue(restored.acceptWatch(watch))
    XCTAssertTrue(restored.records.isEmpty)
    // An explicit new attachment is allowed to reverse this local deletion.
    linked.id = UUID()
    try restored.save(linked)
    XCTAssertTrue(restored.acceptWatch(watch))
    XCTAssertEqual(restored.records.count, 1)
  }

  func testLegacyArchiveWithoutHealthTombstonesStillLoads() throws {
    let folder = try directory()
    let data = try JSONSerialization.data(withJSONObject: ["version": 1, "records": [], "deletedIDs": []])
    try data.write(to: folder.appendingPathComponent("personal-workouts.json"))
    XCTAssertTrue(RecordStore(directory: folder).ready)
  }

  func testDeletedWatchDeliveryPersistsLateHealthIdentityBeforeAcknowledging() throws {
    let folder = try directory()
    let store = RecordStore(directory: folder)
    var watch = workout(origin: .watch)
    watch.healthExportState = .failed
    XCTAssertTrue(store.acceptWatch(watch))
    try store.remove(watch.id)
    watch.healthWorkoutID = UUID(); watch.healthExportState = .saved
    XCTAssertTrue(store.acceptWatch(watch))
    var backupLink = watch
    backupLink.id = UUID(); backupLink.origin = .healthLink
    let reopened = RecordStore(directory: folder)
    try reopened.importData(JSONEncoder().encode(RecordArchive(records: [backupLink])))
    XCTAssertTrue(reopened.records.isEmpty)
  }

  func testDeletedHealthLinkDoesNotDeleteSurvivingWatchRecordOrBlockRetry() throws {
    let folder = try directory()
    let store = RecordStore(directory: folder)
    var watch = workout(origin: .watch)
    watch.healthExportState = .failed
    XCTAssertTrue(store.acceptWatch(watch))
    var link = workout(origin: .healthLink)
    link.healthWorkoutID = UUID(); link.healthExportState = .saved
    try store.save(link)
    try store.remove(link.id)
    var retry = watch
    retry.healthWorkoutID = link.healthWorkoutID; retry.healthExportState = .saved
    XCTAssertTrue(store.acceptWatch(retry))
    let reopened = RecordStore(directory: folder)
    XCTAssertEqual(reopened.records, [watch])
    XCTAssertTrue(reopened.acceptWatch(retry))
    XCTAssertEqual(reopened.records, [watch])
  }

  func testWatchDeliveryCannotClaimPhoneRecordByLocalOrHealthIdentity() throws {
    let store = RecordStore(directory: try directory())
    var phone = workout()
    phone.healthWorkoutID = UUID()
    phone.healthExportState = .saved
    try store.save(phone)
    var incoming = phone
    incoming.origin = .watch
    XCTAssertFalse(store.acceptWatch(incoming))
    incoming.id = UUID()
    XCTAssertFalse(store.acceptWatch(incoming))
    XCTAssertEqual(store.records, [phone])
  }

  func testRecoveredWatchSummaryWarningSurvivesOldFailedDeliveryAndRelaunch() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    var failed = workout(origin: .watch)
    failed.healthExportState = .failed
    XCTAssertTrue(store.acceptWatch(failed))
    var recovered = failed
    recovered.healthWorkoutID = UUID()
    recovered.healthExportState = .saved
    recovered.healthExportMessage = "요약 저장: 원래 센서 수치는 포함하지 않았습니다."
    XCTAssertTrue(store.acceptWatch(recovered))
    XCTAssertTrue(store.acceptWatch(failed))
    var earlierSuccess = recovered
    earlierSuccess.healthExportMessage = nil
    XCTAssertTrue(store.acceptWatch(earlierSuccess))
    let reopened = RecordStore(directory: directory)
    XCTAssertEqual(reopened.records.first?.healthWorkoutID, recovered.healthWorkoutID)
    XCTAssertEqual(reopened.records.first?.healthExportState, .saved)
    XCTAssertEqual(reopened.records.first?.healthExportMessage, recovered.healthExportMessage)
  }

  func testFirstWatchAttachmentKeepsConflictingSetsAndExistingPlaceName() throws {
    let store = RecordStore(directory: try directory())
    let originalSet = ExerciseSet(repetitions: 5)
    var linked = workout(origin: .healthLink)
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    linked.placeName = "직접 기록한 장소"
    linked.exercises = [ExerciseEntry(name: "철봉", sets: [originalSet])]
    try store.save(linked)
    var incoming = linked
    incoming.id = UUID()
    incoming.origin = .watch
    incoming.placeID = "watch-place"
    incoming.placeName = "Watch의 장소"
    incoming.exercises[0].sets[0].repetitions = 8
    incoming.exercises[0].sets.append(ExerciseSet(repetitions: 10))
    XCTAssertTrue(store.acceptWatch(incoming))
    let merged = try XCTUnwrap(store.records.first)
    XCTAssertEqual(merged.placeName, linked.placeName)
    XCTAssertTrue(merged.notes.contains("Watch의 장소"))
    XCTAssertEqual(merged.exercises[0].sets.map(\.repetitions), [5, 8, 10])
    XCTAssertEqual(Set(merged.exercises[0].sets.map(\.id)).count, 3)
    XCTAssertTrue(store.acceptWatch(incoming))
    XCTAssertEqual(store.records, [merged])
  }

  func testUnreadableArchiveCanRestoreBackupWithoutLosingOriginalBytes() throws {
    let directory = try directory()
    let file = directory.appendingPathComponent("personal-workouts.json")
    let unreadable = Data("damaged original archive".utf8)
    try unreadable.write(to: file)
    let store = RecordStore(directory: directory)
    XCTAssertFalse(store.ready)
    var restored = workout()
    restored.healthExportState = .pending
    let deleted = UUID()
    let data = try JSONEncoder().encode(RecordArchive(records: [restored], deletedIDs: [deleted]))
    try store.restoreUnreadableArchive(from: data)
    XCTAssertTrue(store.ready)
    XCTAssertEqual(store.records.first?.healthExportState, .failed)
    let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("personal-workouts-unreadable-") }
    XCTAssertEqual(preserved.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), unreadable)
    let reopened = RecordStore(directory: directory)
    XCTAssertTrue(reopened.ready)
    XCTAssertEqual(reopened.records, store.records)
    XCTAssertTrue(reopened.hasDurableRecordOrDeletion(deleted))
    XCTAssertThrowsError(try reopened.restoreUnreadableArchive(from: data))
  }

  func testInvalidRecoveryBackupLeavesUnreadableArchiveUntouched() throws {
    let directory = try directory()
    let file = directory.appendingPathComponent("personal-workouts.json")
    let unreadable = Data("keep original".utf8)
    try unreadable.write(to: file)
    let store = RecordStore(directory: directory)
    var invalid = workout()
    invalid.notes = String(repeating: "x", count: 10_001)
    let data = try JSONEncoder().encode(RecordArchive(records: [invalid]))
    XCTAssertThrowsError(try store.restoreUnreadableArchive(from: data))
    XCTAssertFalse(store.ready)
    XCTAssertEqual(try Data(contentsOf: file), unreadable)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["personal-workouts.json"])
  }

  func testHealthAttachmentRecoversInterruptedExportWithoutReplacingLocalEdits() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    let exported = workout()
    var edited = exported
    edited.title = "내가 수정한 제목"
    edited.notes = "건강 저장 응답 이후에 쓴 메모"
    edited.placeID = "local-place"
    edited.placeName = "개인 장소"
    edited.healthExportState = .pending
    try store.save(edited)
    let summary = healthSummary(exported, healthID: UUID(), exportedLocalID: exported.id)

    let attached = try store.recordForHealthAttachment(summary)

    XCTAssertEqual(attached.id, exported.id)
    XCTAssertEqual(attached.origin, .phone)
    XCTAssertEqual(attached.healthWorkoutID, summary.id)
    XCTAssertEqual(attached.healthExportState, .saved)
    XCTAssertEqual(attached.title, edited.title)
    XCTAssertEqual(attached.notes, edited.notes)
    XCTAssertEqual(attached.placeID, edited.placeID)
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(RecordStore(directory: directory).records, [attached])
  }

  func testHealthExportCompletionAtomicallyCoalescesOldLinkAndPreservesConflicts() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    var original = workout()
    original.notes = "원래 기록의 메모"
    original.placeID = "same-place-id"
    original.placeName = "원래 장소 이름"
    original.exercises = [ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 10)])]
    original.healthExportState = .failed
    var linked = original
    linked.id = UUID()
    linked.origin = .healthLink
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    linked.title = "다른 기록 제목"
    linked.endedAt = original.endedAt.addingTimeInterval(-60)
    linked.notes = "연결 기록의 메모"
    linked.placeName = "다른 장소 이름"
    linked.exercises[0].sets[0].repetitions = 12
    linked.exercises[0].sets.append(ExerciseSet(repetitions: 20))
    try store.save(original)
    try store.save(linked)
    let healthID = try XCTUnwrap(linked.healthWorkoutID)

    let merged = try XCTUnwrap(store.completeHealthExport(localID: original.id, healthWorkoutID: healthID))

    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(merged.id, original.id)
    XCTAssertEqual(merged.title, original.title)
    XCTAssertEqual(merged.endedAt, original.endedAt)
    XCTAssertEqual(merged.placeName, original.placeName)
    XCTAssertTrue(merged.notes.contains(original.notes))
    XCTAssertTrue(merged.notes.contains(linked.notes))
    XCTAssertTrue(merged.notes.contains(linked.title))
    XCTAssertTrue(merged.notes.contains(linked.placeName!))
    XCTAssertTrue(merged.notes.contains("시간:"))
    XCTAssertTrue(merged.notes.contains("별도 세트로 보존"))
    XCTAssertEqual(merged.exercises[0].sets.map(\.repetitions), [10, 12, 20])
    XCTAssertEqual(Set(merged.exercises[0].sets.map(\.id)).count, 3)
    XCTAssertTrue(merged.watchSourceIDs?.contains(linked.id) == true)
    XCTAssertNotNil(merged.healthExportMessage)
    XCTAssertEqual(RecordStore(directory: directory).records, [merged])
    // Retry, reattachment, and importing the old second record must all remain idempotent.
    XCTAssertEqual(try store.completeHealthExport(localID: original.id, healthWorkoutID: healthID), merged)
    XCTAssertEqual(try store.recordForHealthAttachment(
      healthSummary(original, healthID: healthID, exportedLocalID: original.id)), merged)
    try store.importData(JSONEncoder().encode(RecordArchive(records: [linked])))
    XCTAssertEqual(store.records, [merged])
  }

  func testHealthAttachmentPrefersOriginalOverAlreadySavedLink() throws {
    let store = RecordStore(directory: try directory())
    let original = workout()
    var linked = workout(origin: .healthLink)
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    linked.notes = "연결 기록 메모"
    try store.save(linked)
    try store.save(original)
    let summary = healthSummary(original, healthID: try XCTUnwrap(linked.healthWorkoutID), exportedLocalID: original.id)

    let attached = try store.recordForHealthAttachment(summary)

    XCTAssertEqual(attached.id, original.id)
    XCTAssertEqual(store.records.count, 1)
    XCTAssertTrue(attached.notes.contains(linked.notes))
    var staleEdit = linked
    staleEdit.notes = "이전 연결 기록 화면에서 저장한 메모"
    XCTAssertThrowsError(try store.saveEdited(staleEdit, original: linked)) { error in
      guard case RecordHealthLinkError.recordMergedDuringEdit = error else {
        return XCTFail("Expected an explicit stale editor conflict, received \(error)")
      }
    }
    XCTAssertEqual(store.records, [attached])
  }

  func testStaleOriginalEditorCannotDeleteExerciseChangedByHealthMerge() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    var original = workout()
    original.exercises = [ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 10)])]
    var linked = original
    linked.id = UUID()
    linked.origin = .healthLink
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    linked.exercises[0].sets[0].repetitions = 12
    linked.exercises[0].sets.append(ExerciseSet(repetitions: 20))
    try store.save(original)
    try store.save(linked)
    var staleDraft = original
    staleDraft.exercises = []
    staleDraft.notes = "아직 저장하지 않은 수정"
    let merged = try XCTUnwrap(store.completeHealthExport(localID: original.id,
      healthWorkoutID: try XCTUnwrap(linked.healthWorkoutID)))
    let before = try store.exportData()

    XCTAssertThrowsError(try store.saveEdited(staleDraft, original: original)) { error in
      guard case RecordHealthLinkError.exerciseChangedDuringEdit = error else {
        return XCTFail("Expected a changed exercise deletion conflict, received \(error)")
      }
    }

    XCTAssertEqual(merged.exercises[0].sets.map(\.repetitions), [10, 12, 20])
    XCTAssertEqual(store.records, [merged])
    XCTAssertEqual(try store.exportData(), before)
    XCTAssertEqual(RecordStore(directory: directory).records, [merged])
  }

  func testEditorCanDeleteUnchangedExerciseWhileKeepingOtherConcurrentChanges() throws {
    let store = RecordStore(directory: try directory())
    var original = workout()
    original.exercises = [ExerciseEntry(name: "삭제할 운동"), ExerciseEntry(name: "보존할 운동")]
    try store.save(original)
    var latest = original
    latest.exercises[1].sets.append(ExerciseSet(repetitions: 15))
    latest.exercises.append(ExerciseEntry(name: "나중에 추가된 운동"))
    try store.save(latest)
    var draft = original
    let temporary = ExerciseEntry(name: "편집 중 추가했다 삭제한 운동")
    draft.exercises.append(temporary)
    draft.exercises.removeAll { $0.id == temporary.id || $0.id == original.exercises[0].id }

    try store.saveEdited(draft, original: original)

    XCTAssertEqual(store.records[0].exercises, Array(latest.exercises.dropFirst()))
  }

  func testStaleEditorCannotDeleteOrOverwriteConcurrentlyChangedSet() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    var original = workout()
    original.exercises = [ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 10)])]
    try store.save(original)
    var latest = original
    latest.exercises[0].sets[0].repetitions = 12
    try store.save(latest)
    let before = try store.exportData()
    var deleted = original
    deleted.exercises[0].sets = []
    var changed = original
    changed.exercises[0].sets[0].repetitions = 15
    changed.notes = "충돌 시 함께 저장되면 안 되는 수정"

    for draft in [deleted, changed] {
      XCTAssertThrowsError(try store.saveEdited(draft, original: original)) { error in
        guard case RecordHealthLinkError.exerciseSetChangedDuringEdit = error else {
          return XCTFail("Expected a changed set conflict, received \(error)")
        }
      }
      XCTAssertEqual(store.records, [latest])
      XCTAssertEqual(try store.exportData(), before)
    }
    XCTAssertEqual(RecordStore(directory: directory).records, [latest])
    var matching = original
    matching.exercises[0].sets[0].repetitions = 12
    try store.saveEdited(matching, original: original)
    XCTAssertEqual(store.records[0].exercises, latest.exercises)
  }

  func testStaleEditorCannotResurrectConcurrentlyDeletedExercise() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    var original = workout()
    original.exercises = [ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 10)])]
    try store.save(original)
    var latest = original
    latest.exercises = []
    try store.save(latest)
    let before = try store.exportData()
    var renamed = original
    renamed.exercises[0].name = "평행봉"
    var changedSet = original
    changedSet.exercises[0].sets[0].repetitions = 15

    for draft in [renamed, changedSet] {
      XCTAssertThrowsError(try store.saveEdited(draft, original: original)) { error in
        guard case RecordHealthLinkError.exerciseChangedDuringEdit = error else {
          return XCTFail("Expected a deleted exercise conflict, received \(error)")
        }
      }
      XCTAssertEqual(store.records, [latest])
      XCTAssertEqual(try store.exportData(), before)
    }
    XCTAssertEqual(RecordStore(directory: directory).records, [latest])
    var alsoDeleted = original
    alsoDeleted.exercises = []
    try store.saveEdited(alsoDeleted, original: original)
    XCTAssertTrue(store.records[0].exercises.isEmpty)
  }

  func testExerciseNameConflictRejectsDifferentEditAndAllowsMatchingName() throws {
    let store = RecordStore(directory: try directory())
    var original = workout()
    original.exercises = [ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 10)])]
    try store.save(original)
    var latest = original
    latest.exercises[0].name = "최신 이름"
    latest.exercises[0].sets.append(ExerciseSet(repetitions: 20))
    try store.save(latest)
    let before = try store.exportData()
    var draft = original
    draft.exercises[0].name = "다른 이름"
    draft.notes = "충돌 시 함께 저장되면 안 되는 수정"

    XCTAssertThrowsError(try store.saveEdited(draft, original: original)) { error in
      guard case RecordHealthLinkError.exerciseChangedDuringEdit = error else {
        return XCTFail("Expected a changed exercise name conflict, received \(error)")
      }
    }
    XCTAssertEqual(store.records, [latest])
    XCTAssertEqual(try store.exportData(), before)
    draft.exercises[0].name = latest.exercises[0].name
    try store.saveEdited(draft, original: original)
    XCTAssertEqual(store.records[0].exercises, latest.exercises)
  }

  func testConcurrentExerciseAdditionRequiresMatchingContentsForSameID() throws {
    let store = RecordStore(directory: try directory())
    let original = workout()
    try store.save(original)
    let added = ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 10)])
    var latest = original
    latest.exercises.append(added)
    try store.save(latest)
    let before = try store.exportData()
    var draft = original
    draft.exercises.append(added)
    draft.exercises[draft.exercises.count - 1].name = "다른 이름"

    XCTAssertThrowsError(try store.saveEdited(draft, original: original)) { error in
      guard case RecordHealthLinkError.exerciseChangedDuringEdit = error else {
        return XCTFail("Expected a conflicting exercise addition, received \(error)")
      }
    }
    XCTAssertEqual(store.records, [latest])
    XCTAssertEqual(try store.exportData(), before)
    draft.exercises[draft.exercises.count - 1] = added
    try store.saveEdited(draft, original: original)
    XCTAssertEqual(store.records[0].exercises, latest.exercises)
    let independent = ExerciseEntry(name: "평행봉")
    draft.exercises.append(independent)
    try store.saveEdited(draft, original: original)
    XCTAssertEqual(store.records[0].exercises, latest.exercises + [independent])
  }

  func testSetEditsKeepIndependentConcurrentChangesAndNewMergedSetIDs() throws {
    let store = RecordStore(directory: try directory())
    var original = workout()
    original.exercises = [ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 10),
      ExerciseSet(repetitions: 20), ExerciseSet(repetitions: 30)])]
    try store.save(original)
    var latest = original
    latest.exercises[0].sets[1].repetitions = 25
    let mergedSet = ExerciseSet(repetitions: 40)
    latest.exercises[0].sets.append(mergedSet)
    try store.save(latest)
    var draft = original
    draft.exercises[0].sets[0].repetitions = 15
    draft.exercises[0].sets.removeLast()

    try store.saveEdited(draft, original: original)

    XCTAssertEqual(store.records[0].exercises[0].sets.map(\.repetitions), [15, 25, 40])
    XCTAssertEqual(store.records[0].exercises[0].sets.last, mergedSet)
  }

  func testStaleSetEditCannotResurrectAConcurrentlyDeletedSet() throws {
    let store = RecordStore(directory: try directory())
    var original = workout()
    original.exercises = [ExerciseEntry(name: "철봉", sets: [ExerciseSet(repetitions: 10)])]
    try store.save(original)
    var latest = original
    latest.exercises[0].sets = []
    try store.save(latest)
    var draft = original
    draft.exercises[0].sets[0].repetitions = 15

    XCTAssertThrowsError(try store.saveEdited(draft, original: original))
    XCTAssertEqual(store.records, [latest])
    draft.exercises[0].sets = []
    try store.saveEdited(draft, original: original)
    XCTAssertTrue(store.records[0].exercises[0].sets.isEmpty)
  }

  func testHealthMergeCapacityFailureLeavesBothRecordsAndArchiveUntouched() throws {
    let directory = try directory()
    let store = RecordStore(directory: directory)
    var original = workout()
    original.notes = String(repeating: "a", count: 6_000)
    var linked = workout(origin: .healthLink)
    linked.notes = String(repeating: "b", count: 6_000)
    linked.healthWorkoutID = UUID()
    linked.healthExportState = .saved
    try store.save(original)
    try store.save(linked)
    let before = try store.exportData()

    XCTAssertThrowsError(try store.completeHealthExport(localID: original.id,
      healthWorkoutID: try XCTUnwrap(linked.healthWorkoutID))) { error in
      guard case RecordHealthLinkError.cannotPreserveAnnotations = error else {
        return XCTFail("Expected a non-destructive annotation limit error, received \(error)")
      }
    }
    XCTAssertEqual(try store.exportData(), before)
    XCTAssertEqual(RecordStore(directory: directory).records, store.records)
  }

  func testHealthReconciliationRejectsConflictingExistingIdentity() throws {
    let store = RecordStore(directory: try directory())
    var original = workout()
    original.healthWorkoutID = UUID()
    original.healthExportState = .saved
    try store.save(original)
    let before = try store.exportData()
    XCTAssertThrowsError(try store.recordForHealthAttachment(
      healthSummary(original, healthID: UUID(), exportedLocalID: original.id)))
    XCTAssertEqual(try store.exportData(), before)
  }

  func testLateHealthCompletionCannotResurrectADeletedRecord() throws {
    let store = RecordStore(directory: try directory())
    let original = workout()
    try store.save(original)
    try store.remove(original.id)
    let before = try store.exportData()
    XCTAssertNil(try store.completeHealthExport(localID: original.id, healthWorkoutID: UUID()))
    XCTAssertEqual(try store.exportData(), before)
  }

  func testHealthAttachmentWithoutExportIdentityDoesNotGuessFromMatchingContent() throws {
    let store = RecordStore(directory: try directory())
    let original = workout()
    try store.save(original)
    let draft = try store.recordForHealthAttachment(healthSummary(original, healthID: UUID()))
    XCTAssertNotEqual(draft.id, original.id)
    XCTAssertEqual(draft.origin, .healthLink)
    XCTAssertEqual(store.records, [original])
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
