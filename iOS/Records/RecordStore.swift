import Foundation
import Observation

struct RecordArchive: Codable {
  var version = 1
  var records: [PersonalWorkout] = []
  // Remember explicitly deleted Watch deliveries so a delayed retry cannot resurrect them.
  var deletedIDs: Set<UUID> = []
}

@MainActor @Observable
final class RecordStore {
  private(set) var records: [PersonalWorkout] = []
  private(set) var ready = false
  var notice: String?
  private var deletedIDs: Set<UUID> = []
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
      } else {
        records = []
        deletedIDs = []
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
    try persist(next, deleted: tombstones)
  }

  func saveEdited(_ draft: PersonalWorkout, original: PersonalWorkout) throws {
    var edited = draft
    if let latest = records.first(where: {
      $0.id == draft.id || ($0.watchSourceIDs?.contains(draft.id) ?? false)
        || (draft.healthWorkoutID != nil && $0.healthWorkoutID == draft.healthWorkoutID)
    }) {
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
        edited.exercises = Self.applyExerciseEdits(draft.exercises, original: original.exercises, latest: latest.exercises)
      }
      edited.modifiedAt = draft.modifiedAt
    } else if deletedIDs.contains(draft.id) {
      throw LocalDataError.invalidRecord
    }
    try save(edited)
  }

  func remove(_ id: UUID) throws {
    var tombstones = deletedIDs
    tombstones.insert(id)
    if let record = records.first(where: { $0.id == id }) {
      tombstones.formUnion(record.watchSourceIDs ?? [])
    }
    try persist(records.filter { $0.id != id }, deleted: tombstones)
  }

  func hasDurableRecordOrDeletion(_ id: UUID) -> Bool {
    ready && (deletedIDs.contains(id) || records.contains { $0.id == id })
  }

  // The acknowledgement is allowed only after a durable write, or a previously
  // durable record/tombstone. Repeated transfers never overwrite personal edits.
  func acceptWatch(_ record: PersonalWorkout) -> Bool {
    guard ready else { return false }
    do {
      try record.validate()
      guard record.origin == .watch else { throw LocalDataError.invalidRecord }
      if deletedIDs.contains(record.id) { return true }
      let direct = records.first { $0.id == record.id || ($0.watchSourceIDs?.contains(record.id) ?? false) }
      let linked = records.first { record.healthWorkoutID != nil && $0.healthWorkoutID == record.healthWorkoutID }
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
          merged.healthExportState = .saved
          merged.healthExportMessage = nil
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
    return try encoder.encode(RecordArchive(records: records, deletedIDs: deletedIDs))
  }

  func importData(_ data: Data) throws {
    guard ready, data.count <= maximumArchiveBytes else { throw LocalDataError.unreadable }
    let incoming = try JSONDecoder().decode(RecordArchive.self, from: data)
    try Self.validate(incoming)
    // Import adds missing records only. It never deletes or replaces existing edits.
    let known = Set(records.map(\.id)).union(deletedIDs).union(records.flatMap { $0.watchSourceIDs ?? [] })
    let knownHealthIDs = Set(records.compactMap(\.healthWorkoutID))
    var additions = incoming.records.filter {
      !known.contains($0.id) && !incoming.deletedIDs.contains($0.id)
        && ($0.healthWorkoutID.map { !knownHealthIDs.contains($0) } ?? true)
    }
    for index in additions.indices {
      // An imported pending export is uncertain, not proof of a successful write.
      if additions[index].healthExportState == .pending {
        additions[index].healthExportState = .failed
        additions[index].healthExportMessage = "이전 저장 결과를 다시 확인해야 합니다."
      }
    }
    try persist(records + additions, deleted: deletedIDs)
  }

  private func persist(_ next: [PersonalWorkout], deleted: Set<UUID>) throws {
    guard ready, let file else { throw LocalDataError.storageUnavailable }
    let archive = RecordArchive(records: next, deletedIDs: deleted)
    try Self.validate(archive)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(archive)
    guard data.count <= maximumArchiveBytes else { throw LocalDataError.archiveTooLarge }
    try ProtectedFile.writeData(data, to: file)
    records = next.sorted { $0.startedAt > $1.startedAt }
    deletedIDs = deleted
    notice = nil
  }

  private static func validate(_ archive: RecordArchive) throws {
    guard archive.version == 1 else { throw LocalDataError.unsupportedVersion }
    guard archive.records.count <= 50_000, archive.deletedIDs.count <= 100_000,
      Set(archive.records.map(\.id)).count == archive.records.count,
      archive.records.allSatisfy({ !archive.deletedIDs.contains($0.id) })
    else { throw LocalDataError.invalidRecord }
    let healthIDs = archive.records.compactMap(\.healthWorkoutID)
    guard Set(healthIDs).count == healthIDs.count else { throw LocalDataError.invalidRecord }
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
      if source.placeID != target.placeID, let place = source.placeName ?? source.placeID, target.placeID != nil {
        conflicts.append("장소: \(place)")
      }
      if !conflicts.isEmpty { notes = combinedNotes(notes, "병합한 다른 개인 기록의 값:\n" + conflicts.joined(separator: "\n")) }
    }
    if target.placeID == nil { target.placeID = source.placeID; target.placeName = source.placeName }
    target.notes = combinedNotes(target.notes, notes)
    let knownExercises = Set(target.exercises.map(\.id))
    target.exercises.append(contentsOf: source.exercises.filter { !knownExercises.contains($0.id) })
  }

  private static func applyExerciseEdits(_ draft: [ExerciseEntry], original: [ExerciseEntry], latest: [ExerciseEntry]) -> [ExerciseEntry] {
    let removedIDs = Set(original.map(\.id)).subtracting(draft.map(\.id))
    var result = latest.filter { !removedIDs.contains($0.id) }
    for entry in draft {
      guard let baseline = original.first(where: { $0.id == entry.id }) else {
        if !result.contains(where: { $0.id == entry.id }) { result.append(entry) }
        continue
      }
      guard entry != baseline else { continue }
      guard let index = result.firstIndex(where: { $0.id == entry.id }) else { result.append(entry); continue }
      if entry.name != baseline.name { result[index].name = entry.name }
      let removedSets = Set(baseline.sets.map(\.id)).subtracting(entry.sets.map(\.id))
      result[index].sets.removeAll { removedSets.contains($0.id) }
      for set in entry.sets where baseline.sets.first(where: { $0.id == set.id }) != set {
        if let setIndex = result[index].sets.firstIndex(where: { $0.id == set.id }) { result[index].sets[setIndex] = set }
        else { result[index].sets.append(set) }
      }
    }
    return result
  }
}
