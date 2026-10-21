import SwiftUI

struct HealthView: View {
  @Environment(\.scenePhase) private var scenePhase
  let library: HealthLibrary
  let onAttach: (HealthWorkoutSummary) -> Void
  @State private var period = HealthPeriod.month
  @State private var customStart = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
  @State private var refreshNumber = 0
  @State private var requesting = false
  @State private var requestError: String?
  @State private var selectedWorkout: HealthWorkoutSummary?

  private var days: Int {
    period.days ?? max(1, (Calendar.current.dateComponents([.day],
      from: Calendar.current.startOfDay(for: customStart),
      to: Calendar.current.startOfDay(for: Date())).day ?? 0) + 1)
  }
  private var refreshKey: String { "\(days)-\(scenePhase == .active)-\(refreshNumber)" }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("건강 앱에서 현재 읽을 수 있는 기록을 조회합니다. Apple Watch 기록은 건강에 반영된 뒤 여기에서 확인할 수 있습니다.")
            .font(.subheadline)
          Text("빈 항목은 기록이 없거나 읽기 접근이 제공되지 않은 상태입니다. 앱은 두 경우를 구분할 수 없습니다.")
            .font(.footnote).foregroundStyle(.secondary)
          Text("접근 변경은 건강 앱의 앱별 접근 설정에서 관리합니다. 요청 완료가 읽기 허용을 뜻하지는 않습니다.")
            .font(.footnote).foregroundStyle(.secondary)
          if !library.available {
            Label("이 기기에서는 건강 데이터를 사용할 수 없습니다.", systemImage: "heart.slash")
          } else {
            Button {
              requesting = true
              requestError = nil
              Task { @MainActor in
                defer { requesting = false }
                do {
                  try await library.requestReadAccess()
                  refreshNumber += 1
                } catch { requestError = error.localizedDescription }
              }
            } label: {
              if requesting { ProgressView("건강 접근 요청 중") }
              else {
                Label(library.readRequested ? "건강 읽기 접근 확인" : "건강 읽기 접근 요청", systemImage: "heart.text.square")
              }
            }
            .disabled(requesting)
          }
          if let requestError { Text(requestError).foregroundStyle(.red) }
        }

        if library.available && library.readRequested {
          Section {
            Picker("조회 기간", selection: $period) {
              ForEach(HealthPeriod.allCases) { Text($0.title).tag($0) }
            }
            if period == .custom {
              DatePicker("시작 날짜", selection: $customStart, in: ...Date(), displayedComponents: .date)
            }
            Text("오늘을 포함한 \(days)일 · 현재 기기의 달력·시간대 기준")
              .font(.footnote).foregroundStyle(.secondary)
            if library.loading { ProgressView("건강 기록을 조회하고 있습니다") }
            if let date = library.lastRefresh {
              Text("조회 시각 \(date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = library.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
          } header: { Text("조회 범위") }

          Section {
            HealthMetricRow(title: "걸음 수", values: library.dailyMetrics.map(\.steps),
              unit: "걸음", scale: 1, state: library.metricStates[.steps])
            HealthMetricRow(title: "걷기·달리기 거리", values: library.dailyMetrics.map(\.distanceMeters),
              unit: "km", scale: 1000, state: library.metricStates[.distance])
            HealthMetricRow(title: "활동 에너지", values: library.dailyMetrics.map(\.activeEnergyKilocalories),
              unit: "kcal", scale: 1, state: library.metricStates[.energy])
          } header: { Text("읽은 값의 합계") }
          footer: { Text("읽을 수 있는 날과 항목만 합산합니다. 이 값이 전체 활동량이나 권한 허용을 의미하지는 않습니다.") }

          if !library.dailyMetrics.isEmpty {
            Section("날짜별 기록") {
              DisclosureGroup("일별 수치 보기") {
                ForEach(library.dailyMetrics.reversed()) { day in
                  VStack(alignment: .leading, spacing: 7) {
                    Text(day.date.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                    Text("걸음 수: \(HealthText.number(day.steps)) 걸음")
                    Text("걷기·달리기: \(HealthText.number(day.distanceMeters.map { $0 / 1000 }, fraction: 2)) km")
                    Text("활동 에너지: \(HealthText.number(day.activeEnergyKilocalories)) kcal")
                  }
                  .font(.subheadline).padding(.vertical, 4)
                }
              }
            }
          }

          Section {
            switch library.workoutState {
            case .loading: ProgressView("운동 목록 조회 중")
            case .failed(let message): Text(message).foregroundStyle(.secondary)
            case .noReadableData:
              Text("이 기간에 읽을 수 있는 운동이 없습니다. 기록이 없거나 읽기 접근이 제공되지 않았을 수 있습니다.")
                .foregroundStyle(.secondary)
            default: EmptyView()
            }
            ForEach(library.workouts) { workout in
              Button { selectedWorkout = workout } label: {
                HealthWorkoutRow(workout: workout)
              }
              .buttonStyle(.plain)
              .accessibilityHint("운동 상세 정보와 개인 기록 연결 열기")
            }
          } header: { Text("건강 운동 \(library.workouts.count)개") }
          footer: { Text("운동을 열어 출처와 측정값을 확인하거나 개인 기록에 연결할 수 있습니다. 원본 운동은 변경하지 않습니다.") }
        }
      }
      .navigationTitle("건강 기록")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("새로 고침", systemImage: "arrow.clockwise") { refreshNumber += 1 }
            .disabled(!library.available || !library.readRequested || library.loading)
        }
      }
      .refreshable { if scenePhase == .active { await library.refresh(days: days) } }
      .task(id: refreshKey) {
        guard scenePhase == .active else { return }
        await library.refresh(days: days)
      }
      .onChange(of: scenePhase) { _, value in
        if value != .active { library.clearReadResults() }
      }
      .sheet(item: $selectedWorkout) { selected in
        HealthWorkoutDetailView(library: library, workoutID: selected.id, onAttach: onAttach)
      }
    }
  }
}

private enum HealthPeriod: String, CaseIterable, Identifiable {
  case week, month, quarter, year, custom
  var id: String { rawValue }
  var title: String {
    switch self {
    case .week: return "7일"
    case .month: return "30일"
    case .quarter: return "90일"
    case .year: return "365일"
    case .custom: return "시작 날짜 선택"
    }
  }
  var days: Int? {
    switch self {
    case .week: return 7
    case .month: return 30
    case .quarter: return 90
    case .year: return 365
    case .custom: return nil
    }
  }
}

private struct HealthMetricRow: View {
  let title: String
  let values: [Double?]
  let unit: String
  let scale: Double
  let state: HealthReadState?

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.subheadline)
      if let total = HealthValues.readableTotal(values) {
        Text("\(HealthText.number(total / scale, fraction: scale == 1 ? 0 : 2)) \(unit)")
          .font(.title3).bold().monospacedDigit()
        Text("\(values.compactMap { $0 }.count)일의 읽은 값")
          .font(.caption).foregroundStyle(.secondary)
      } else if state == .loading {
        Text("조회 중").foregroundStyle(.secondary)
      } else if case .failed(let message)? = state {
        Text(message).font(.footnote).foregroundStyle(.secondary)
      } else {
        Text("읽을 수 있는 값 없음").foregroundStyle(.secondary)
      }
    }.padding(.vertical, 3)
  }
}

private struct HealthWorkoutRow: View {
  let workout: HealthWorkoutSummary
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(workout.title, systemImage: workout.kind.symbol).font(.headline)
        .foregroundStyle(.primary)
      Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
      Text("\(HealthText.duration(workout.duration)) · \(workout.sourceName)")
      if workout.manuallyEntered { Text("수동 입력 운동") }
    }
    .font(.subheadline).foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

private struct HealthWorkoutDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  let library: HealthLibrary
  let workoutID: UUID
  let onAttach: (HealthWorkoutSummary) -> Void
  @State private var detail: HealthWorkoutDetail?
  @State private var loading = true
  @State private var error: String?
  @State private var retry = 0

  private var refreshKey: String {
    "\(scenePhase == .active)-\(library.lastRefresh?.timeIntervalSince1970 ?? 0)-\(retry)"
  }

  var body: some View {
    NavigationStack {
      List {
        if loading { ProgressView("운동 상세 정보 조회 중") }
        if let error {
          Section {
            Text(error).foregroundStyle(.secondary)
            Button("다시 시도") { retry += 1 }
          }
        }
        if let detail {
          let workout = detail.workout
          Section("운동") {
            Text(workout.title).font(.title2).bold()
            HealthDetailLine(title: "시작", value: workout.startedAt.formatted(date: .abbreviated, time: .shortened))
            HealthDetailLine(title: "종료", value: workout.endedAt.formatted(date: .abbreviated, time: .shortened))
            HealthDetailLine(title: "건강의 운동 시간", value: HealthText.duration(workout.duration))
            HealthDetailLine(title: "출처", value: workout.sourceName)
            if workout.manuallyEntered { Text("사용자가 수동으로 입력한 운동입니다.").font(.footnote) }
          }
          Section {
            HealthDetailLine(title: "거리", value: HealthText.value(workout.distanceMeters.map { $0 / 1000 }, unit: "km", fraction: 2))
            HealthDetailLine(title: "활동 에너지", value: HealthText.value(workout.activeEnergyKilocalories, unit: "kcal"))
            HealthDetailLine(title: "평균 심박수", value: HealthText.value(detail.heartRate.average, unit: "회/분"))
            HealthDetailLine(title: "최저 심박수", value: HealthText.value(detail.heartRate.minimum, unit: "회/분"))
            HealthDetailLine(title: "최고 심박수", value: HealthText.value(detail.heartRate.maximum, unit: "회/분"))
            if let notice = detail.heartRateNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
          } header: { Text("읽을 수 있는 측정값") }
          footer: { Text("심박수는 이 운동에 연결된 샘플만 조회합니다. 값이 없으면 측정되지 않았거나 읽기 접근이 제공되지 않았을 수 있습니다.") }
          Section {
            Button("개인 기록에 연결", systemImage: "link") {
              onAttach(workout)
              dismiss()
            }
          } footer: { Text("운동 제목과 시간을 개인 기록으로 저장하고 원본 운동의 식별자를 연결합니다. 이후 장소·세트·메모를 추가할 수 있으며 건강의 원본은 수정하지 않습니다.") }
        }
      }
      .navigationTitle("건강 운동")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
      .task(id: refreshKey) {
        detail = nil
        error = nil
        loading = true
        guard scenePhase == .active, !library.loading else { return }
        do {
          let result = try await library.detail(id: workoutID)
          try Task.checkCancellation()
          detail = result
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
        loading = false
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { detail = nil; error = nil; loading = true }
      }
    }
  }
}

private struct HealthDetailLine: View {
  let title: String
  let value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }.padding(.vertical, 2)
  }
}

private enum HealthText {
  static func number(_ value: Double?, fraction: Int = 0) -> String {
    guard let value = HealthValues.nonnegative(value) else { return "—" }
    return value.formatted(.number.precision(.fractionLength(0...fraction)))
  }
  static func value(_ value: Double?, unit: String, fraction: Int = 0) -> String {
    guard let value = HealthValues.nonnegative(value) else { return "읽을 수 있는 값 없음" }
    return "\(number(value, fraction: fraction)) \(unit)"
  }
  static func duration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "시간 정보 없음" }
    let total = Int(seconds)
    if total >= 3600 { return "\(total / 3600)시간 \(total % 3600 / 60)분" }
    if total >= 60 { return "\(total / 60)분 \(total % 60)초" }
    return "\(total)초"
  }
}
