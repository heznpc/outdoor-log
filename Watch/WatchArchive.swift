import Foundation

enum WatchSaveStage: String, Codable {
  case recording, ending, collectionEnded, saveRequested, saveRejected
}

struct WatchJournal: Codable {
  var workout: PersonalWorkout
  var stage: WatchSaveStage = .recording
  var elapsedSeconds: Double = 0
}

private struct WatchArchiveDocument: Codable {
  var version = 1
  var journal: WatchJournal?
  var history: [PersonalWorkout] = []
  var pendingIDs: Set<UUID> = []
}

/// One atomic protected document commits both local history and the durable transfer outbox.
@MainActor
final class WatchArchive {
  private let url: URL
  private var document: WatchArchiveDocument

  init() throws {
    url = try ProtectedFile.directory().appendingPathComponent("watch-workouts-v1.json")
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        let data = try Data(contentsOf: url)
        guard data.count <= 20 * 1024 * 1024 else { throw LocalDataError.unreadable }
        let loaded = try JSONDecoder().decode(WatchArchiveDocument.self, from: data)
        guard loaded.version == 1 else { throw LocalDataError.unsupportedVersion }
        guard Set(loaded.history.map(\.id)).count == loaded.history.count,
          loaded.pendingIDs.isSubset(of: Set(loaded.history.map(\.id))) else { throw LocalDataError.unreadable }
        for workout in loaded.history { try workout.validate() }
        if let journal = loaded.journal { try journal.workout.validate() }
        document = loaded
      } catch let error as LocalDataError { throw error }
      catch { throw LocalDataError.unreadable }
    } else {
      document = WatchArchiveDocument()
      try ProtectedFile.write(document, to: url)
    }
  }

  var journal: WatchJournal? { document.journal }
  var history: [PersonalWorkout] { document.history.sorted { $0.startedAt > $1.startedAt } }
  var pending: [PersonalWorkout] { document.history.filter { document.pendingIDs.contains($0.id) } }

  func saveJournal(_ journal: WatchJournal) throws {
    try journal.workout.validate()
    var next = document
    next.journal = journal
    try commit(next)
  }

  func complete(_ workout: PersonalWorkout) throws {
    // Validate the actual transfer before committing an unsendable outbox entry.
    _ = try WatchWire.encode(WatchPacket(kind: .completed, workout: workout))
    var next = document
    next.history.removeAll { $0.id == workout.id }
    next.history.append(workout)
    next.pendingIDs.insert(workout.id)
    if next.journal?.workout.id == workout.id { next.journal = nil }
    // Retain every unacknowledged record even when the on-watch recent history is full.
    let retained = Set(next.history.sorted { $0.startedAt > $1.startedAt }.prefix(200).map(\.id))
      .union(next.pendingIDs)
    next.history.removeAll { !retained.contains($0.id) }
    try commit(next)
  }

  func acknowledge(_ packet: WatchPacket) throws {
    guard let id = packet.acknowledgedWorkoutID,
      let workout = document.history.first(where: { $0.id == id }),
      WatchWire.matchesAcknowledgement(packet, workout: workout), document.pendingIDs.contains(id) else { return }
    var next = document
    next.pendingIDs.remove(id)
    try commit(next)
  }

  private func commit(_ next: WatchArchiveDocument) throws {
    guard try JSONEncoder().encode(next).count <= 20 * 1024 * 1024 else {
      throw LocalDataError.storageUnavailable
    }
    try ProtectedFile.write(next, to: url)
    document = next
  }
}
