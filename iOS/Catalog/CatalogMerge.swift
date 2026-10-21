import Foundation

enum CatalogMerge {
  /// Replace only a completely downloaded source. Unverifiable file imports
  /// upsert matching IDs, because a portal export can contain a regional subset.
  static func national(_ incoming: CatalogPack, into existing: CatalogPack?, replace: Bool) throws -> CatalogPack {
    try CatalogValidation.validate(incoming)
    if let existing { try CatalogValidation.validate(existing) }
    guard !incoming.places.isEmpty, incoming.places.allSatisfy(\.isNationalEquipment),
      var summary = incoming.sources?.first(where: { $0.id == NationalEquipment.sourceID })
    else { throw CatalogError.invalid("전국 기구 자료의 출처 또는 수집 정보가 없습니다") }
    _ = try requiredCaptureDate(summary.capturedAt)
    let previousSummary = existing?.sources?.first { $0.id == NationalEquipment.sourceID }
    summary.completeCapturedAt = replace ? summary.capturedAt : previousSummary?.completeCapturedAt
    summary.partialCapturedAt = replace ? nil : summary.capturedAt
    var nationalPlaces = Dictionary(uniqueKeysWithValues:
      (replace ? [] : (existing?.places.filter(\.isNationalEquipment) ?? [])).map { ($0.id, $0) })
    for place in incoming.places { nationalPlaces[place.id] = place }
    let merged = nationalPlaces.values.sorted { $0.id < $1.id }
    summary.placeCount = merged.count
    summary.missingCoordinateCount = merged.filter { $0.coordinate == nil }.count
    summary.regions = Set(merged.map(\.regionName)).sorted()
    var sources = existing?.sources?.filter { $0.id != NationalEquipment.sourceID } ?? []
    sources.append(summary)
    let result = CatalogPack(schemaVersion: 1, version: max(existing?.version ?? 1, incoming.version),
      generatedAt: max(existing?.generatedAt ?? "", incoming.generatedAt),
      places: (existing?.places.filter { !$0.isNationalEquipment } ?? []) + merged, sources: sources)
    try CatalogValidation.validate(result)
    return result
  }

  /// A schema-1 cache must not hide a newly shipped national source. Legacy
  /// places and user-imported IDs are kept; only this source is compared.
  static func adoptingBundledNational(_ bundled: CatalogPack, into cached: CatalogPack) throws -> CatalogPack {
    guard let bundledSource = bundled.sources?.first(where: { $0.id == NationalEquipment.sourceID })
    else { return cached }
    let bundledComplete = bundledSource.completeCapturedAt ?? bundledSource.capturedAt
    let bundledDate = try requiredCaptureDate(bundledComplete)
    let cachedSource = cached.sources?.first { $0.id == NationalEquipment.sourceID }
    if let cachedComplete = cachedSource?.completeCapturedAt,
      try requiredCaptureDate(cachedComplete) >= bundledDate { return cached }
    let nationalPack = CatalogPack(schemaVersion: 1, version: bundled.version,
      generatedAt: bundled.generatedAt, places: bundled.places.filter(\.isNationalEquipment), sources: [bundledSource])
    var result = try national(nationalPack, into: cached, replace: true)
    var nationalPlaces = Dictionary(uniqueKeysWithValues: result.places.filter(\.isNationalEquipment).map { ($0.id, $0) })
    // Old caches have no reliable completeness marker. Treat their row dates
    // as evidence without assuming that their latest input was a full snapshot.
    var rowDates: [String: Date] = [:]
    for place in cached.places where place.isNationalEquipment {
      let value = place.provenance.capturedAt
      let date: Date
      if let knownDate = rowDates[value] { date = knownDate }
      else { date = try requiredCaptureDate(value); rowDates[value] = date }
      if date > bundledDate { nationalPlaces[place.id] = place }
    }
    let merged = nationalPlaces.values.sorted { $0.id < $1.id }
    var summary = bundledSource
    summary.completeCapturedAt = bundledComplete
    if let cachedSource,
      try requiredCaptureDate(cachedSource.capturedAt) > requiredCaptureDate(bundledSource.capturedAt) {
      // These fields describe the last input, not the size/date of a full snapshot.
      summary.capturedAt = cachedSource.capturedAt
      summary.rowCount = cachedSource.rowCount
    }
    if let partial = cachedSource?.partialCapturedAt,
      try requiredCaptureDate(partial) > bundledDate {
      summary.partialCapturedAt = try newerCapture(summary.partialCapturedAt, partial)
    }
    summary.placeCount = merged.count
    summary.missingCoordinateCount = merged.filter { $0.coordinate == nil }.count
    summary.regions = Set(merged.map(\.regionName)).sorted()
    result.places = cached.places.filter { !$0.isNationalEquipment } + merged
    result.sources = (cached.sources?.filter { $0.id != NationalEquipment.sourceID } ?? []) + [summary]
    try CatalogValidation.validate(result)
    return result
  }

  /// Packs may partition one source, but each partition must describe the same
  /// capture. Duplicate places or incompatible metadata reject the whole update.
  static func manifest(_ packs: [CatalogPack], version: Int, generatedAt: String) throws -> CatalogPack {
    guard !packs.isEmpty, packs.count <= 100 else { throw CatalogError.invalid("manifest 구성 오류") }
    var places: [EquipmentPlace] = []
    var sources: [String: CatalogSourceSummary] = [:]
    for pack in packs {
      try CatalogValidation.validate(pack)
      guard pack.version == version else { throw CatalogError.invalid("manifest와 파일의 버전이 다릅니다") }
      places.append(contentsOf: pack.places)
      for source in pack.sources ?? [] {
        guard var combined = sources[source.id] else { sources[source.id] = source; continue }
        combined.capturedAt = try matchingCapture(combined.capturedAt, source.capturedAt)
        combined.completeCapturedAt = try matchingOptionalCapture(combined.completeCapturedAt, source.completeCapturedAt)
        combined.partialCapturedAt = try matchingOptionalCapture(combined.partialCapturedAt, source.partialCapturedAt)
        combined.rowCount += source.rowCount
        combined.placeCount += source.placeCount
        combined.missingCoordinateCount += source.missingCoordinateCount
        combined.regions = Set(combined.regions + source.regions).sorted()
        sources[source.id] = combined
      }
    }
    let summaries = sources.values.sorted { $0.id < $1.id }
    let result = CatalogPack(schemaVersion: 1, version: version, generatedAt: generatedAt,
      places: places, sources: summaries.isEmpty ? nil : summaries)
    try CatalogValidation.validate(result)
    return result
  }

  static func captureDate(_ value: String) -> Date? {
    if value.count == 10 {
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "yyyy-MM-dd"
      formatter.isLenient = false
      guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
      return date
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private static func requiredCaptureDate(_ value: String) throws -> Date {
    guard let date = captureDate(value) else { throw CatalogError.invalid("수집일 형식이 올바르지 않습니다") }
    return date
  }

  private static func newerCapture(_ lhs: String?, _ rhs: String) throws -> String {
    guard let lhs else { return rhs }
    return try requiredCaptureDate(lhs) >= requiredCaptureDate(rhs) ? lhs : rhs
  }

  private static func matchingCapture(_ lhs: String, _ rhs: String) throws -> String {
    let date = try requiredCaptureDate(lhs)
    guard date == (try requiredCaptureDate(rhs)) else {
      throw CatalogError.invalid("같은 출처의 묶음 파일 수집일이 서로 다릅니다")
    }
    // Only the spelling differs. Pick deterministically without formatting
    // away fractional-second precision before another partition is compared.
    return min(lhs, rhs)
  }

  private static func matchingOptionalCapture(_ lhs: String?, _ rhs: String?) throws -> String? {
    switch (lhs, rhs) {
    case (nil, nil): return nil
    case let (lhs?, rhs?): return try matchingCapture(lhs, rhs)
    default: throw CatalogError.invalid("같은 출처의 묶음 파일 전체·부분 수집 정보가 서로 다릅니다")
    }
  }
}
