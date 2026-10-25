import SwiftUI

struct WatchRootView: View {
  @ObservedObject var controller: WatchWorkoutController

  var body: some View {
    TabView {
      NavigationStack { WatchWorkoutView(controller: controller) }
        .tabItem { Label("운동", systemImage: "figure.strengthtraining.traditional") }
      NavigationStack { WatchStepsView(controller: controller) }
        .tabItem { Label("걸음", systemImage: "shoeprints.fill") }
      NavigationStack { WatchHistoryView(controller: controller) }
        .tabItem { Label("기록", systemImage: "list.bullet") }
    }
  }
}

private struct WatchWorkoutView: View {
  @ObservedObject var controller: WatchWorkoutController
  @State private var kind: WorkoutKind = .strength
  @State private var showSet = false
  @State private var confirmFinish = false
  @State private var permissionError: String?

  private var active: Bool { [.running, .paused, .saving].contains(controller.state.phase) }

  var body: some View {
    List {
      if active {
        Section(controller.state.kind.title) {
          Text(controller.state.phase == .paused ? "일시 정지" : controller.state.phase == .saving ? "처리 중" : "운동 기록 중")
            .font(.headline)
          Text(Duration.seconds(controller.state.elapsedSeconds).formatted(.time(pattern: .hourMinuteSecond)))
            .font(.title2.monospacedDigit())
            .accessibilityLabel("운동 시간 \(Int(controller.state.elapsedSeconds))초")
          if let place = controller.state.placeName { Label(place, systemImage: "mappin") }
          metric("심박수", value: controller.state.heartRate, suffix: "bpm")
          metric("활동 에너지", value: controller.state.activeEnergyKilocalories, suffix: "kcal")
          if let distance = controller.state.distanceMeters {
            LabeledContent("거리", value: "\((distance / 1000).formatted(.number.precision(.fractionLength(2)))) km")
          }
        }
        if controller.state.phase != .saving {
          Section {
            Button(controller.state.phase == .paused ? "계속하기" : "일시 정지") {
              Task { await controller.perform(controller.state.phase == .paused ? .resume : .pause) }
            }
            Button("세트 추가", systemImage: "plus") { showSet = true }
            Button("운동 끝내기", role: .destructive) { confirmFinish = true }
          }.disabled(controller.isBusy)
        }
        if !controller.exercises.isEmpty {
          Section("기록한 동작") {
            ForEach(controller.exercises) { exercise in
              VStack(alignment: .leading) {
                Text(exercise.name)
                Text("\(exercise.sets.count)세트 · \(exercise.sets.reduce(0) { $0 + $1.repetitions })회")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      } else {
        Section("새 운동") {
          Picker("운동 종류", selection: $kind) {
            ForEach(WorkoutKind.allCases) { Text($0.title).tag($0) }
          }
          Button("운동 시작", systemImage: "play.fill") { Task { await controller.perform(.start, kind: kind) } }
            .disabled(!controller.isReady || controller.isBusy)
          Text("iPhone에서 장소를 선택하고 시작하면 장소 이름도 함께 기록됩니다.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if controller.isBusy { ProgressView("처리 결과 확인 중") }
      if let message = permissionError ?? controller.notice ?? controller.state.message {
        Section("안내") { Text(message).font(.footnote) }
      }
      Section {
        if !controller.isReady {
          Button("저장소 다시 열기") { Task { await controller.activate() } }
        }
        Button("저장·전송 재시도") { Task { await controller.retrySaveAndTransfer() } }
          .disabled(controller.isBusy || !controller.isReady)
        Text("iPhone 저장 확인 대기: \(controller.pendingCount)개").font(.caption)
        Button("운동 저장 권한 확인") {
          Task {
            do { try await controller.requestPermissions(); permissionError = nil }
            catch { permissionError = error.localizedDescription }
          }
        }.disabled(controller.isBusy)
      }
    }
    .navigationTitle("OutdoorLog")
    .sheet(isPresented: $showSet) { WatchSetEntryView(controller: controller) }
    .confirmationDialog("운동을 끝내고 저장할까요?", isPresented: $confirmFinish, titleVisibility: .visible) {
      Button("운동 끝내기") { Task { await controller.perform(.finish) } }
      Button("취소", role: .cancel) {}
    }
  }

  @ViewBuilder private func metric(_ label: String, value: Double?, suffix: String) -> some View {
    if let value { LabeledContent(label, value: "\(value.formatted(.number.precision(.fractionLength(0)))) \(suffix)") }
    else { LabeledContent(label, value: "데이터 없음") }
  }
}

private struct WatchSetEntryView: View {
  @ObservedObject var controller: WatchWorkoutController
  @Environment(\.dismiss) private var dismiss
  @State private var preset = "스쿼트"
  @State private var customName = ""
  @State private var repetitions = 10
  @State private var useWeight = false
  @State private var weight = ""
  @State private var failure: String?
  private let names = ["스쿼트", "푸시업", "턱걸이", "런지", "벤치 프레스", "데드리프트", "직접 입력"]

  var body: some View {
    NavigationStack {
      Form {
        Picker("동작", selection: $preset) { ForEach(names, id: \.self) { Text($0).tag($0) } }
        if preset == "직접 입력" { TextField("동작 이름", text: $customName) }
        Picker("반복 횟수", selection: $repetitions) {
          ForEach(0...100, id: \.self) { Text("\($0)회").tag($0) }
        }
        Toggle("중량 기록", isOn: $useWeight)
        if useWeight { TextField("중량 (kg)", text: $weight) }
        if let failure { Text(failure).font(.footnote) }
        Button("1세트 저장") {
          do {
            let kilograms = useWeight ? Double(weight.replacingOccurrences(of: ",", with: ".")) : nil
            if useWeight && kilograms == nil { throw LocalDataError.invalidRecord }
            try controller.addSet(name: preset == "직접 입력" ? customName : preset,
              repetitions: repetitions, weight: kilograms)
            dismiss()
          } catch { failure = error.localizedDescription }
        }.disabled(controller.isBusy || ![.running, .paused].contains(controller.state.phase))
        Button("취소", role: .cancel) { dismiss() }
      }.navigationTitle("세트 기록")
    }
  }
}

private struct WatchStepsView: View {
  @ObservedObject var controller: WatchWorkoutController
  @State private var failure: String?

  var body: some View {
    List {
      Section("오늘의 걸음") {
        if let steps = controller.todaySteps {
          Text("\(steps.formatted(.number.precision(.fractionLength(0))))걸음").font(.title2)
        } else { Text("걸음 데이터 없음") }
        if let notice = failure ?? controller.stepsNotice { Text(notice).font(.footnote) }
        Text("이 Watch에서 현재 읽을 수 있는 건강 데이터입니다. iPhone과 동기화되기 전에는 합계가 다를 수 있습니다.")
          .font(.caption).foregroundStyle(.secondary)
        Button("권한 확인·새로고침") {
          Task {
            do { try await controller.requestStepPermissions(); failure = nil; await controller.refreshSteps() }
            catch { failure = error.localizedDescription }
          }
        }
      }
    }.navigationTitle("걸음")
  }
}

private struct WatchHistoryView: View {
  @ObservedObject var controller: WatchWorkoutController

  var body: some View {
    List {
      Text("iPhone 저장 확인 대기 \(controller.pendingCount)개").font(.caption)
      if controller.history.isEmpty { Text("Watch에서 완료한 운동이 여기에 표시됩니다.") }
      ForEach(controller.history) { workout in
        NavigationLink {
          WatchHistoryDetail(controller: controller, workoutID: workout.id)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(workout.title)
            Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            Text(workout.healthExportState == .saved ? "건강 앱 저장 완료" : "건강 저장 확인 필요")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Button("전송 재시도") { controller.retryTransfer() }
    }.navigationTitle("운동 기록")
  }
}

private struct WatchHistoryDetail: View {
  @ObservedObject var controller: WatchWorkoutController
  var workoutID: UUID

  var body: some View {
    List {
      if let workout = controller.history.first(where: { $0.id == workoutID }) {
        Text(workout.title).font(.headline)
        Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
        Text(Duration.seconds(workout.duration).formatted(.time(pattern: .hourMinuteSecond)))
        if let place = workout.placeName { Text(place) }
        if !workout.notes.isEmpty { Text(workout.notes).font(.caption) }
        ForEach(workout.exercises) { exercise in
          Section(exercise.name) {
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
              Text("\(index + 1)세트 · \(set.repetitions)회" + (set.weightKilograms.map { " · \($0.formatted()) kg" } ?? ""))
            }
          }
        }
        if workout.healthExportState == .saved {
          Label("건강 앱 저장 완료", systemImage: "checkmark")
          if let message = workout.healthExportMessage { Text(message).font(.footnote) }
        } else {
          if let message = workout.healthExportMessage { Text(message).font(.footnote) }
          Text(controller.healthRetryDescription(for: workout)).font(.footnote)
          Button("건강 저장 재시도·확인") { Task { await controller.retryHealthSave(workout) } }
            .disabled(!controller.isReady || controller.isBusy || [.running, .paused, .saving].contains(controller.state.phase))
        }
        if controller.isBusy { ProgressView("확인 중") }
        if let notice = controller.notice { Text(notice).font(.footnote) }
      } else { Text("기록을 찾을 수 없습니다.") }
    }.navigationTitle("운동 상세")
  }
}
