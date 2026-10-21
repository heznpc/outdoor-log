import Foundation

enum WorkoutKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case walking, running, strength, cycling, flexibility, other
  var id: String { rawValue }
  var title: String {
    switch self {
    case .walking: return "걷기"
    case .running: return "달리기"
    case .strength: return "근력 운동"
    case .cycling: return "자전거"
    case .flexibility: return "스트레칭"
    case .other: return "기타 운동"
    }
  }
  var symbol: String {
    switch self {
    case .walking: return "figure.walk"
    case .running: return "figure.run"
    case .strength: return "dumbbell"
    case .cycling: return "figure.outdoor.cycle"
    case .flexibility: return "figure.flexibility"
    case .other: return "figure.cooldown"
    }
  }
}

struct ExerciseSet: Codable, Identifiable, Equatable, Sendable {
  var id = UUID()
  var repetitions = 0
  var weightKilograms: Double?
  var durationSeconds: Int?
}

struct ExerciseEntry: Codable, Identifiable, Equatable, Sendable {
  var id = UUID()
  var name: String
  var sets: [ExerciseSet] = []
}

struct WorkoutPause: Codable, Equatable, Sendable {
  var startedAt: Date
  var endedAt: Date
}

enum HealthExportState: String, Codable, Sendable {
  case notRequested, pending, saved, failed
}

enum WorkoutOrigin: String, Codable, Sendable {
  case phone, watch, healthLink
}

struct PersonalWorkout: Codable, Identifiable, Equatable, Sendable {
  var id = UUID()
  var title: String
  var kind: WorkoutKind
  var startedAt: Date
  var endedAt: Date
  var activeDurationSeconds: Double?
  var pauses: [WorkoutPause] = []
  var placeID: String?
  var placeName: String?
  var notes = ""
  var exercises: [ExerciseEntry] = []
  var healthWorkoutID: UUID?
  // Preserve the local ID when a workout linked from Health later arrives from Watch.
  var watchSourceIDs: Set<UUID>?
  var timingEditedLocally: Bool?
  var healthExportState: HealthExportState = .notRequested
  var healthExportMessage: String?
  var origin: WorkoutOrigin = .phone
  var modifiedAt = Date()

  var duration: TimeInterval { activeDurationSeconds ?? max(0, endedAt.timeIntervalSince(startedAt)) }

  func validate() throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      title.count <= 160, notes.count <= 10_000,
      (placeID?.count ?? 0) <= 200, (placeName?.count ?? 0) <= 300,
      (watchSourceIDs?.count ?? 0) <= 100,
      endedAt >= startedAt, duration.isFinite, duration >= 0, duration <= 7 * 24 * 3600,
      duration <= endedAt.timeIntervalSince(startedAt) + 1,
      pauses.count <= 1000, pauses.allSatisfy({ $0.startedAt >= startedAt && $0.endedAt >= $0.startedAt && $0.endedAt <= endedAt }),
      endedAt <= Date().addingTimeInterval(300),
      exercises.count <= 100,
      Set(exercises.map(\.id)).count == exercises.count,
      exercises.allSatisfy({ exercise in
        !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && exercise.name.count <= 160
          && exercise.sets.count <= 100 && Set(exercise.sets.map(\.id)).count == exercise.sets.count
          && exercise.sets.allSatisfy { set in
            (0...10_000).contains(set.repetitions)
              && (set.weightKilograms.map { $0.isFinite && (0...2000).contains($0) } ?? true)
              && (set.durationSeconds.map { (0...86400).contains($0) } ?? true)
          }
      }) else { throw LocalDataError.invalidRecord }
    for index in pauses.indices.dropFirst() {
      guard pauses[index - 1].endedAt <= pauses[index].startedAt else { throw LocalDataError.invalidRecord }
    }
    if healthExportState == .saved && healthWorkoutID == nil { throw LocalDataError.invalidRecord }
  }
}

enum LocalDataError: LocalizedError {
  case invalidRecord, unreadable, unsupportedVersion, storageUnavailable, archiveTooLarge
  var errorDescription: String? {
    switch self {
    case .invalidRecord: return "기록의 이름, 시간 또는 운동 수치를 확인해 주세요."
    case .unreadable: return "저장된 데이터를 읽지 못했습니다. 원본 파일을 유지했습니다."
    case .unsupportedVersion: return "더 새로운 앱에서 저장한 데이터입니다. 앱을 업데이트해 주세요."
    case .storageUnavailable: return "기기에 저장하지 못했습니다. 저장 공간과 기기 잠금을 확인해 주세요."
    case .archiveTooLarge: return "기록 보관 한도를 넘었습니다. 기존 기록은 그대로 유지했습니다. 먼저 기록을 내보내고 오래된 기록을 정리해 주세요."
    }
  }
}

struct WatchWorkoutState: Codable, Equatable, Sendable {
  enum Phase: String, Codable, Sendable { case idle, running, paused, saving, finished, failed }
  var sessionID: UUID?
  var phase: Phase = .idle
  var kind: WorkoutKind = .strength
  var startedAt: Date?
  var elapsedSeconds: Double = 0
  var heartRate: Double?
  var activeEnergyKilocalories: Double?
  var distanceMeters: Double?
  var placeID: String?
  var placeName: String?
  var updatedAt = Date()
  var message: String?
}

struct WatchCommand: Codable, Identifiable, Sendable {
  enum Action: String, Codable, Sendable { case start, pause, resume, finish }
  var id = UUID()
  var action: Action
  var sessionID: UUID?
  var kind: WorkoutKind = .strength
  var placeID: String?
  var placeName: String?
  var issuedAt = Date()
}

struct WatchPacket: Codable, Sendable {
  enum Kind: String, Codable, Sendable { case state, completed, command, acknowledgement }
  var version = 1
  var kind: Kind
  var state: WatchWorkoutState?
  var workout: PersonalWorkout?
  var command: WatchCommand?
  var acknowledgedWorkoutID: UUID?
  static let payloadKey = "outdoorlog.payload"
}
