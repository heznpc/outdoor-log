import Foundation

struct HealthWorkoutSummary: Identifiable, Equatable, Sendable {
  let id: UUID
  let kind: WorkoutKind
  let title: String
  let startedAt: Date
  let endedAt: Date
  let sourceName: String
  let duration: TimeInterval
  let distanceMeters: Double?
  let activeEnergyKilocalories: Double?
  let manuallyEntered: Bool
  var pauses: [WorkoutPause] = []
}

struct HealthDailyMetrics: Identifiable, Equatable, Sendable {
  var id: Date { date }
  let date: Date
  var steps: Double?
  var distanceMeters: Double?
  var activeEnergyKilocalories: Double?
}

enum HealthMetric: String, CaseIterable, Sendable {
  case steps, distance, energy
  var title: String {
    switch self {
    case .steps: return "걸음 수"
    case .distance: return "걷기·달리기 거리"
    case .energy: return "활동 에너지"
    }
  }
}

enum HealthReadState: Equatable, Sendable {
  case notRequested, loading, readable, noReadableData, failed(String)
}

struct HealthHeartRate: Equatable, Sendable {
  let average: Double?
  let minimum: Double?
  let maximum: Double?
}

struct HealthWorkoutDetail: Sendable {
  let workout: HealthWorkoutSummary
  let heartRate: HealthHeartRate
  let heartRateNotice: String?
}

/// A calendar-day window: advancing a day does not assume that it lasts 24 hours.
struct HealthDateWindow {
  let start: Date
  let end: Date
  let days: [Date]
  let calendar: Calendar

  init?(days count: Int, now: Date, calendar: Calendar = .current) {
    guard count > 0,
      let start = calendar.date(byAdding: .day, value: 1 - count, to: calendar.startOfDay(for: now))
    else { return nil }
    var dates: [Date] = []
    var cursor = start
    while cursor <= now {
      dates.append(cursor)
      guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { return nil }
      cursor = next
    }
    self.start = start
    self.end = now
    self.days = dates
    self.calendar = calendar
  }
}

enum HealthValues {
  static func nonnegative(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }

  /// Missing samples must remain missing; an entirely unreadable period is not zero.
  static func readableTotal(_ values: [Double?]) -> Double? {
    let readable = values.compactMap { nonnegative($0) }
    guard !readable.isEmpty else { return nil }
    return nonnegative(readable.reduce(0, +))
  }
}

struct HealthExportIdentity: Equatable {
  static let syncVersion = 1
  let localID: UUID
  var syncIdentifier: String { "outdoor-log.personal-workout.\(localID.uuidString.lowercased())" }

  // Millisecond precision avoids equality failures when HealthKit normalizes timestamps.
  static func matches(_ stored: HealthWorkoutSummary, workout: PersonalWorkout) -> Bool {
    let pauses = workout.pauses.filter { $0.endedAt > $0.startedAt }
    let samePauses = stored.pauses.count == pauses.count && zip(stored.pauses, pauses).allSatisfy { pair in
      abs(pair.0.startedAt.timeIntervalSince(pair.1.startedAt)) < 0.001
        && abs(pair.0.endedAt.timeIntervalSince(pair.1.endedAt)) < 0.001
    }
    return stored.kind == workout.kind && stored.title == workout.title
      && abs(stored.startedAt.timeIntervalSince(workout.startedAt)) < 0.001
      && abs(stored.endedAt.timeIntervalSince(workout.endedAt)) < 0.001
      && abs(stored.duration - workout.duration) < 1
      && samePauses && stored.manuallyEntered
  }
}

enum HealthExportTimeline {
  static func validate(_ workout: PersonalWorkout) throws {
    try workout.validate()
    let paused = workout.pauses.reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
    let actualActiveTime = workout.endedAt.timeIntervalSince(workout.startedAt) - paused
    guard abs(actualActiveTime - workout.duration) < 1 else { throw HealthLibraryError.invalidTimeline }
  }
}

enum HealthLibraryError: LocalizedError {
  case unavailable, invalidPeriod, writeDenied, importedWorkout, watchExportPending, saveInProgress
  case saveUnconfirmed, previouslyExportedDifferentRecord, unreadableWorkout, invalidTimeline

  var errorDescription: String? {
    switch self {
    case .unavailable: return "이 기기에서는 건강 데이터를 사용할 수 없습니다."
    case .invalidPeriod: return "조회할 시작 날짜를 확인해 주세요."
    case .writeDenied: return "건강 앱에서 이 앱의 운동 쓰기 권한을 확인해 주세요."
    case .importedWorkout: return "건강에서 연결한 운동은 다시 내보내지 않습니다. 원본은 건강 앱에서 관리해 주세요."
    case .watchExportPending: return "Watch 운동의 건강 저장 결과를 Watch에서 다시 확인해 주세요. iPhone에서 별도 운동을 만들지 않습니다."
    case .saveInProgress: return "이 운동을 건강에 저장하고 있습니다. 잠시 후 다시 확인해 주세요."
    case .saveUnconfirmed: return "건강에 저장되었는지 확인하지 못했습니다. 다시 시도하면 같은 기록을 먼저 조회해 중복 저장을 방지합니다."
    case .previouslyExportedDifferentRecord: return "이 개인 기록의 이전 내용이 이미 건강에 있습니다. 건강의 기존 운동은 자동으로 덮어쓰지 않습니다."
    case .unreadableWorkout: return "이 운동을 현재 읽을 수 없습니다. 삭제 여부, 읽기 권한, 기기 잠금을 확인해 주세요."
    case .invalidTimeline: return "활동 시간과 실제 시작·종료·일시정지 기록이 일치하지 않아 건강에 저장하지 않았습니다."
    }
  }
}
