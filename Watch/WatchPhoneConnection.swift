import Foundation
import WatchConnectivity

@MainActor
final class WatchPhoneConnection: NSObject {
  var onCommand: ((WatchCommand) async -> WatchCommandReply)?
  var onAcknowledgement: ((WatchPacket) -> Void)?
  var onReady: (() -> Void)?
  var onError: ((String) -> Void)?
  private var session: WCSession?
  private var lastState: WatchWorkoutState?
  private var inFlight: [UUID: Task<WatchCommandReply, Never>] = [:]
  private var recentReplies: [UUID: WatchCommandReply] = [:]

  func activate() {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    self.session = session
    session.delegate = self
    session.activate()
  }

  func publish(_ state: WatchWorkoutState) {
    lastState = state
    guard let session, session.activationState == .activated else { return }
    do {
      let data = try WatchWire.encode(WatchPacket(kind: .state, state: state))
      try session.updateApplicationContext([WatchPacket.payloadKey: data])
      if session.isReachable { session.sendMessageData(data, replyHandler: nil, errorHandler: nil) }
    } catch { onError?(error.localizedDescription) }
  }

  func transfer(_ workouts: [PersonalWorkout]) {
    guard let session, session.activationState == .activated else { return }
    for workout in workouts {
      do {
        let queued = session.outstandingUserInfoTransfers.contains { transfer in
          guard let data = transfer.userInfo[WatchPacket.payloadKey] as? Data,
            let packet = try? WatchWire.decode(data) else { return false }
          return packet.kind == .completed && packet.workout == workout
        }
        guard !queued else { continue }
        let data = try WatchWire.encode(WatchPacket(kind: .completed, workout: workout))
        session.transferUserInfo([WatchPacket.payloadKey: data])
        if session.isReachable { session.sendMessageData(data, replyHandler: nil, errorHandler: nil) }
      } catch { onError?(error.localizedDescription) }
    }
  }

  private func receiveAcknowledgement(_ data: Data) {
    do {
      let packet = try WatchWire.decode(data)
      if packet.kind == .acknowledgement { onAcknowledgement?(packet) }
      // Background delivery is deliberately incapable of starting or ending a workout.
    } catch { onError?(error.localizedDescription) }
  }

  private func receiveCommand(_ data: Data) async -> Data {
    do {
      let packet = try WatchWire.decode(data)
      guard packet.kind == .command, let command = packet.command, let onCommand else {
        throw WatchWireError.invalidPayload
      }
      if let reply = recentReplies[command.id] { return try reply.encoded() }
      if let task = inFlight[command.id] { return try await task.value.encoded() }
      let task = Task { await onCommand(command) }
      inFlight[command.id] = task
      let reply = await task.value
      inFlight.removeValue(forKey: command.id)
      if recentReplies.count >= 100 { recentReplies.removeAll() }
      recentReplies[command.id] = reply
      return try reply.encoded()
    } catch {
      onError?(error.localizedDescription)
      // An invalid frame has no trustworthy command ID; an empty reply cannot be mistaken for success.
      return Data()
    }
  }
}

extension WatchPhoneConnection: WCSessionDelegate {
  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?) {
    Task { @MainActor in
      if let error { self.onError?(error.localizedDescription) }
      if activationState == .activated {
        if let state = self.lastState { self.publish(state) }
        self.onReady?()
      }
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in
      if session.isReachable {
        if let state = self.lastState { self.publish(state) }
        self.onReady?()
      }
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
    replyHandler: @escaping (Data) -> Void) {
    Task { @MainActor in replyHandler(await self.receiveCommand(messageData)) }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
    Task { @MainActor in self.receiveAcknowledgement(messageData) }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    guard let data = userInfo[WatchPacket.payloadKey] as? Data else { return }
    Task { @MainActor in self.receiveAcknowledgement(data) }
  }

  nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
    if let error { Task { @MainActor in self.onError?("iPhone 전송을 다시 시도할 수 있습니다: \(error.localizedDescription)") } }
    // Successful transport is not a durable phone acknowledgement. Never remove the outbox here.
  }
}
