import SwiftUI

struct PlaceChoice: Identifiable {
  let id: String
  let name: String
}

struct WorkoutEditor: View {
  @Environment(\.dismiss) private var dismiss
  let store: RecordStore
  let places: [PlaceChoice]
  private let original: PersonalWorkout
  @State private var draft: PersonalWorkout
  @State private var error: String?
  @State private var newExercise = ""

  init(store: RecordStore, places: [PlaceChoice], record: PersonalWorkout) {
    self.store = store
    self.places = places
    self.original = record
    _draft = State(initialValue: record)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("운동") {
          TextField("제목", text: $draft.title)
          Picker("종류", selection: $draft.kind) {
            ForEach(WorkoutKind.allCases) { kind in Text(kind.title).tag(kind) }
          }
          DatePicker("시작", selection: $draft.startedAt, in: ...Date())
          DatePicker("종료", selection: $draft.endedAt, in: ...Date())
          if draft.healthWorkoutID != nil {
            Text("이 화면은 개인 기록을 수정합니다. 건강 앱의 원본 운동은 변경하지 않습니다.")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }
        Section("장소") {
          Picker("연결할 장소", selection: Binding(
            get: { draft.placeID ?? "" },
            set: { id in
              draft.placeID = id.isEmpty ? nil : id
              draft.placeName = places.first { $0.id == id }?.name
            })) {
              Text("장소 연결 안 함").tag("")
              if let id = draft.placeID, !places.contains(where: { $0.id == id }) {
                Text(draft.placeName ?? "이전에 연결한 장소").tag(id)
              }
              ForEach(places) { place in Text(place.name).tag(place.id) }
            }
          Text("직접 선택한 장소로 기록합니다. 위치나 건강 기록으로 기구 사용을 추정하지 않습니다.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach($draft.exercises) { $exercise in
          Section {
            TextField("운동·기구 이름", text: $exercise.name)
            ForEach($exercise.sets) { $set in
              SetEditor(set: $set)
            }
            .onDelete { offsets in exercise.sets.remove(atOffsets: offsets) }
            Button("세트 추가", systemImage: "plus") {
              exercise.sets.append(ExerciseSet(repetitions: 10))
            }.disabled(exercise.sets.count >= 100)
            Button("이 운동 항목 삭제", role: .destructive) {
              draft.exercises.removeAll { $0.id == exercise.id }
            }
          } header: { Text("기구·운동별 기록") }
        }
        Section {
          TextField("예: 철봉, 평행봉, 스쿼트", text: $newExercise)
          Button("운동 항목 추가", systemImage: "plus") {
            let name = newExercise.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            draft.exercises.append(ExerciseEntry(name: name, sets: [ExerciseSet(repetitions: 10)]))
            newExercise = ""
          }.disabled(newExercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.exercises.count >= 100)
        }
        Section("메모") { TextEditor(text: $draft.notes).frame(minHeight: 100) }
        if let error { Section { Text(error).foregroundStyle(.red) } }
      }
      .navigationTitle("운동 기록")
      .onChange(of: draft.startedAt) { _, _ in resetMeasuredDuration() }
      .onChange(of: draft.endedAt) { _, _ in resetMeasuredDuration() }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("저장") {
            do {
              draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
              draft.modifiedAt = Date()
              try store.saveEdited(draft, original: original)
              dismiss()
            } catch { self.error = error.localizedDescription }
          }.disabled(!store.ready)
        }
      }
    }
  }

  private func resetMeasuredDuration() {
    // Editing the local interval is an explicit manual correction. Old pause
    // intervals no longer describe the corrected times, and Health is unchanged.
    draft.activeDurationSeconds = nil
    draft.pauses = []
  }
}

private struct SetEditor: View {
  @Binding var set: ExerciseSet
  var body: some View {
    VStack(alignment: .leading) {
      Stepper("반복 \(set.repetitions)회", value: $set.repetitions, in: 0...10_000)
      HStack {
        Text("중량 (kg)")
        TextField("선택", value: $set.weightKilograms, format: .number)
          .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
          .accessibilityLabel("세트 중량 킬로그램")
      }
      HStack {
        Text("유지 시간 (초)")
        TextField("선택", value: $set.durationSeconds, format: .number)
          .keyboardType(.numberPad).multilineTextAlignment(.trailing)
          .accessibilityLabel("세트 유지 시간 초")
      }
    }.padding(.vertical, 4)
  }
}
