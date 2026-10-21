import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WatchLink: NSObject, ObservableObject {
  @Published private(set) var state = WatchWorkoutState()
  @Published private(set) var isReachable = false
  @Published private(set) var isPaired = false
  @Published private(set) var notice: String?
  @Published private(set) var isSending = false

  /// Return true only after the phone has durably merged this exact revision by workout ID.
  var onCompleted: ((PersonalWorkout) -> Bool)? {
    didSet { drainPendingCompletions() }
  }

  private var session: WCSession?
  private var pendingCompletions: [UUID: PersonalWorkout] = [:]
  private var replies: [UUID: CheckedContinuation<Data, Error>] = [:]
  private var timeouts: [UUID: Task<Void, Never>] = [:]

  override init() {
    super.init()
    // A new local idle timestamp must not mask a previously received Watch state.
    state.updatedAt = .distantPast
  }

  func activate() {
    guard WCSession.isSupported() else {
      notice = "이 기기에서는 Apple Watch 연결을 사용할 수 없습니다."
      return
    }
    let session = WCSession.default
    self.session = session
    session.delegate = self
    session.activate()
  }

  func send(_ command: WatchCommand) async throws {
    guard !isSending else { throw WatchWireError.busy }
    guard let session, session.activationState == .activated, session.isPaired,
      session.isWatchAppInstalled, session.isReachable else { throw WatchWireError.unavailable }
    guard command.issuedAt > Date().addingTimeInterval(-WatchWire.commandLifetime) else {
      throw WatchWireError.expiredCommand
    }
    let data = try WatchWire.encode(WatchPacket(kind: .command, command: command))
    isSending = true
    notice = nil
    defer { isSending = false }
    do {
      let response: Data = try await withCheckedThrowingContinuation { continuation in
        replies[command.id] = continuation
        timeouts[command.id] = Task { [weak self] in
          try? await Task.sleep(nanoseconds: 25_000_000_000)
          guard !Task.isCancelled else { return }
          self?.resolve(command.id, result: .failure(WatchWireError.rejected(
            "Watch 응답이 늦습니다. 요청 결과가 아직 확인되지 않았으니 Watch의 현재 상태를 확인해 주세요.")))
        }
        session.sendMessageData(data, replyHandler: { [weak self] response in
          Task { @MainActor in self?.resolve(command.id, result: .success(response)) }
        }, errorHandler: { [weak self] error in
          Task { @MainActor in self?.resolve(command.id, result: .failure(error)) }
        })
      }
      let reply = try WatchCommandReply.decode(response, commandID: command.id)
      apply(reply.state)
      guard reply.accepted else { throw WatchWireError.rejected(reply.message ?? "Watch에서 요청을 처리하지 못했습니다.") }
      notice = reply.message
    } catch {
      notice = error.localizedDescription
      throw error
    }
  }

  private func resolve(_ id: UUID, result: Result<Data, Error>) {
    timeouts.removeValue(forKey: id)?.cancel()
    replies.removeValue(forKey: id)?.resume(with: result)
  }

  private func apply(_ incoming: WatchWorkoutState) {
    guard WatchWire.shouldApply(incoming, after: state) else { return }
    state = incoming
  }

  private func receive(_ data: Data) {
    do {
      let packet = try WatchWire.decode(data)
      switch packet.kind {
      case .state: if let state = packet.state { apply(state) }
      case .completed:
        guard let workout = packet.workout else { return }
        if let previous = pendingCompletions[workout.id], previous.modifiedAt > workout.modifiedAt { return }
        pendingCompletions[workout.id] = workout
        drainPendingCompletions()
      default: break
      }
    } catch { notice = error.localizedDescription }
  }

  private func drainPendingCompletions() {
    guard let onCompleted else { return }
    for workout in Array(pendingCompletions.values) {
      guard onCompleted(workout) else {
        notice = "Watch 기록을 iPhone에 저장하지 못했습니다. Watch 원본을 보관하고 다시 전송합니다."
        continue
      }
      // Acknowledgement occurs strictly after the application's durable write.
      do {
        let data = try WatchWire.encode(WatchPacket(kind: .acknowledgement, workout: workout,
          acknowledgedWorkoutID: workout.id))
        guard let session, session.activationState == .activated else { continue }
        session.transferUserInfo([WatchPacket.payloadKey: data])
        if session.isReachable { session.sendMessageData(data, replyHandler: nil, errorHandler: nil) }
        pendingCompletions.removeValue(forKey: workout.id)
      } catch { notice = error.localizedDescription }
    }
  }

  private func refreshConnection(_ session: WCSession) {
    isReachable = session.isReachable
    isPaired = session.isPaired
    if !session.isPaired { notice = "iPhone에 Apple Watch를 페어링해 주세요." }
    else if !session.isWatchAppInstalled { notice = "Apple Watch에 OutdoorLog 앱을 설치해 주세요." }
    if let data = session.receivedApplicationContext[WatchPacket.payloadKey] as? Data { receive(data) }
    drainPendingCompletions()
  }
}

extension WatchLink: WCSessionDelegate {
  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?) {
    Task { @MainActor in
      if let error { self.notice = error.localizedDescription }
      self.refreshConnection(session)
    }
  }

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
    Task { @MainActor in self.isReachable = false }
  }

  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
    Task { @MainActor in
      self.state = WatchWorkoutState()
      self.state.updatedAt = .distantPast
      self.refreshConnection(session)
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in self.refreshConnection(session) }
  }

  nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in self.refreshConnection(session) }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    guard let data = applicationContext[WatchPacket.payloadKey] as? Data else { return }
    Task { @MainActor in self.receive(data) }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    guard let data = userInfo[WatchPacket.payloadKey] as? Data else { return }
    Task { @MainActor in self.receive(data) }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
    Task { @MainActor in self.receive(messageData) }
  }
}
