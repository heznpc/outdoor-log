import Foundation
import Observation

struct RecordArchive: Codable {
  var version = 1
  var records: [PersonalWorkout] = []
  // Remember explicitly deleted Watch deliveries so a delayed retry cannot resurrect them.
  var deletedIDs: Set<UUID> = []
  // Optional so archives written before Health-linked deletion tracking remain readable.
  var deletedHealthIDs: Set<UUID>? = nil
}

@MainActor @Observable
final class RecordStore {
  private(set) var records: [PersonalWorkout] = []
  private(set) var ready = false
  var notice: String?
  private var deletedIDs: Set<UUID> = []
  private var deletedHealthIDs: Set<UUID> = []
  private var file: URL?
  private let suppliedDirectory: URL?
  private let maximumArchiveBytes: Int

  init(directory: URL? = nil, maximumArchiveBytes: Int = 25_000_000) {
    suppliedDirectory = directory
    self.maximumArchiveBytes = maximumArchiveBytes
    reload()
  }

  func reload() {
    ready = false
    do {
      let directory = try suppliedDirectory ?? ProtectedFile.directory()
      let url = directory.appendingPathComponent("personal-workouts.json")
      file = url
      if FileManager.default.fileExists(atPath: url.path) {
        let data = try Data(contentsOf: url)
        guard data.count <= maximumArchiveBytes else { throw LocalDataError.unreadable }
        let archive = try JSONDecoder().decode(RecordArchive.self, from: data)
        try Self.validate(archive)
        records = archive.records.sorted { $0.startedAt > $1.startedAt }
        deletedIDs = archive.deletedIDs
        deletedHealthIDs = archive.deletedHealthIDs ?? []
      } else {
        records = []
        deletedIDs = []
        deletedHealthIDs = []
      }
      ready = true
      notice = nil
    } catch {
      notice = "기록을 열지 못했습니다. 저장 파일을 덮어쓰지 않습니다. \(error.localizedDescription)"
    }
  }

  func save(_ record: PersonalWorkout) throws {
    try record.validate()
    var next = records
    if let index = next.firstIndex(where: { $0.id == record.id }) { next[index] = record }
    else { next.append(record) }
    var tombstones = deletedIDs
    tombstones.remove(record.id)
    tombstones.subtract(record.watchSourceIDs ?? [])
    var healthTombstones = deletedHealthIDs
    if let id = record.healthWorkoutID { healthTombstones.remove(id) }
    try persist(next, deleted: tombstones, deletedHealth: healthTombstones)
  }

  func saveEdited(_ draft: PersonalWorkout, original: PersonalWorkout) throws {
    var edited = draft
    let latest = records.first(where: {
      $0.id == draft.id || ($0.watchSourceIDs?.contains(draft.id) ?? false)
        || (draft.healthWorkoutID != nil && $0.healthWorkoutID == draft.healthWorkoutID)
    })
    if let latest {
      // The absorbed record can have conflicting field/ID variants preserved in the
      // survivor. Ask the stale editor to reopen that result before choosing values.
      guard latest.id == draft.id else { throw RecordHealthLinkError.recordMergedDuringEdit }
      // Apply only fields the user changed; keep asynchronous metadata and new
      // Watch annotations that arrived while this editor was open.
      edited = latest
      if draft.title != original.title { edited.title = draft.title }
      if draft.kind != original.kind { edited.kind = draft.kind }
      if draft.startedAt != original.startedAt || draft.endedAt != original.endedAt
        || draft.activeDurationSeconds != original.activeDurationSeconds || draft.pauses != original.pauses {
        edited.startedAt = draft.startedAt
        edited.endedAt = draft.endedAt
        edited.activeDurationSeconds = draft.activeDurationSeconds
        edited.pauses = draft.pauses
        edited.timingEditedLocally = true
      }
      if draft.placeID != original.placeID || draft.placeName != original.placeName {
        edited.placeID = draft.placeID
        edited.placeName = draft.placeName
      }
      if draft.notes != original.notes {
        edited.notes = latest.notes == original.notes || latest.notes == draft.notes
          ? draft.notes : Self.combinedNotes(draft.notes, latest.notes)
      }
      if draft.exercises != original.exercises {
        edited.exercises = try Self.applyExerciseEdits(draft.exercises, original: original.exercises, latest: latest.exercises)
      }
      edited.modifiedAt = draft.modifiedAt
    } else if deletedIDs.contains(draft.id) {
      throw LocalDataError.invalidRecord
    }
    if latest == nil || draft.startedAt != original.startedAt || draft.endedAt != original.endedAt {
      try edited.validateNewTiming()
    }
    try save(edited)
  }

  func remove(_ id: UUID) throws {
    var tombstones = deletedIDs
    var healthTombstones = deletedHealthIDs
    tombstones.insert(id)
    if let record = records.first(where: { $0.id == id }) {
      tombstones.formUnion(record.watchSourceIDs ?? [])
      if let healthID = record.healthWorkoutID { healthTombstones.insert(healthID) }
    }
    try persist(records.filter { $0.id != id }, deleted: tombstones, deletedHealth: healthTombstones)
  }

  func hasDurableRecordOrDeletion(_ id: UUID) -> Bool {
    ready && (deletedIDs.contains(id) || records.contains { $0.id == id })
  }

  func recordForHealthAttachment(_ workout: HealthWorkoutSummary) throws -> PersonalWorkout {
    guard ready else { throw LocalDataError.storageUnavailable }
    // A successful Health write may outlive the callback that would have stored its UUID.
    // The trusted export identity takes precedence over a separately created Health link.
    if let localID = workout.exportedLocalID,
      let original = records.first(where: { $0.id == localID }),
      let reconciled = try completeHealthExport(localID: original.id, healthWorkoutID: workout.id) {
      return reconciled
    }
    if let existing = records.first(where: { $0.healthWorkoutID == workout.id }) { return existing }
    return PersonalWorkout(title: workout.title, kind: workout.kind,
      startedAt: workout.startedAt, endedAt: workout.endedAt,
      activeDurationSeconds: workout.duration, pauses: workout.pauses,
      healthWorkoutID: workout.id, healthExportState: .saved, origin: .healthLink)
  }

  @discardableResult
  func completeHealthExport(localID: UUID, healthWorkoutID: UUID) throws -> PersonalWorkout? {
    guard ready else { throw LocalDataError.storageUnavailable }
    // A late callback cannot recreate a record the user has deleted.
    guard var original = records.first(where: { $0.id == localID }) else { return nil }
    guard original.origin == .phone,
      original.healthWorkoutID == nil || original.healthWorkoutID == healthWorkoutID
    else { throw RecordHealthLinkError.conflictingIdentity }
    let linked = records.first { $0.id != original.id && $0.healthWorkoutID == healthWorkoutID }
    if let linked {
      guard linked.origin == .healthLink else { throw RecordHealthLinkError.conflictingIdentity }
      Self.mergeAnnotations(from: linked, into: &original, preserveConflicts: true)
      // Retain absorbed IDs like the existing Watch/Health merge, so stale editors
      // and backup imports cannot reintroduce the second local record.
      original.watchSourceIDs = (original.watchSourceIDs ?? [])
        .union(linked.watchSourceIDs ?? []).union([linked.id])
      original.healthExportMessage = "같은 건강 운동의 개인 기록을 합쳤습니다. 서로 다른 값은 메모 또는 별도 운동 항목·세트에 함께 보존했습니다."
    } else if original.healthExportState != .saved {
      original.healthExportMessage = nil
    }
    original.healthWorkoutID = healthWorkoutID
    original.healthExportState = .saved
    // Fail before changing either record if preserving annotations exceeds a record limit.
    do { try original.validate() }
    catch { throw RecordHealthLinkError.cannotPreserveAnnotations }
    let next = records.filter { $0.id != original.id && $0.id != linked?.id } + [original]
    try persist(next, deleted: deletedIDs)
    return original
  }

  // The acknowledgement is allowed only after a durable write, or a previously
  // durable record/tombstone. Repeated transfers never overwrite personal edits.
  func acceptWatch(_ record: PersonalWorkout) -> Bool {
    guard ready else { return false }
    do {
      try record.validate()
      guard record.origin == .watch else { throw LocalDataError.invalidRecord }
      if deletedIDs.contains(record.id) {
        // The first delivery may have failed to save Health data. A later
        // delivery can reveal its UUID after the local record was deleted.
        if let healthID = record.healthWorkoutID, !deletedHealthIDs.contains(healthID),
          !records.contains(where: { $0.healthWorkoutID == healthID }) {
          try persist(records, deleted: deletedIDs, deletedHealth: deletedHealthIDs.union([healthID]))
        }
        return true
      }
      let direct = records.first { $0.id == record.id || ($0.watchSourceIDs?.contains(record.id) ?? false) }
      if record.healthWorkoutID.map({ deletedHealthIDs.contains($0) }) == true {
        if let direct {
          guard direct.origin != .phone else { throw RecordHealthLinkError.conflictingIdentity }
          // Deleting a separate Health link is not permission to remove a
          // surviving Watch record or to reattach that deleted Health identity.
          return true
        }
        // A delayed older payload may not know its Health UUID yet. Remember
        // the delivery ID before ACK so that payload also stays deleted.
        try persist(records, deleted: deletedIDs.union([record.id]).union(record.watchSourceIDs ?? []))
        return true
      }
      let linked = records.first { record.healthWorkoutID != nil && $0.healthWorkoutID == record.healthWorkoutID }
      // A retry may fill an absent Health UUID, but it cannot change an already
      // committed identity or claim an independently recorded phone workout.
      if let direct, let storedID = direct.healthWorkoutID, let incomingID = record.healthWorkoutID,
        storedID != incomingID { throw RecordHealthLinkError.conflictingIdentity }
      guard direct?.origin != .phone, linked?.origin != .phone else {
        throw RecordHealthLinkError.conflictingIdentity
      }
      if var merged = direct ?? linked {
        let firstAttachment = merged.origin == .healthLink
        let needsRecoveredTiming = merged.healthWorkoutID == nil && record.healthWorkoutID != nil
        var sourceIDs = merged.watchSourceIDs ?? []
        sourceIDs.insert(record.id)
        if let linked, linked.id != merged.id {
          // A delayed Health UUID can reveal two already stored views of one workout.
          sourceIDs.insert(linked.id)
          sourceIDs.formUnion(linked.watchSourceIDs ?? [])
          Self.mergeAnnotations(from: linked, into: &merged, preserveConflicts: true)
        } else if firstAttachment {
          Self.mergeAnnotations(from: record, into: &merged)
        }
        merged.watchSourceIDs = sourceIDs
        merged.origin = .watch
        if let healthID = record.healthWorkoutID {
          if needsRecoveredTiming && merged.timingEditedLocally != true {
            merged.startedAt = record.startedAt
            merged.endedAt = record.endedAt
            merged.activeDurationSeconds = record.activeDurationSeconds
            merged.pauses = record.pauses
          }
          merged.healthWorkoutID = healthID
          if merged.healthExportState != .saved || record.healthExportMessage != nil {
            merged.healthExportMessage = record.healthExportMessage
          }
          merged.healthExportState = .saved
        }
        var next = records.filter { $0.id != merged.id && $0.id != linked?.id }
        next.append(merged)
        try persist(next, deleted: deletedIDs)
        return true
      }
      try save(record)
      return true
    } catch {
      notice = "Watch의 기록을 기기에 저장하지 못했습니다. Watch에 원본을 유지합니다. \(error.localizedDescription)"
      return false
    }
  }

  func exportData() throws -> Data {
    guard ready else { throw LocalDataError.unreadable }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(RecordArchive(records: records, deletedIDs: deletedIDs, deletedHealthIDs: deletedHealthIDs))
  }

  func importData(_ data: Data) throws {
    guard ready, data.count <= maximumArchiveBytes else { throw LocalDataError.unreadable }
    let incoming = try JSONDecoder().decode(RecordArchive.self, from: data)
    try Self.validate(incoming)
    // Import adds missing records only. It never deletes or replaces existing edits.
    let known = Set(records.map(\.id)).union(deletedIDs).union(records.flatMap { $0.watchSourceIDs ?? [] })
    let knownHealthIDs = Set(records.compactMap(\.healthWorkoutID))
    var additions = incoming.records.filter {
      known.isDisjoint(with: ($0.watchSourceIDs ?? []).union([$0.id]))
        && ($0.healthWorkoutID.map { !knownHealthIDs.contains($0) && !deletedHealthIDs.contains($0) } ?? true)
    }
    for index in additions.indices {
      // An imported pending export is uncertain, not proof of a successful write.
      if additions[index].healthExportState == .pending {
        additions[index].healthExportState = .failed
        additions[index].healthExportMessage = "이전 저장 결과를 다시 확인해야 합니다."
      }
    }
    let keptRecords = records + additions
    let keptIDs = Set(keptRecords.flatMap { ($0.watchSourceIDs ?? []).union([$0.id]) })
    // Restore deletion history without deleting records already alive on this device.
    let restoredDeletions = deletedIDs.union(incoming.deletedIDs.subtracting(keptIDs))
    let keptHealthIDs = Set(keptRecords.compactMap(\.healthWorkoutID))
    let restoredHealthDeletions = deletedHealthIDs.union((incoming.deletedHealthIDs ?? []).subtracting(keptHealthIDs))
    try persist(keptRecords, deleted: restoredDeletions, deletedHealth: restoredHealthDeletions)
  }

  // Recovery is an explicit replacement action available only when the current
  // archive cannot be opened. Keep its bytes before writing the validated backup.
  func restoreUnreadableArchive(from data: Data) throws {
    guard !ready, let file, data.count <= maximumArchiveBytes else { throw LocalDataError.unreadable }
    var archive = try JSONDecoder().decode(RecordArchive.self, from: data)
    try Self.validate(archive)
    for index in archive.records.indices where archive.records[index].healthExportState == .pending {
      archive.records[index].healthExportState = .failed
      archive.records[index].healthExportMessage = "이전 저장 결과를 다시 확인해야 합니다."
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let restored = try encoder.encode(archive)
    guard restored.count <= maximumArchiveBytes else { throw LocalDataError.archiveTooLarge }
    // A missing/inaccessible original is a storage problem; retry opening it
    // instead of treating its absence as permission to replace another archive.
    guard FileManager.default.fileExists(atPath: file.path) else { throw LocalDataError.storageUnavailable }
    let preserved = file.deletingLastPathComponent()
      .appendingPathComponent("personal-workouts-unreadable-\(UUID().uuidString).json")
    try FileManager.default.copyItem(at: file, to: preserved)
    try ProtectedFile.writeData(restored, to: file)
    records = archive.records.sorted { $0.startedAt > $1.startedAt }
    deletedIDs = archive.deletedIDs
    deletedHealthIDs = archive.deletedHealthIDs ?? []
    ready = true
    notice = nil
  }

  private func persist(_ next: [PersonalWorkout], deleted: Set<UUID>, deletedHealth: Set<UUID>? = nil) throws {
    guard ready, let file else { throw LocalDataError.storageUnavailable }
    let healthDeletions = deletedHealth ?? deletedHealthIDs
    let archive = RecordArchive(records: next, deletedIDs: deleted, deletedHealthIDs: healthDeletions)
    try Self.validate(archive)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(archive)
    guard data.count <= maximumArchiveBytes else { throw LocalDataError.archiveTooLarge }
    try ProtectedFile.writeData(data, to: file)
    records = next.sorted { $0.startedAt > $1.startedAt }
    deletedIDs = deleted
    deletedHealthIDs = healthDeletions
    notice = nil
  }

  private static func validate(_ archive: RecordArchive) throws {
    guard archive.version == 1 else { throw LocalDataError.unsupportedVersion }
    guard archive.records.count <= 50_000, archive.deletedIDs.count <= 100_000,
      (archive.deletedHealthIDs?.count ?? 0) <= 100_000,
      Set(archive.records.map(\.id)).count == archive.records.count,
      archive.records.allSatisfy({ !archive.deletedIDs.contains($0.id) })
    else { throw LocalDataError.invalidRecord }
    let healthIDs = archive.records.compactMap(\.healthWorkoutID)
    guard Set(healthIDs).count == healthIDs.count,
      (archive.deletedHealthIDs ?? []).isDisjoint(with: healthIDs) else { throw LocalDataError.invalidRecord }
    var ownedIDs = Set<UUID>()
    for record in archive.records {
      let identifiers = (record.watchSourceIDs ?? []).union([record.id])
      guard ownedIDs.isDisjoint(with: identifiers), archive.deletedIDs.isDisjoint(with: identifiers)
      else { throw LocalDataError.invalidRecord }
      ownedIDs.formUnion(identifiers)
    }
    for record in archive.records { try record.validate() }
  }

  private static func combinedNotes(_ first: String, _ second: String) -> String {
    if first.isEmpty { return second }
    if second.isEmpty || first == second { return first }
    return first + "\n\n함께 보존한 메모:\n" + second
  }

  private static func mergeAnnotations(from source: PersonalWorkout, into target: inout PersonalWorkout,
    preserveConflicts: Bool = false) {
    var notes = source.notes
    if preserveConflicts {
      var conflicts: [String] = []
      if source.title != target.title { conflicts.append("제목: \(source.title)") }
      if source.kind != target.kind { conflicts.append("종류: \(source.kind.title)") }
      if source.startedAt != target.startedAt || source.endedAt != target.endedAt || source.duration != target.duration {
        conflicts.append("시간: \(source.startedAt.ISO8601Format()) ~ \(source.endedAt.ISO8601Format()), 활동 \(source.duration)초")
      }
      if source.pauses != target.pauses && !source.pauses.isEmpty {
        conflicts.append("일시정지: " + source.pauses.map { "\($0.startedAt.ISO8601Format()) ~ \($0.endedAt.ISO8601Format())" }.joined(separator: ", "))
      }
      let targetHasPlace = target.placeID != nil || target.placeName != nil
      if targetHasPlace, (source.placeID != target.placeID || source.placeName != target.placeName),
        (source.placeID != nil || source.placeName != nil) {
        conflicts.append("장소: \(source.placeName ?? "이름 없음") (ID: \(source.placeID ?? "없음"))")
      }
      if !targetHasPlace { target.placeID = source.placeID; target.placeName = source.placeName }
      for exercise in source.exercises {
        guard let index = target.exercises.firstIndex(where: { $0.id == exercise.id }) else {
          target.exercises.append(exercise)
          continue
        }
        if target.exercises[index].name != exercise.name {
          var alternative = exercise
          alternative.id = UUID()
          target.exercises.append(alternative)
          conflicts.append("운동 항목 이름이 달라 별도 항목으로 보존: \(exercise.name)")
          continue
        }
        for set in exercise.sets {
          if let existing = target.exercises[index].sets.first(where: { $0.id == set.id }) {
            if existing != set {
              var alternative = set
              alternative.id = UUID()
              target.exercises[index].sets.append(alternative)
              conflicts.append("\(exercise.name): 같은 세트의 다른 수치를 별도 세트로 보존")
            }
          } else { target.exercises[index].sets.append(set) }
        }
      }
      if !conflicts.isEmpty { notes = combinedNotes(notes, "병합한 다른 개인 기록의 값:\n" + conflicts.joined(separator: "\n")) }
    } else {
      if target.placeID == nil && target.placeName == nil {
        target.placeID = source.placeID
        target.placeName = source.placeName
      } else if (source.placeID != nil || source.placeName != nil),
        (source.placeID != target.placeID || source.placeName != target.placeName) {
        notes = combinedNotes(notes, "Watch에서 함께 보존한 장소: \(source.placeName ?? "이름 없음") (ID: \(source.placeID ?? "없음"))")
      }
      // A Health link restored from an archive may already contain the same
      // exercise IDs. Retain additional and conflicting sets on first delivery.
      for exercise in source.exercises {
        guard let index = target.exercises.firstIndex(where: { $0.id == exercise.id }) else {
          target.exercises.append(exercise)
          continue
        }
        if target.exercises[index].name != exercise.name {
          var alternative = exercise
          alternative.id = UUID()
          target.exercises.append(alternative)
          continue
        }
        for set in exercise.sets {
          if let existing = target.exercises[index].sets.first(where: { $0.id == set.id }) {
            if existing != set {
              var alternative = set
              alternative.id = UUID()
              target.exercises[index].sets.append(alternative)
            }
          } else { target.exercises[index].sets.append(set) }
        }
      }
    }
    target.notes = combinedNotes(target.notes, notes)
  }

  private static func applyExerciseEdits(_ draft: [ExerciseEntry], original: [ExerciseEntry], latest: [ExerciseEntry]) throws -> [ExerciseEntry] {
    let removedIDs = Set(original.map(\.id)).subtracting(draft.map(\.id))
    // An older editor has not shown sets or alternatives merged into this item.
    // Reject its deletion before saving any field, rather than discard those values.
    for baseline in original where removedIDs.contains(baseline.id) {
      if let current = latest.first(where: { $0.id == baseline.id }), current != baseline {
        throw RecordHealthLinkError.exerciseChangedDuringEdit
      }
    }
    var result = latest.filter { !removedIDs.contains($0.id) }
    for entry in draft {
      guard let baseline = original.first(where: { $0.id == entry.id }) else {
        if let current = result.first(where: { $0.id == entry.id }) {
          guard current == entry else { throw RecordHealthLinkError.exerciseChangedDuringEdit }
        } else { result.append(entry) }
        continue
      }
      guard entry != baseline else { continue }
      guard let index = result.firstIndex(where: { $0.id == entry.id }) else {
        throw RecordHealthLinkError.exerciseChangedDuringEdit
      }
      if entry.name != baseline.name {
        guard result[index].name == baseline.name || result[index].name == entry.name else {
          throw RecordHealthLinkError.exerciseChangedDuringEdit
        }
        result[index].name = entry.name
      }
      let removedSets = Set(baseline.sets.map(\.id)).subtracting(entry.sets.map(\.id))
      for baselineSet in baseline.sets where removedSets.contains(baselineSet.id) {
        if let current = result[index].sets.first(where: { $0.id == baselineSet.id }), current != baselineSet {
          throw RecordHealthLinkError.exerciseSetChangedDuringEdit
        }
      }
      result[index].sets.removeAll { removedSets.contains($0.id) }
      for set in entry.sets where baseline.sets.first(where: { $0.id == set.id }) != set {
        let baselineSet = baseline.sets.first(where: { $0.id == set.id })
        let current = result[index].sets.first(where: { $0.id == set.id })
        // A concurrent deletion also differs from the baseline. Matching edits
        // are safe; different values must be reviewed before either is discarded.
        guard current == baselineSet || current == set else {
          throw RecordHealthLinkError.exerciseSetChangedDuringEdit
        }
        if let setIndex = result[index].sets.firstIndex(where: { $0.id == set.id }) { result[index].sets[setIndex] = set }
        else { result[index].sets.append(set) }
      }
    }
    return result
  }
}

enum RecordHealthLinkError: LocalizedError {
  case conflictingIdentity, cannotPreserveAnnotations, recordMergedDuringEdit, exerciseChangedDuringEdit, exerciseSetChangedDuringEdit

  var errorDescription: String? {
    switch self {
    case .conflictingIdentity:
      return "서로 다른 개인 기록의 건강 연결이 충돌해 자동으로 합치지 않았습니다. 기존 기록은 모두 유지했습니다."
    case .cannotPreserveAnnotations:
      return "합칠 메모나 운동 항목이 보관 한도를 넘었습니다. 두 기록을 그대로 유지했으니 내보낸 뒤 내용을 정리해 주세요."
    case .recordMergedDuringEdit:
      return "편집 중 이 기록이 다른 개인 기록과 합쳐졌습니다. 입력 중인 내용을 복사해 둔 뒤 편집을 닫고, 합쳐진 기록을 다시 열어 수정해 주세요. 기존 저장 내용은 변경하지 않았습니다."
    case .exerciseChangedDuringEdit:
      return "추가·수정·삭제하려는 운동 항목이 편집 중 변경되었거나 삭제되었습니다. 입력 중인 내용을 복사해 둔 뒤 편집을 닫고, 최신 기록을 다시 열어 확인해 주세요. 기존 저장 내용은 변경하지 않았습니다."
    case .exerciseSetChangedDuringEdit:
      return "삭제하거나 수정하려는 세트가 편집 중 변경되었습니다. 입력 중인 내용을 복사해 둔 뒤 편집을 닫고, 최신 기록의 세트를 확인해 주세요. 기존 저장 내용은 변경하지 않았습니다."
    }
  }
}
