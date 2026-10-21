import SwiftUI
import UniformTypeIdentifiers

struct RecordsView: View {
  let store: RecordStore
  let health: HealthLibrary
  let recorder: PhoneWorkoutController
  let places: [PlaceChoice]
  @ObservedObject var watch: WatchLink
  @State private var editing: PersonalWorkout?
  @State private var exporting = false
  @State private var importing = false
  @State private var archive: WorkoutArchiveDocument?
  @State private var notice: String?

  var body: some View {
    NavigationStack {
      List {
        Section("iPhone 운동 기록") { PhoneWorkoutPanel(controller: recorder, store: store) }
        WatchStatusView(link: watch)
        if let notice = store.notice {
          Section {
            Text(notice).foregroundStyle(.red)
            Button("기록 다시 열기") { store.reload() }
          }
        }
        if let notice { Section { Text(notice) } }
        if store.ready && store.records.isEmpty {
          ContentUnavailableView("아직 운동 기록이 없습니다", systemImage: "dumbbell",
            description: Text("직접 기록하거나 건강 탭에서 기존 운동을 연결할 수 있습니다."))
        }
        Section("개인 운동 기록") {
          ForEach(store.records) { record in
            NavigationLink {
              RecordDetailView(id: record.id, store: store, health: health, places: places)
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                Label(record.title, systemImage: record.kind.symbol).font(.headline)
                Text(record.startedAt, format: .dateTime.year().month().day().hour().minute())
                  .font(.subheadline).foregroundStyle(.secondary)
                if let place = record.placeName { Text(place).font(.subheadline) }
                Text("\(Int(record.duration / 60))분 · \(record.exercises.count)개 운동 항목")
                  .font(.caption).foregroundStyle(.secondary)
              }.padding(.vertical, 4)
            }
          }
        }
        Section("개인 데이터") {
          Button("기록 파일 내보내기", systemImage: "square.and.arrow.up") {
            do { archive = WorkoutArchiveDocument(data: try store.exportData()); exporting = true }
            catch { notice = error.localizedDescription }
          }.disabled(!store.ready)
          Button("기록 파일 가져오기", systemImage: "square.and.arrow.down") { importing = true }
            .disabled(!store.ready)
          Text("기록은 이 기기에 저장됩니다. 앱을 삭제하기 전에 직접 내보내 주세요. 내보낸 파일에는 장소와 개인 운동 정보가 포함됩니다.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("나의 운동")
      .toolbar {
        Button("새 운동 기록", systemImage: "plus") {
          let end = Date()
          editing = PersonalWorkout(title: "근력 운동", kind: .strength,
            startedAt: end, endedAt: end)
        }.disabled(!store.ready)
      }
      .sheet(item: $editing) { record in WorkoutEditor(store: store, places: places, record: record) }
      .fileExporter(isPresented: $exporting, document: archive, contentType: .json,
        defaultFilename: "OutdoorLog-workouts") { result in
          if case .failure(let error) = result { notice = error.localizedDescription }
        }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
        do {
          let url = try result.get()
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 25_000_000 else { throw LocalDataError.invalidRecord }
          try store.importData(Data(contentsOf: url))
          notice = "기존 기록을 유지하고 새로운 기록을 가져왔습니다."
        } catch { notice = error.localizedDescription }
      }
    }
  }
}

private struct RecordDetailView: View {
  @Environment(\.dismiss) private var dismiss
  let id: UUID
  let store: RecordStore
  let health: HealthLibrary
  let places: [PlaceChoice]
  @State private var editing: PersonalWorkout?
  @State private var confirmingDelete = false
  @State private var savingHealth = false
  @State private var error: String?
  private var record: PersonalWorkout? { store.records.first { $0.id == id } }

  var body: some View {
    Group {
      if let record {
        List {
          Section("운동") {
            LabeledContent("종류", value: record.kind.title)
            LabeledContent("시작") { Text(record.startedAt, format: .dateTime) }
            LabeledContent("종료") { Text(record.endedAt, format: .dateTime) }
            LabeledContent("시간", value: "\(Int(record.duration / 60))분")
            if let name = record.placeName { LabeledContent("직접 연결한 장소", value: name) }
            if !record.notes.isEmpty { Text(record.notes) }
          }
          ForEach(record.exercises) { exercise in
            Section(exercise.name) {
              ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                VStack(alignment: .leading) {
                  Text("\(index + 1)세트 · \(set.repetitions)회")
                  if let weight = set.weightKilograms { Text("\(weight.formatted()) kg") }
                  if let seconds = set.durationSeconds { Text("\(seconds)초") }
                }
              }
            }
          }
          Section("Apple 건강") {
            if record.healthWorkoutID != nil {
              Text(record.origin == .healthLink ? "건강 앱에서 가져온 운동과 연결되어 있습니다." : "건강 앱에 저장된 운동과 연결되어 있습니다.")
              Text("건강 원본은 별도로 삭제되거나 읽기 접근이 제한될 수 있습니다. 여기에는 직접 저장한 개인 기록이 남습니다.")
                .font(.footnote).foregroundStyle(.secondary)
            } else if record.origin == .watch {
              Text("Watch에서 건강 저장 상태를 확인하거나 다시 시도해 주세요. 중복 저장을 막기 위해 iPhone에서 같은 운동을 다시 기록하지 않습니다.")
            } else {
              Text("운동 종류와 시작·종료 시각을 저장합니다. 세트·횟수·메모는 이 앱에 보관하며 측정하지 않은 칼로리는 만들지 않습니다.")
                .font(.footnote)
              Button(savingHealth ? "저장 확인 중…" : "건강 앱에 운동 저장") {
                Task { await exportToHealth() }
              }.disabled(savingHealth || !health.available)
            }
            if let message = record.healthExportMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
          }
          if let error { Section { Text(error).foregroundStyle(.red) } }
          Section {
            Button("개인 기록 삭제", role: .destructive) { confirmingDelete = true }
              .disabled(savingHealth)
            Text("개인 기록만 삭제합니다. Apple 건강의 원본 운동은 삭제하지 않습니다.")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }
        .navigationTitle(record.title)
        .toolbar { Button("편집") { editing = record }.disabled(savingHealth) }
      } else {
        ContentUnavailableView("기록을 찾을 수 없습니다", systemImage: "doc.questionmark")
      }
    }
    .sheet(item: $editing) { item in WorkoutEditor(store: store, places: places, record: item) }
    .confirmationDialog("이 기기의 개인 기록을 삭제할까요? 건강 원본은 유지됩니다.", isPresented: $confirmingDelete) {
      Button("개인 기록 삭제", role: .destructive) {
        do { try store.remove(id); dismiss() } catch { self.error = error.localizedDescription }
      }
    }
  }

  @MainActor private func exportToHealth() async {
    guard var item = record, !savingHealth, item.origin != .watch, item.origin != .healthLink else { return }
    savingHealth = true
    error = nil
    defer { savingHealth = false }
    do {
      item.healthExportState = .pending
      item.healthExportMessage = "저장 결과를 확인하는 중입니다."
      try store.save(item)
      let healthID = try await health.save(workout: item)
      guard var current = record else { return }
      current.healthWorkoutID = healthID
      current.healthExportState = .saved
      current.healthExportMessage = nil
      try store.save(current)
    } catch {
      self.error = error.localizedDescription
      if var current = record {
        current.healthExportState = .failed
        current.healthExportMessage = error.localizedDescription
        do { try store.save(current) }
        catch { self.error = "건강 저장 결과를 기기에 보관하지 못했습니다. \(error.localizedDescription)" }
      }
    }
  }
}

struct WorkoutArchiveDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else { throw LocalDataError.unreadable }
    self.data = data
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
