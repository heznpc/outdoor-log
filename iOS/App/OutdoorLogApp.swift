import SwiftUI

@main
struct OutdoorLogApp: App {
  @State private var catalog = CatalogStore(loadImmediately: false)
  @State private var records = RecordStore()
  @State private var health = HealthLibrary()
  @State private var recorder = PhoneWorkoutController()
  @StateObject private var watch = WatchLink()

  var body: some Scene {
    WindowGroup {
      OutdoorLogRoot(catalog: catalog, records: records, health: health, recorder: recorder, watch: watch)
    }
  }
}

private struct OutdoorLogRoot: View {
  let catalog: CatalogStore
  let records: RecordStore
  let health: HealthLibrary
  let recorder: PhoneWorkoutController
  @ObservedObject var watch: WatchLink
  @State private var editing: PersonalWorkout?
  @State private var recordingPlace: PlaceChoice?
  @State private var healthAttachmentError: String?
  @Environment(\.scenePhase) private var scenePhase

  private var places: [PlaceChoice] {
    catalog.recordPlaceChoices
  }

  var body: some View {
    TabView {
      ExploreView(store: catalog) { id, name in
        recordingPlace = PlaceChoice(id: id, name: name)
      }
      .tabItem { Label("기구 찾기", systemImage: "map") }

      HealthView(library: health) { workout in
        do { editing = try records.recordForHealthAttachment(workout) }
        catch { healthAttachmentError = error.localizedDescription }
      }
      .tabItem { Label("건강", systemImage: "heart") }

      RecordsView(store: records, health: health, recorder: recorder, places: places, watch: watch)
        .tabItem { Label("나의 운동", systemImage: "figure.strengthtraining.traditional") }
    }
    .sheet(item: $editing) { record in
      WorkoutEditor(store: records, places: places, record: record)
    }
    .sheet(item: $recordingPlace) { place in
      PlaceWorkoutSheet(place: place, records: records, recorder: recorder, watch: watch, places: places)
    }
    .alert("건강 기록 연결 실패", isPresented: Binding(
      get: { healthAttachmentError != nil },
      set: { if !$0 { healthAttachmentError = nil } })) {
      Button("확인", role: .cancel) { healthAttachmentError = nil }
    } message: {
      Text(healthAttachmentError ?? "")
    }
    .task {
      watch.onCompleted = { record in records.acceptWatch(record) }
      watch.activate()
      await catalog.loadIfNeeded()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        if !records.ready { records.reload() }
        if !recorder.ready { recorder.reload() }
        watch.activate()
      } else {
        health.clearReadResults()
      }
    }
    .environment(\.workoutPlaceCatalogRevision, catalog.revision)
  }
}

private struct PlaceWorkoutSheet: View {
  @Environment(\.dismiss) private var dismiss
  let place: PlaceChoice
  let records: RecordStore
  let recorder: PhoneWorkoutController
  @ObservedObject var watch: WatchLink
  let places: [PlaceChoice]
  @State private var editing: PersonalWorkout?

  var body: some View {
    NavigationStack {
      Form {
        Section("iPhone에서 기록") {
          PhoneWorkoutPanel(controller: recorder, store: records, placeID: place.id, placeName: place.name)
        }
        WatchStatusView(link: watch, placeID: place.id, placeName: place.name)
        Section {
          Button("지난 운동 직접 입력") {
            let now = Date()
            editing = PersonalWorkout(title: "\(place.name) 운동", kind: .strength,
              startedAt: now, endedAt: now, placeID: place.id, placeName: place.name)
          }
        }
      }
      .navigationTitle(place.name)
      .toolbar { Button("닫기") { dismiss() } }
      .sheet(item: $editing) { record in WorkoutEditor(store: records, places: places, record: record) }
    }
  }
}
