import SwiftUI

struct WatchStatusView: View {
  @ObservedObject var link: WatchLink
  var placeID: String? = nil
  var placeName: String? = nil
  @State private var kind: WorkoutKind = .strength
  @State private var failure: String?
  @State private var confirmFinish = false

  private var active: Bool { [.running, .paused, .saving].contains(link.state.phase) }

  var body: some View {
    Section("Apple Watch 운동") {
      Label(link.isReachable ? "Watch 연결됨" : "Watch 앱을 열어 주세요", systemImage: "applewatch")
      if active {
        Text(link.state.kind.title).font(.headline)
        if let place = link.state.placeName { Text(place).font(.subheadline) }
        LabeledContent("상태", value: phaseTitle)
        LabeledContent("운동 시간", value: Duration.seconds(link.state.elapsedSeconds).formatted(.time(pattern: .hourMinuteSecond)))
        if let rate = link.state.heartRate { LabeledContent("심박수", value: "\(rate.formatted(.number.precision(.fractionLength(0)))) bpm") }
        if let energy = link.state.activeEnergyKilocalories { LabeledContent("활동 에너지", value: "\(energy.formatted(.number.precision(.fractionLength(0)))) kcal") }
        if let distance = link.state.distanceMeters { LabeledContent("거리", value: "\((distance / 1000).formatted(.number.precision(.fractionLength(2)))) km") }
        if link.state.updatedAt != .distantPast {
          Text("마지막 수신 \(link.state.updatedAt.formatted(date: .omitted, time: .standard))")
            .font(.caption).foregroundStyle(.secondary)
        }
        if link.state.phase == .running { Button("일시 정지") { act(.pause) }.disabled(!canSend) }
        if link.state.phase == .paused { Button("계속하기") { act(.resume) }.disabled(!canSend) }
        if link.state.phase != .saving {
          Button("운동 끝내기", role: .destructive) { confirmFinish = true }.disabled(!canSend)
        }
      } else {
        Picker("운동 종류", selection: $kind) { ForEach(WorkoutKind.allCases) { Text($0.title).tag($0) } }
        if let placeName { Text("운동 장소: \(placeName)") }
        Button("Watch에서 운동 시작") { act(.start) }.disabled(!canSend)
      }
      if link.isSending { ProgressView("Watch 처리 결과 확인 중") }
      if let message = failure ?? link.notice ?? link.state.message {
        Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityLabel("Watch 안내: \(message)")
      }
      Text("연결이 끊겨도 Watch의 운동은 계속됩니다. 완료 기록은 iPhone에 저장된 뒤 Watch 전송 대기열에서 지워집니다.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .confirmationDialog("운동을 끝내고 저장할까요?", isPresented: $confirmFinish, titleVisibility: .visible) {
      Button("운동 끝내기") { act(.finish) }
      Button("취소", role: .cancel) {}
    }
    .task { link.activate() }
  }

  private var canSend: Bool { link.isReachable && !link.isSending }
  private var phaseTitle: String {
    switch link.state.phase {
    case .running: return "기록 중"
    case .paused: return "일시 정지"
    case .saving: return "저장 중"
    case .finished: return "저장 완료"
    case .failed: return "저장 확인 필요"
    case .idle: return "대기 중"
    }
  }

  private func act(_ action: WatchCommand.Action) {
    failure = nil
    let command = WatchCommand(action: action, sessionID: action == .start ? UUID() : link.state.sessionID,
      kind: action == .start ? kind : link.state.kind, placeID: placeID, placeName: placeName)
    Task {
      do { try await link.send(command) }
      catch { failure = error.localizedDescription }
    }
  }
}
