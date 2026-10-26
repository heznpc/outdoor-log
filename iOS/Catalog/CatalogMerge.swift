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
    let previousPlaces = Dictionary(uniqueKeysWithValues: (existing?.places ?? []).map { ($0.id, $0) })
    for var place in incoming.places {
      // Keep an evidenced estimate only while the underlying address and data
      // reference date still agree. A new source coordinate always takes priority.
      if place.coordinate == nil, place.coordinateConflict != true,
        let previous = previousPlaces[place.id], let evidence = previous.coordinateEvidence,
        previous.address == place.address, previous.provenance.referenceDate == place.provenance.referenceDate {
        place.latitude = previous.latitude
        place.longitude = previous.longitude
        place.coordinateQuality = previous.coordinateQuality
        place.coordinateEvidence = evidence
      }
      nationalPlaces[place.id] = place
    }
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
  static func manifest(_ packs: [CatalogPack], version: Int, generatedAt: String,
    preservingCoordinatesFrom existing: CatalogPack? = nil) throws -> CatalogPack {
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
        if source.requiresPlaceSourceID == true { combined.requiresPlaceSourceID = true }
        sources[source.id] = combined
      }
    }
    let summaries = sources.values.sorted { $0.id < $1.id }
    var result = CatalogPack(schemaVersion: 1, version: version, generatedAt: generatedAt,
      places: places, sources: summaries.isEmpty ? nil : summaries)
    try CatalogValidation.validate(result)
    guard let existing else { return result }
    try CatalogValidation.validate(existing)
    let publishedPlaces = Dictionary(uniqueKeysWithValues: result.places.map { ($0.id, $0) })
    // A published release can be newer while one of its source captures is
    // older than a direct API refresh or a user's reviewed file. Release
    // numbers do not grant permission to roll that source backwards.
    if let incomingSource = result.sources?.first(where: { $0.id == NationalEquipment.sourceID }),
      let previousSource = existing.sources?.first(where: { $0.id == NationalEquipment.sourceID }) {
      let incoming = CatalogPack(schemaVersion: 1, version: version, generatedAt: generatedAt,
        places: result.places.filter(\.isNationalEquipment), sources: [incomingSource])
      let previous = CatalogPack(schemaVersion: 1, version: existing.version, generatedAt: existing.generatedAt,
        places: existing.places.filter(\.isNationalEquipment), sources: [previousSource])
      let reconciled = try reconcilePublishedNational(incoming, previous: previous)
      result.places = result.places.filter { !$0.isNationalEquipment } + reconciled.places
      result.sources = (result.sources?.filter { $0.id != NationalEquipment.sourceID } ?? []) + (reconciled.sources ?? [])
    }
    for previous in existing.sources ?? [] where previous.id != NationalEquipment.sourceID {
      guard previous.requiresPlaceSourceID == true,
        let index = result.sources?.firstIndex(where: { $0.id == previous.id }),
        let incoming = result.sources?[index],
        let previousDate = captureDate(previous.capturedAt), let incomingDate = captureDate(incoming.capturedAt),
        previousDate > incomingDate else { continue }
      // Legacy unassociated rows cannot safely be attributed to a source.
      let retained = existing.places.filter { $0.sourceID == previous.id }
      guard retained.count == previous.placeCount else { continue }
      result.places = result.places.filter { $0.sourceID != previous.id } + retained
      result.sources?[index] = previous
    }
    try CatalogValidation.validate(result)
    let previousPlaces = Dictionary(uniqueKeysWithValues: existing.places.map { ($0.id, $0) })
    let retained = result.places.compactMap { place -> CoordinateSupplementPack.Entry? in
      // The manifest owns the new inventory and source coordinates. Carry a
      // reviewed estimate only when its original place identity still agrees.
      guard place.coordinate == nil else { return nil }
      let candidates = [publishedPlaces[place.id], previousPlaces[place.id]].compactMap { $0 }.filter { candidate in
        candidate.name == place.name && candidate.address == place.address
          && candidate.provenance.sourceURL == place.provenance.sourceURL
          && candidate.provenance.referenceDate == place.provenance.referenceDate
          && (candidate.sourceID == nil || place.sourceID == nil || candidate.sourceID == place.sourceID)
          && candidate.coordinate != nil && candidate.coordinateEvidence != nil
      }.sorted {
        (captureDate($0.coordinateEvidence!.capturedAt) ?? .distantPast)
          > (captureDate($1.coordinateEvidence!.capturedAt) ?? .distantPast)
      }
      guard let previous = candidates.first, let coordinate = previous.coordinate,
        let evidence = previous.coordinateEvidence else { return nil }
      return CoordinateSupplementPack.Entry(placeID: place.id,
        latitude: coordinate.latitude, longitude: coordinate.longitude, quality: previous.coordinateQuality,
        sourceURL: evidence.sourceURL, method: evidence.method, capturedAt: evidence.capturedAt,
        matchedAddress: evidence.matchedAddress, sourceRecordID: evidence.sourceRecordID,
        matchedName: evidence.matchedName)
    }
    // Reuse the coordinate import's freshness/conflict checks and update source
    // counts after any missing coordinates have been filled.
    return try coordinates(.init(schemaVersion: 1, entries: retained), into: result).0
  }

  private static func reconcilePublishedNational(_ incoming: CatalogPack, previous: CatalogPack) throws -> CatalogPack {
    guard let newSource = incoming.sources?.first, let oldSource = previous.sources?.first else {
      throw CatalogError.invalid("전국 자료의 수집 정보가 없습니다")
    }
    let incomingComplete = newSource.completeCapturedAt
      ?? (newSource.partialCapturedAt == nil ? newSource.capturedAt : nil)
    let incomingDate = try incomingComplete.map(requiredCaptureDate)
    let previousDate = try oldSource.completeCapturedAt.map(requiredCaptureDate)
    // Equal full captures still accept new publication evidence and corrections.
    let useIncoming = previousDate == nil || (incomingDate.map { $0 >= previousDate! } ?? false)
    let base = useIncoming ? incoming : previous
    let other = useIncoming ? previous : incoming
    let complete = useIncoming ? incomingComplete : oldSource.completeCapturedAt
    let cutoff = try complete.map(requiredCaptureDate) ?? .distantPast
    var indexed = Dictionary(uniqueKeysWithValues: base.places.map { ($0.id, $0) })
    var partial = base.sources?.first?.partialCapturedAt
    for place in other.places {
      let date = try requiredCaptureDate(place.provenance.capturedAt)
      guard date > cutoff else { continue }
      if let current = indexed[place.id],
        try requiredCaptureDate(current.provenance.capturedAt) >= date { continue }
      indexed[place.id] = place
      partial = try newerCapture(partial, place.provenance.capturedAt)
    }
    var summary = try requiredCaptureDate(newSource.capturedAt) >= requiredCaptureDate(oldSource.capturedAt)
      ? newSource : oldSource
    summary.completeCapturedAt = complete
    summary.partialCapturedAt = partial.flatMap { value in
      captureDate(value).map { $0 > cutoff } == true ? value : nil
    }
    var result = CatalogPack(schemaVersion: 1, version: incoming.version, generatedAt: incoming.generatedAt,
      places: indexed.values.sorted { $0.id < $1.id }, sources: [summary])
    refreshSourceSummaries(&result)
    try CatalogValidation.validate(result)
    return result
  }

  static func regional(_ supplemental: CatalogPack, into existing: CatalogPack) throws -> (CatalogPack, Int) {
    try CatalogValidation.validate(supplemental)
    try CatalogValidation.validate(existing)
    guard supplemental.places.allSatisfy({ !$0.isNationalEquipment }) else {
      throw CatalogError.invalid("지역 보완 파일에 전국 자료가 섞여 있습니다")
    }
    var result = existing
    var indexed = Dictionary(uniqueKeysWithValues: existing.places.map { ($0.id, $0) })
    var conflicts = 0
    for place in supplemental.places {
      var incoming = place
      if let previous = indexed[place.id] {
        guard previous.name == place.name, previous.address == place.address,
          previous.provenance.sourceURL == place.provenance.sourceURL,
          previous.sourceID == nil || place.sourceID == nil || previous.sourceID == place.sourceID
          else { conflicts += 1; continue }
        // Old schema-1 caches lost this optional field. An otherwise identical
        // bundled place can restore its source association without replacing it.
        if previous.sourceID == nil { indexed[place.id]?.sourceID = place.sourceID }
        if let oldCoordinate = previous.coordinate, let newCoordinate = place.coordinate,
          oldCoordinate.latitude != newCoordinate.latitude || oldCoordinate.longitude != newCoordinate.longitude,
          !(previous.coordinateEvidence != nil && place.coordinateEvidence == nil) {
          conflicts += 1
          continue
        }
        guard let newer = captureDate(place.provenance.capturedAt),
          let older = captureDate(previous.provenance.capturedAt), newer > older else { continue }
        if place.coordinate == nil,
          previous.provenance.referenceDate == place.provenance.referenceDate,
          let coordinate = previous.coordinate, let evidence = previous.coordinateEvidence {
          let retained = CoordinateSupplementPack.Entry(placeID: place.id,
            latitude: coordinate.latitude, longitude: coordinate.longitude, quality: previous.coordinateQuality,
            sourceURL: evidence.sourceURL, method: evidence.method, capturedAt: evidence.capturedAt,
            matchedAddress: evidence.matchedAddress, sourceRecordID: evidence.sourceRecordID,
            matchedName: evidence.matchedName)
          // Reapply the same matching/staleness checks as a coordinate import.
          // An incoming source coordinate takes priority over an earlier estimate.
          if retained.matches(place) {
            incoming.latitude = retained.latitude
            incoming.longitude = retained.longitude
            incoming.coordinateQuality = retained.quality
            incoming.coordinateEvidence = evidence
          }
        }
      }
      incoming.sourceID = place.sourceID ?? indexed[place.id]?.sourceID
      indexed[place.id] = incoming
    }
    result.places = indexed.values.sorted { $0.id < $1.id }
    result.version = max(existing.version, supplemental.version)
    result.generatedAt = max(existing.generatedAt, supplemental.generatedAt)
    var sources = Dictionary(uniqueKeysWithValues: (existing.sources ?? []).map { ($0.id, $0) })
    for source in supplemental.sources ?? [] {
      if let previous = sources[source.id] {
        if let newer = captureDate(source.capturedAt),
          let older = captureDate(previous.capturedAt), newer > older { sources[source.id] = source }
        if previous.requiresPlaceSourceID == true || source.requiresPlaceSourceID == true {
          sources[source.id]?.requiresPlaceSourceID = true
        }
      } else { sources[source.id] = source }
    }
    result.sources = sources.isEmpty ? nil : sources.values.sorted { $0.id < $1.id }
    refreshSourceSummaries(&result, including: Set(supplemental.places.compactMap(\.catalogSourceID)))
    try CatalogValidation.validate(result)
    return (result, conflicts)
  }

  static func coordinates(_ supplemental: CoordinateSupplementPack, into existing: CatalogPack) throws -> (CatalogPack, Int) {
    try CatalogValidation.validate(existing)
    guard supplemental.schemaVersion == 1 else { throw CatalogError.unsupportedSchema }
    guard supplemental.entries.count <= CatalogValidation.maximumPlaces else { throw CatalogError.tooLarge }
    var result = existing
    let entries = Dictionary(grouping: supplemental.entries, by: \.placeID)
    var rejected = 0
    var encountered = Set<String>()
    for index in result.places.indices {
      let place = result.places[index]
      guard let candidates = entries[place.id] else { continue }
      encountered.insert(place.id)
      // Even equal duplicates are rejected: one identity has one reviewed decision.
      guard candidates.count == 1, let entry = candidates.first,
        entry.matches(place) else { rejected += candidates.count; continue }
      if let coordinate = place.coordinate {
        if coordinate.latitude != entry.latitude || coordinate.longitude != entry.longitude { rejected += 1 }
        continue
      }
      result.places[index].latitude = entry.latitude
      result.places[index].longitude = entry.longitude
      result.places[index].coordinateQuality = entry.quality
      result.places[index].coordinateEvidence = entry.evidence
    }
    rejected += entries.filter { !encountered.contains($0.key) }.values.reduce(0) { $0 + $1.count }
    refreshSourceSummaries(&result)
    try CatalogValidation.validate(result)
    return (result, rejected)
  }

  private static func refreshSourceSummaries(_ pack: inout CatalogPack, including additionalIDs: Set<String> = []) {
    let grouped = Dictionary(grouping: pack.places.filter { $0.catalogSourceID != nil }, by: { $0.catalogSourceID! })
    guard var sources = pack.sources else { return }
    let knownIDs = Set(grouped.keys).union(additionalIDs)
      .union(sources.filter { $0.requiresPlaceSourceID == true }.map(\.id))
    for index in sources.indices where knownIDs.contains(sources[index].id) {
      let places = grouped[sources[index].id] ?? []
      sources[index].placeCount = places.count
      sources[index].missingCoordinateCount = places.filter { $0.coordinate == nil }.count
      sources[index].regions = Set(places.map(\.regionName)).sorted()
    }
    pack.sources = sources
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

struct CoordinateSupplementPack: Codable, Sendable {
  var schemaVersion: Int
  var entries: [Entry]

  struct Entry: Codable, Sendable {
    var placeID: String
    var latitude: Double
    var longitude: Double
    var quality: CoordinateQuality
    var sourceURL: String
    var method: String
    var capturedAt: String
    var matchedAddress: String
    var sourceRecordID: String? = nil
    var matchedName: String? = nil

    var evidence: CoordinateEvidence {
      CoordinateEvidence(sourceURL: sourceURL, method: method, capturedAt: capturedAt,
        matchedAddress: matchedAddress, sourceRecordID: sourceRecordID, matchedName: matchedName)
    }

    func matches(_ place: EquipmentPlace) -> Bool {
      guard !matchedAddress.isEmpty, matchedAddress == place.address,
        matchedName.map({ $0 == place.name }) ?? true,
        latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
        quality != .unknown, !method.isEmpty, method.count <= 500,
        (try? CatalogValidation.httpsURL(sourceURL)) != nil,
        let captured = CatalogMerge.captureDate(capturedAt),
        place.coordinateConflict != true,
        // Older schema-1 packs expressed this conflict only in the source note.
        place.provenance.note?.contains("원본 좌표가 서로 달라") != true else { return false }
      if let date = place.provenance.referenceDate.flatMap(CatalogMerge.captureDate), captured < date { return false }
      if let previous = (place.coordinateEvidence?.capturedAt).flatMap(CatalogMerge.captureDate), captured < previous { return false }
      return true
    }
  }
}
