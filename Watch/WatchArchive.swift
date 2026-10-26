import Foundation

private struct WatchArchiveDocument: Codable {
  var version = 1
  var journal: WatchJournal?
  var history: [PersonalWorkout] = []
  var pendingIDs: Set<UUID> = []
  // Optional for archives written before durable HealthKit retries were introduced.
  var healthRecovery: WatchHealthRecoveryState?
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
        if let journal = loaded.journal { try journal.validate() }
        let retries = loaded.healthRecovery?.attempts ?? []
        let knownIDs = Set(loaded.history.map(\.id)).union(loaded.journal.map { [$0.workout.id] } ?? [])
        guard Set(retries.map(\.workoutID)).count == retries.count,
          retries.allSatisfy({ knownIDs.contains($0.workoutID) }) else { throw LocalDataError.unreadable }
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

  func healthRetry(for id: UUID) -> WatchHealthRetry? { document.healthRecovery?.attempt(for: id) }

  func saveHealthRetry(_ retry: WatchHealthRetry) throws {
    guard document.history.contains(where: { $0.id == retry.workoutID })
      || document.journal?.workout.id == retry.workoutID else { throw LocalDataError.invalidRecord }
    var next = document
    var recovery = next.healthRecovery ?? WatchHealthRecoveryState()
    recovery.remember(retry)
    next.healthRecovery = recovery
    try commit(next)
  }

  func saveJournal(_ journal: WatchJournal) throws {
    try journal.validate()
    var next = document
    next.journal = journal
    if journal.stage != .recording {
      var recovery = next.healthRecovery ?? WatchHealthRecoveryState()
      recovery.remember(WatchHealthRetry(workoutID: journal.workout.id, stage: journal.stage))
      next.healthRecovery = recovery
    }
    try commit(next)
  }

  func complete(_ workout: PersonalWorkout, recoveryJournal: WatchJournal? = nil) throws {
    // Validate the actual transfer before committing an unsendable outbox entry.
    _ = try WatchWire.encodeTransfer(WatchPacket(kind: .completed, workout: workout))
    var next = document
    next.history.removeAll { $0.id == workout.id }
    next.history.append(workout)
    next.pendingIDs.insert(workout.id)
    var recovery = next.healthRecovery ?? WatchHealthRecoveryState()
    recovery.complete(workout, journal: recoveryJournal ?? next.journal)
    next.healthRecovery = recovery
    if next.journal?.workout.id == workout.id { next.journal = nil }
    // Retain every unacknowledged record even when the on-watch recent history is full.
    let retained = Set(next.history.sorted { $0.startedAt > $1.startedAt }.prefix(200).map(\.id))
      .union(next.pendingIDs).union(recovery.attempts.map(\.workoutID))
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
