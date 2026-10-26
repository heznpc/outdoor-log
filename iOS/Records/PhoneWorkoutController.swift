import Foundation
import Observation
import SwiftUI

struct PhoneWorkoutDraft: Codable {
  var version = 1
  var workout: PersonalWorkout
  var pausedAt: Date?
  var finishedAt: Date?

  func validate() throws {
    guard version == 1 else { throw LocalDataError.unsupportedVersion }
    if let finishedAt {
      try workout.validate()
      guard finishedAt == workout.endedAt else { throw LocalDataError.invalidRecord }
    } else {
      try workout.validateInProgress()
    }
    if let pausedAt {
      guard pausedAt >= workout.startedAt, pausedAt <= workout.endedAt,
        finishedAt != nil || pausedAt >= (workout.pauses.last?.endedAt ?? workout.startedAt)
      else { throw LocalDataError.invalidRecord }
    }
  }
}

@MainActor @Observable
final class PhoneWorkoutController {
  private(set) var draft: PhoneWorkoutDraft?
  private(set) var ready = false
  private(set) var canDiscard = false
  var notice: String?
  private var file: URL?
  private let suppliedDirectory: URL?
  private let now: () -> Date

  init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
    suppliedDirectory = directory
    self.now = now
    reload()
  }

  func reload() {
    ready = false
    do {
      let directory = try suppliedDirectory ?? ProtectedFile.directory()
      let url = directory.appendingPathComponent("active-phone-workout.json")
      file = url
      canDiscard = FileManager.default.fileExists(atPath: url.path)
      if canDiscard {
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw LocalDataError.unreadable }
        let value = try JSONDecoder().decode(PhoneWorkoutDraft.self, from: data)
        try value.validate()
        draft = value
      } else {
        draft = nil
      }
      ready = true
      notice = nil
    } catch { ready = false; notice = error.localizedDescription }
  }

  func elapsed(at now: Date) -> TimeInterval {
    guard let draft else { return 0 }
    if draft.finishedAt != nil { return draft.workout.duration }
    let end = draft.pausedAt ?? now
    let paused = draft.workout.pauses.reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
    return max(0, end.timeIntervalSince(draft.workout.startedAt) - paused)
  }

  func start(kind: WorkoutKind, placeID: String? = nil, placeName: String? = nil) throws {
    guard ready, draft == nil else { throw LocalDataError.storageUnavailable }
    let now = self.now()
    // A valid catalog name can be longer than the record title limit. Keep the
    // full place metadata while giving the generated title room for the kind.
    let title = placeName.map { "\(String($0.prefix(159 - kind.title.count))) \(kind.title)" } ?? kind.title
    let workout = PersonalWorkout(title: title,
      kind: kind, startedAt: now, endedAt: now, placeID: placeID, placeName: placeName)
    try commit(PhoneWorkoutDraft(workout: workout))
  }

  func pause() throws {
    guard var next = draft, next.pausedAt == nil, next.finishedAt == nil else { return }
    let now = self.now()
    guard now >= next.workout.endedAt else { throw LocalDataError.invalidRecord }
    next.pausedAt = now
    next.workout.endedAt = next.pausedAt!
    try commit(next)
  }

  func resume() throws {
    guard var next = draft, let paused = next.pausedAt, next.finishedAt == nil else { return }
    let now = self.now()
    guard now >= next.workout.endedAt else { throw LocalDataError.invalidRecord }
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
    next.workout.endedAt = max(next.workout.endedAt, now())
    try commit(next)
  }

  func finish(into store: RecordStore) throws {
    guard var current = draft else { return }
    if current.finishedAt == nil {
      let now = self.now()
      guard now >= current.workout.endedAt else { throw LocalDataError.invalidRecord }
      current.workout.activeDurationSeconds = elapsed(at: now)
      current.workout.endedAt = now
      if let paused = current.pausedAt {
        current.workout.pauses.append(WorkoutPause(startedAt: paused, endedAt: now))
      }
      current.workout.modifiedAt = now
      current.finishedAt = now
      try current.workout.validateNewTiming(at: now)
      try commit(current)
    }
    try saveFinished(current, into: store)
  }

  func finishCorrecting(startedAt: Date, endedAt: Date, activeDurationSeconds: Double,
    resetPauses: Bool, into store: RecordStore) throws {
    guard var current = draft, current.finishedAt == nil else { throw LocalDataError.invalidRecord }
    guard resetPauses || (current.workout.pauses.isEmpty && current.pausedAt == nil)
    else { throw LocalDataError.invalidRecord }
    current.workout.startedAt = startedAt
    current.workout.endedAt = endedAt
    current.workout.activeDurationSeconds = activeDurationSeconds
    current.workout.pauses = []
    current.workout.timingEditedLocally = true
    current.workout.modifiedAt = now()
    current.pausedAt = nil
    current.finishedAt = endedAt
    try current.workout.validateNewTiming(at: now())
    try commit(current)
    try saveFinished(current, into: store)
  }

  func discard() throws {
    guard let file else { throw LocalDataError.storageUnavailable }
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    draft = nil
    canDiscard = false
    ready = true
    notice = nil
  }

  private func saveFinished(_ current: PhoneWorkoutDraft, into store: RecordStore) throws {
    guard let file else { throw LocalDataError.storageUnavailable }
    // If cleanup failed after the previous durable save, retry cleanup without
    // extending the recorded workout or overwriting later personal edits.
    if !store.hasDurableRecordOrDeletion(current.workout.id) { try store.save(current.workout) }
    // Keep the durable draft until the completed record has been written.
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    draft = nil
    canDiscard = false
  }

  private func commit(_ next: PhoneWorkoutDraft) throws {
    guard ready, let file else { throw LocalDataError.storageUnavailable }
    try next.validate()
    try ProtectedFile.write(next, to: file)
    draft = next
    canDiscard = true
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
  @State private var confirmingDiscard = false
  @State private var correctingTime = false

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
        if draft.finishedAt == nil {
          Button("실제 운동 시간으로 보정해서 저장") { correctingTime = true }
            .disabled(!controller.ready || !store.ready)
          Text("종료를 잊었거나 기기 시각이 바뀌었다면 실제 시작·종료와 활동 시간을 입력할 수 있습니다.")
            .font(.footnote).foregroundStyle(.secondary)
        }
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
      if controller.canDiscard {
        Button("진행 중 기록 폐기", role: .destructive) { confirmingDiscard = true }
      }
    }
    .confirmationDialog("진행 중 기록을 폐기할까요?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
      Button("기록 폐기", role: .destructive) { perform { try controller.discard() } }
      Button("취소", role: .cancel) {}
    } message: {
      Text("아직 저장하지 않은 운동 시간과 세트가 삭제되며 되돌릴 수 없습니다.")
    }
    .sheet(isPresented: $correctingTime) {
      if let draft = controller.draft {
        PhoneWorkoutTimeCorrection(controller: controller, store: store, draft: draft)
      }
    }
  }

  private func perform(_ action: () throws -> Void) {
    do { try action(); error = nil } catch { self.error = error.localizedDescription }
  }
}

private struct PhoneWorkoutTimeCorrection: View {
  let controller: PhoneWorkoutController
  let store: RecordStore
  private let hasPauses: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var startedAt: Date
  @State private var endedAt: Date
  @State private var activeMinutes: Double?
  @State private var resetPauses = false
  @State private var error: String?

  init(controller: PhoneWorkoutController, store: RecordStore, draft: PhoneWorkoutDraft) {
    self.controller = controller
    self.store = store
    hasPauses = !draft.workout.pauses.isEmpty || draft.pausedAt != nil
    _startedAt = State(initialValue: draft.workout.startedAt)
    _endedAt = State(initialValue: draft.pausedAt ?? Date())
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("실제 운동 시간") {
          DatePicker("실제 시작", selection: $startedAt)
          DatePicker("실제 종료", selection: $endedAt)
          TextField("활동 시간 (분)", value: $activeMinutes, format: .number)
            .keyboardType(.decimalPad)
          Text("휴식을 뺀 실제 활동 시간을 직접 입력해 주세요. 활동 시간은 7일 이하이고 시작·종료 사이에 들어가야 합니다.")
            .font(.footnote).foregroundStyle(.secondary)
          if hasPauses {
            Toggle("시간을 보정하며 기존 휴식 구간 삭제", isOn: $resetPauses)
            Text("기록한 세트는 유지되며 휴식 구간은 복원할 수 없습니다.")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }
        if let error { Section { Text(error).foregroundStyle(.red) } }
      }
      .navigationTitle("운동 시간 보정")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(controller.draft?.finishedAt == nil ? "보정하고 저장" : "저장 다시 시도") {
            guard let activeMinutes else { return }
            do {
              if controller.draft?.finishedAt != nil {
                try controller.finish(into: store)
              } else {
                try controller.finishCorrecting(startedAt: startedAt, endedAt: endedAt,
                  activeDurationSeconds: activeMinutes * 60, resetPauses: resetPauses, into: store)
              }
              dismiss()
            } catch { self.error = error.localizedDescription }
          }.disabled(activeMinutes == nil || (hasPauses && !resetPauses) || !store.ready || !controller.ready)
        }
      }
    }
  }
}
