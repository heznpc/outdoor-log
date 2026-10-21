import Foundation
import Observation
import SwiftUI

struct PhoneWorkoutDraft: Codable {
  var version = 1
  var workout: PersonalWorkout
  var pausedAt: Date?
  var finishedAt: Date?
}

@MainActor @Observable
final class PhoneWorkoutController {
  private(set) var draft: PhoneWorkoutDraft?
  private(set) var ready = false
  var notice: String?
  private var file: URL?

  init() { reload() }

  func reload() {
    do {
      let url = try ProtectedFile.directory().appendingPathComponent("active-phone-workout.json")
      file = url
      if FileManager.default.fileExists(atPath: url.path) {
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw LocalDataError.unreadable }
        let value = try JSONDecoder().decode(PhoneWorkoutDraft.self, from: data)
        guard value.version == 1 else { throw LocalDataError.unsupportedVersion }
        try value.workout.validate()
        draft = value
      }
      ready = true
      notice = nil
    } catch { ready = false; notice = error.localizedDescription }
  }

  func elapsed(at now: Date) -> TimeInterval {
    guard let draft else { return 0 }
    let end = draft.pausedAt ?? now
    let paused = draft.workout.pauses.reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
    return max(0, end.timeIntervalSince(draft.workout.startedAt) - paused)
  }

  func start(kind: WorkoutKind, placeID: String? = nil, placeName: String? = nil) throws {
    guard ready, draft == nil else { throw LocalDataError.storageUnavailable }
    let now = Date()
    let workout = PersonalWorkout(title: placeName.map { "\($0) \(kind.title)" } ?? kind.title,
      kind: kind, startedAt: now, endedAt: now, placeID: placeID, placeName: placeName)
    try commit(PhoneWorkoutDraft(workout: workout))
  }

  func pause() throws {
    guard var next = draft, next.pausedAt == nil, next.finishedAt == nil else { return }
    next.pausedAt = Date()
    next.workout.endedAt = next.pausedAt!
    try commit(next)
  }

  func resume() throws {
    guard var next = draft, let paused = next.pausedAt, next.finishedAt == nil else { return }
    let now = Date()
    next.workout.pauses.append(WorkoutPause(startedAt: paused, endedAt: now))
    next.workout.endedAt = now
    next.pausedAt = nil
    try commit(next)
  }

  func addSet(exercise: String, repetitions: Int) throws {
    guard var next = draft, next.finishedAt == nil else { return }
    let name = exercise.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 160, (0...10_000).contains(repetitions) else { throw LocalDataError.invalidRecord }
    if let index = next.workout.exercises.firstIndex(where: { $0.name == name }) {
      guard next.workout.exercises[index].sets.count < 100 else { throw LocalDataError.invalidRecord }
      next.workout.exercises[index].sets.append(ExerciseSet(repetitions: repetitions))
    } else {
      guard next.workout.exercises.count < 100 else { throw LocalDataError.invalidRecord }
      next.workout.exercises.append(ExerciseEntry(name: name, sets: [ExerciseSet(repetitions: repetitions)]))
    }
    next.workout.endedAt = Date()
    try commit(next)
  }

  func finish(into store: RecordStore) throws {
    guard var current = draft, let file else { return }
    if current.finishedAt == nil {
      let now = Date()
      current.workout.activeDurationSeconds = elapsed(at: now)
      current.workout.endedAt = now
      if let paused = current.pausedAt {
        current.workout.pauses.append(WorkoutPause(startedAt: paused, endedAt: now))
      }
      current.workout.modifiedAt = now
      current.finishedAt = now
      try commit(current)
    }
    // If cleanup failed after the previous durable save, retry cleanup without
    // extending the recorded workout or overwriting later personal edits.
    if !store.hasDurableRecordOrDeletion(current.workout.id) { try store.save(current.workout) }
    // Keep the durable draft until the completed record has been written.
    try FileManager.default.removeItem(at: file)
    draft = nil
  }

  private func commit(_ next: PhoneWorkoutDraft) throws {
    guard ready, let file else { throw LocalDataError.storageUnavailable }
    try next.workout.validate()
    try ProtectedFile.write(next, to: file)
    draft = next
  }
}

struct PhoneWorkoutPanel: View {
  let controller: PhoneWorkoutController
  let store: RecordStore
  var placeID: String? = nil
  var placeName: String? = nil
  @State private var kind: WorkoutKind = .strength
  @State private var exercise = ""
  @State private var repetitions = 10
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let draft = controller.draft {
        Text(draft.workout.title).font(.headline)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let seconds = Int(draft.finishedAt == nil ? controller.elapsed(at: context.date) : draft.workout.duration)
          Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
            .font(.title.monospacedDigit()).accessibilityLabel("활동 시간 \(seconds)초")
        }
        if draft.finishedAt != nil { Text("운동이 끝났습니다. 저장 마무리를 다시 시도해 주세요.") }
        else if draft.pausedAt != nil { Text("일시정지 중") }
        HStack {
          Button(draft.pausedAt == nil ? "일시정지" : "계속") {
            perform { if draft.pausedAt == nil { try controller.pause() } else { try controller.resume() } }
          }.disabled(draft.finishedAt != nil)
          Button("종료하고 기록 저장") { perform { try controller.finish(into: store) } }
        }.buttonStyle(.bordered).disabled(!store.ready)
        TextField("세트를 기록할 기구·운동", text: $exercise)
        Stepper("\(repetitions)회", value: $repetitions, in: 0...10_000)
        Button("세트 기록") {
          perform { try controller.addSet(exercise: exercise, repetitions: repetitions) }
        }.disabled(exercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.finishedAt != nil)
        Text("\(draft.workout.exercises.reduce(0) { $0 + $1.sets.count })개 세트 기록됨")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Picker("운동 종류", selection: $kind) {
          ForEach(WorkoutKind.allCases) { Text($0.title).tag($0) }
        }
        Button("iPhone에서 운동 시작", systemImage: "play.fill") {
          perform { try controller.start(kind: kind, placeID: placeID, placeName: placeName) }
        }.disabled(!controller.ready || !store.ready)
        Text("시간과 세트를 기기에 기록합니다. 건강 앱 저장은 완료된 기록에서 선택할 수 있습니다.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      if let notice = controller.notice {
        Text(notice).foregroundStyle(.red)
        Button("진행 중 기록 다시 열기") { controller.reload() }
      }
      if let error { Text(error).foregroundStyle(.red) }
    }
  }

  private func perform(_ action: () throws -> Void) {
    do { try action(); error = nil } catch { self.error = error.localizedDescription }
  }
}
