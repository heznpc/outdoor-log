import Foundation

enum WatchWireError: LocalizedError {
  case invalidPayload, unsupportedVersion, tooLarge, expiredCommand, wrongSession, unavailable, busy
  case rejected(String)

  var errorDescription: String? {
    switch self {
    case .invalidPayload: return "Watch 메시지 형식을 확인하지 못했습니다."
    case .unsupportedVersion: return "iPhone과 Watch 앱을 모두 업데이트해 주세요."
    case .tooLarge: return "Watch에서 보낼 수 있는 기록 크기를 초과했습니다."
    case .expiredCommand: return "요청 시간이 지났습니다. 현재 운동 상태를 확인하고 다시 눌러 주세요."
    case .wrongSession: return "다른 운동의 요청입니다. 현재 운동 상태를 확인해 주세요."
    case .unavailable: return "Watch 앱을 열고 연결을 확인한 다음 다시 눌러 주세요."
    case .busy: return "이전 요청을 처리하고 있습니다. 잠시 후 상태를 확인해 주세요."
    case .rejected(let message): return message
    }
  }
}

/// Included in both app targets. Live commands are never placed in a background queue.
enum WatchWire {
  static let maximumBytes = 48 * 1024
  static let commandLifetime: TimeInterval = 30

  static func encode(_ packet: WatchPacket) throws -> Data {
    try validate(packet)
    let data = try JSONEncoder().encode(packet)
    guard data.count <= maximumBytes else { throw WatchWireError.tooLarge }
    return data
  }

  static func decode(_ data: Data) throws -> WatchPacket {
    guard data.count <= maximumBytes else { throw WatchWireError.tooLarge }
    let packet = try JSONDecoder().decode(WatchPacket.self, from: data)
    try validate(packet)
    return packet
  }

  static func validate(_ packet: WatchPacket) throws {
    guard packet.version == 1 else { throw WatchWireError.unsupportedVersion }
    switch packet.kind {
    case .state:
      guard let state = packet.state, packet.command == nil, packet.workout == nil else {
        throw WatchWireError.invalidPayload
      }
      try validate(state)
    case .command:
      guard let command = packet.command, packet.state == nil, packet.workout == nil,
        command.sessionID != nil, (command.placeID?.count ?? 0) <= 200,
        (command.placeName?.count ?? 0) <= 200,
        command.issuedAt.timeIntervalSince1970.isFinite else { throw WatchWireError.invalidPayload }
    case .completed:
      guard let workout = packet.workout, packet.command == nil, packet.state == nil,
        workout.origin == .watch, workout.healthExportState == .saved || workout.healthExportState == .failed,
        workout.healthExportState != .saved || workout.healthWorkoutID != nil else {
        throw WatchWireError.invalidPayload
      }
      try workout.validate()
    case .acknowledgement:
      // Echo the exact durable revision, so a late ack cannot remove a newer corrected record.
      guard let id = packet.acknowledgedWorkoutID, let workout = packet.workout,
        workout.id == id, packet.command == nil, packet.state == nil else {
        throw WatchWireError.invalidPayload
      }
      try workout.validate()
    }
  }

  static func validate(_ state: WatchWorkoutState) throws {
    guard state.elapsedSeconds.isFinite, (0...604_800).contains(state.elapsedSeconds),
      [state.heartRate, state.activeEnergyKilocalories, state.distanceMeters].allSatisfy({
        $0.map { $0.isFinite && $0 >= 0 } ?? true
      }), (state.placeID?.count ?? 0) <= 200, (state.placeName?.count ?? 0) <= 200,
      (state.message?.count ?? 0) <= 2000, state.updatedAt.timeIntervalSince1970.isFinite,
      state.startedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
      state.phase == .idle || state.sessionID != nil else { throw WatchWireError.invalidPayload }
  }

  static func validateCommand(_ command: WatchCommand, state: WatchWorkoutState, now: Date = Date()) throws {
    guard command.issuedAt.timeIntervalSince(now) <= 5,
      now.timeIntervalSince(command.issuedAt) <= commandLifetime else { throw WatchWireError.expiredCommand }
    guard let id = command.sessionID else { throw WatchWireError.wrongSession }
    if command.action == .start {
      guard ![.running, .paused, .saving].contains(state.phase) else { throw WatchWireError.busy }
      guard id != state.sessionID else { throw WatchWireError.wrongSession }
    } else {
      guard id == state.sessionID else { throw WatchWireError.wrongSession }
      switch command.action {
      case .pause: guard state.phase == .running else { throw WatchWireError.wrongSession }
      case .resume: guard state.phase == .paused else { throw WatchWireError.wrongSession }
      case .finish: guard [.running, .paused].contains(state.phase) else { throw WatchWireError.wrongSession }
      case .start: break
      }
    }
  }

  static func shouldApply(_ incoming: WatchWorkoutState, after current: WatchWorkoutState) -> Bool {
    incoming.updatedAt > current.updatedAt
  }

  static func matchesAcknowledgement(_ packet: WatchPacket, workout: PersonalWorkout) -> Bool {
    packet.kind == .acknowledgement && packet.acknowledgedWorkoutID == workout.id
      && packet.workout == workout
  }
}

struct WatchCommandReply: Codable {
  var version = 1
  var commandID: UUID
  var accepted: Bool
  var state: WatchWorkoutState
  var message: String?

  func encoded() throws -> Data {
    try WatchWire.validate(state)
    let data = try JSONEncoder().encode(self)
    guard data.count <= WatchWire.maximumBytes else { throw WatchWireError.tooLarge }
    return data
  }

  static func decode(_ data: Data, commandID: UUID) throws -> Self {
    guard data.count <= WatchWire.maximumBytes else { throw WatchWireError.tooLarge }
    let reply = try JSONDecoder().decode(Self.self, from: data)
    guard reply.version == 1, reply.commandID == commandID, (reply.message?.count ?? 0) <= 2000 else {
      throw WatchWireError.invalidPayload
    }
    try WatchWire.validate(reply.state)
    return reply
  }
}
