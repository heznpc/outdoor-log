import SwiftUI

struct PlaceChoice: Identifiable, Sendable {
  let id: String
  let name: String
  var detail: String? = nil
}

private struct WorkoutPlaceCatalogRevisionKey: EnvironmentKey {
  static let defaultValue = 0
}

extension EnvironmentValues {
  var workoutPlaceCatalogRevision: Int {
    get { self[WorkoutPlaceCatalogRevisionKey.self] }
    set { self[WorkoutPlaceCatalogRevisionKey.self] = newValue }
  }
}

struct WorkoutEditor: View {
  @Environment(\.dismiss) private var dismiss
  let store: RecordStore
  let places: [PlaceChoice]
  private let original: PersonalWorkout
  @State private var draft: PersonalWorkout
  @State private var error: String?
  @State private var newExercise = ""
  @State private var choosingPlace = false

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
          Button { choosingPlace = true } label: {
            LabeledContent("연결할 장소", value: draft.placeName ?? (draft.placeID == nil ? "장소 연결 안 함" : "이전에 연결한 장소"))
          }
          .accessibilityHint("장소 검색 화면을 엽니다")
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
      .sheet(isPresented: $choosingPlace) {
        WorkoutPlacePicker(places: places, selectedID: draft.placeID, selectedName: draft.placeName) { place in
          draft.placeID = place?.id
          draft.placeName = place?.name
        }
      }
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

@MainActor private struct WorkoutPlacePicker: View {
  let places: [PlaceChoice]
  let selectedID: String?
  let selectedName: String?
  let onSelect: (PlaceChoice?) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.workoutPlaceCatalogRevision) private var catalogRevision
  @State private var query = ""
  @State private var results: [PlaceChoice] = []
  @State private var totalMatches = 0
  @State private var completedRequest: SearchRequest?
  private let resultLimit = 60

  private struct SearchRequest: Equatable, Sendable {
    let query: String
    let catalogRevision: Int
  }

  private var searchRequest: SearchRequest {
    SearchRequest(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
      catalogRevision: catalogRevision)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          if selectedID != nil {
            LabeledContent("현재 연결", value: selectedName ?? "이전에 연결한 장소")
            Text("검색 결과에 없어도 기존 장소 연결은 유지됩니다.")
              .font(.footnote).foregroundStyle(.secondary)
          }
          Button("장소 연결 안 함") { onSelect(nil); dismiss() }
        }
        Section {
          if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("장소 이름이나 주소를 입력해 \(places.count)곳의 등록 목록에서 검색하세요.")
              .foregroundStyle(.secondary)
          } else if completedRequest != searchRequest {
            ProgressView("장소 검색 중")
          } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
          } else {
            ForEach(results) { place in
              Button {
                onSelect(place)
                dismiss()
              } label: {
                HStack(alignment: .top) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(place.name).foregroundStyle(.primary)
                    if let detail = place.detail, !detail.isEmpty {
                      Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                  }
                  Spacer(minLength: 8)
                  if place.id == selectedID { Image(systemName: "checkmark").accessibilityLabel("현재 연결된 장소") }
                }.padding(.vertical, 4)
              }
            }
          }
        } footer: {
          if completedRequest == searchRequest, totalMatches > resultLimit {
            Text("검색 결과 \(totalMatches)곳 중 앞 \(resultLimit)곳입니다. 이름이나 주소를 더 입력해 범위를 좁혀주세요.")
          }
        }
      }
      .navigationTitle("운동 장소 선택")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "장소 이름, 지역, 주소")
      .scrollDismissesKeyboard(.interactively)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
      .task(id: searchRequest) {
        let request = searchRequest
        guard !request.query.isEmpty else {
          results = []; totalMatches = 0; completedRequest = request
          return
        }
        let snapshot = places
        let limit = resultLimit
        do {
          try await Task.sleep(for: .milliseconds(180))
          let search = Task.detached(priority: .userInitiated) { () -> (places: [PlaceChoice], count: Int) in
            let terms = request.query.split(whereSeparator: \.isWhitespace).map(String.init)
            var found: [PlaceChoice] = []
            var count = 0
            for place in snapshot {
              if Task.isCancelled { return ([], 0) }
              let text = place.name + " " + (place.detail ?? "")
              if terms.allSatisfy({ text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                count += 1
                if found.count < limit { found.append(place) }
              }
            }
            return (found, count)
          }
          let found = await withTaskCancellationHandler {
            await search.value
          } onCancel: {
            search.cancel()
          }
          try Task.checkCancellation()
          guard request == searchRequest else { return }
          results = found.places
          totalMatches = found.count
          completedRequest = request
        } catch { /* The newest query and catalog revision own the results and loading state. */ }
      }
    }
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
