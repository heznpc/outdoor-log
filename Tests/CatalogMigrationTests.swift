import XCTest
@testable import OutdoorLog

final class CatalogMigrationTests: XCTestCase {
  func testPartialFileUpsertsWithoutDeletingAbsentPlaces() throws {
    let old = try CatalogMerge.national(national([row("가공원", equipment: "철봉"), row("나공원", equipment: "평행봉")]),
      into: nil, replace: true)
    let partial = try national([row("가공원", equipment: "하늘걷기")], capturedAt: "2026-10-24T00:00:00Z")
    let merged = try CatalogMerge.national(partial, into: old, replace: false)
    XCTAssertEqual(merged.places.count, 2)
    XCTAssertEqual(merged.places.first { $0.name == "가공원" }?.equipment.first?.name, "하늘걷기")
    XCTAssertEqual(merged.places.first { $0.name == "나공원" }?.id, old.places.first { $0.name == "나공원" }?.id)
    XCTAssertEqual(merged.sources?.first?.rowCount, 1)
    XCTAssertEqual(merged.sources?.first?.placeCount, 2)
    XCTAssertEqual(merged.sources?.first?.capturedAt, "2026-10-24T00:00:00Z")
    XCTAssertEqual(merged.sources?.first?.completeCapturedAt, "2026-10-22")
    XCTAssertEqual(merged.sources?.first?.partialCapturedAt, "2026-10-24T00:00:00Z")
  }

  func testCompleteDownloadReplacesOnlyItsSource() throws {
    var old = try national([row("가공원", equipment: "철봉"), row("나공원", equipment: "평행봉")])
    old.sources?[0].partialCapturedAt = "2026-10-22"
    var local = old.places[0]
    local.id = "existing-local-id"
    local.provenance.sourceURL = "https://example.org/local"
    old.places.append(local)
    let incoming = try national([row("가공원", equipment: "철봉")])
    let merged = try CatalogMerge.national(incoming, into: old, replace: true)
    XCTAssertEqual(merged.places.count, 2)
    XCTAssertTrue(merged.places.contains { $0.id == local.id })
    XCTAssertFalse(merged.places.contains { $0.name == "나공원" })
    XCTAssertEqual(merged.sources?.first?.completeCapturedAt, incoming.sources?.first?.capturedAt)
    XCTAssertNil(merged.sources?.first?.partialCapturedAt)
  }

  @MainActor func testLegacyCacheAdoptsBundledNationalWithoutRewritingOriginal() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var legacy = try national([row("기존장소", equipment: "철봉")])
    legacy.places[0].id = "gimhae-existing-id"
    legacy.places[0].provenance.sourceURL = "https://example.org/legacy"
    legacy.sources = nil
    let currentURL = directory.appendingPathComponent("current.json")
    let original = try JSONEncoder().encode(legacy)
    try original.write(to: currentURL)
    let bundleURL = directory.appendingPathComponent("bundle.json")
    let bundled = try national([row("신규장소", equipment: "평행봉")])
    try JSONEncoder().encode(bundled).write(to: bundleURL)
    let suite = "CatalogMigration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set([legacy.places[0].id, "unavailable-place"], forKey: "catalog.favoriteIDs")
    let store = CatalogStore(defaults: defaults, directory: directory, bundledURL: bundleURL)
    XCTAssertEqual(Set(store.places.map(\.id)), Set([legacy.places[0].id, bundled.places[0].id]))
    XCTAssertTrue(store.isFavorite(legacy.places[0].id))
    XCTAssertEqual(store.unavailableFavoriteIDs, ["unavailable-place"])
    XCTAssertEqual(try Data(contentsOf: currentURL), original)
  }

  func testNewerDownloadedSourceWinsOverOlderBundle() throws {
    let cached = try CatalogMerge.national(
      national([row("최근장소", equipment: "철봉")], capturedAt: "2026-10-23T00:00:00Z"), into: nil, replace: true)
    let bundle = try national([row("과거장소", equipment: "평행봉")], capturedAt: "2026-10-22")
    let result = try CatalogMerge.adoptingBundledNational(bundle, into: cached)
    XCTAssertEqual(result.places.map(\.id), cached.places.map(\.id))
  }

  func testNewerPartialImportDoesNotHideNewBundleAndKeepsNewerRows() throws {
    let old = try CatalogMerge.national(
      national([row("가공원", equipment: "철봉"), row("삭제된장소", equipment: "평행봉")], capturedAt: "2026-10-20"),
      into: nil, replace: true)
    let partial = try national([row("가공원", equipment: "하늘걷기"), row("부분파일신규", equipment: "철봉")],
      capturedAt: "2026-10-24T00:00:00Z")
    let cached = try CatalogMerge.national(partial, into: old, replace: false)
    let bundle = try national([row("가공원", equipment: "평행봉"), row("번들신규", equipment: "철봉")],
      capturedAt: "2026-10-23")

    let result = try CatalogMerge.adoptingBundledNational(bundle, into: cached)

    XCTAssertEqual(Set(result.places.map(\.name)), Set(["가공원", "부분파일신규", "번들신규"]))
    let retained = try XCTUnwrap(result.places.first { $0.name == "가공원" })
    XCTAssertEqual(retained.id, partial.places.first { $0.name == "가공원" }?.id)
    XCTAssertEqual(retained.equipment.first?.name, "하늘걷기")
    XCTAssertEqual(retained.provenance.capturedAt, "2026-10-24T00:00:00Z")
    XCTAssertEqual(result.sources?.first?.completeCapturedAt, "2026-10-23")
    XCTAssertEqual(result.sources?.first?.partialCapturedAt, "2026-10-24T00:00:00Z")
    XCTAssertEqual(result.sources?.first?.capturedAt, "2026-10-24T00:00:00Z")
    XCTAssertEqual(result.sources?.first?.rowCount, 2)
    XCTAssertEqual(result.sources?.first?.placeCount, 3)
  }

  func testBundleComparisonUsesInstantsForDateOnlyAndTimeZoneValues() throws {
    let old = try CatalogMerge.national(
      national([row("가공원", equipment: "철봉")], capturedAt: "2026-10-23T00:30:00+09:00"),
      into: nil, replace: true)
    let partial = try national([row("가공원", equipment: "하늘걷기")], capturedAt: "2026-10-22T23:30:00-02:00")
    let cached = try CatalogMerge.national(partial, into: old, replace: false)
    let bundle = try national([row("가공원", equipment: "평행봉"), row("번들신규", equipment: "철봉")],
      capturedAt: "2026-10-23")

    let result = try CatalogMerge.adoptingBundledNational(bundle, into: cached)

    XCTAssertEqual(result.places.count, 2)
    XCTAssertEqual(result.places.first { $0.name == "가공원" }?.equipment.first?.name, "하늘걷기")
    XCTAssertEqual(result.sources?.first?.completeCapturedAt, "2026-10-23")
  }

  func testSchemaOneWithoutCaptureMarkersKeepsNewerRowsWhenAdoptingBundle() throws {
    let legacy = try national([row("기존장소", equipment: "철봉")], capturedAt: "2026-10-24")
    let decoded = try CatalogValidation.decode(JSONEncoder().encode(legacy))
    XCTAssertNil(decoded.sources?.first?.completeCapturedAt)
    XCTAssertNil(decoded.sources?.first?.partialCapturedAt)
    let bundle = try national([row("번들신규", equipment: "평행봉")], capturedAt: "2026-10-23")

    let result = try CatalogMerge.adoptingBundledNational(bundle, into: decoded)

    XCTAssertEqual(Set(result.places.map(\.id)), Set(legacy.places.map(\.id) + bundle.places.map(\.id)))
    XCTAssertEqual(result.sources?.first?.completeCapturedAt, "2026-10-23")
    XCTAssertEqual(result.sources?.first?.capturedAt, "2026-10-24")
    XCTAssertNil(result.sources?.first?.partialCapturedAt)
  }

  @MainActor func testValidCacheSurvivesFailedBundleMigrationWithoutUsingBackup() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var cached = try national([row("기존장소", equipment: "철봉")])
    cached.places[0].id = "gimhae-existing-id"
    cached.places[0].provenance.sourceURL = "https://example.org/legacy"
    // Each pack is valid; their union exceeds the allowed source count.
    cached.sources = (0..<100).map { index in
      CatalogSourceSummary(id: "legacy-\(index)", capturedAt: "2026-10-22", rowCount: 0,
        placeCount: 0, missingCoordinateCount: 0, regions: [])
    }
    try CatalogValidation.validate(cached)
    let currentURL = directory.appendingPathComponent("current.json")
    let original = try JSONEncoder().encode(cached)
    try original.write(to: currentURL)
    var backup = cached
    backup.places[0].id = "backup-only-id"
    backup.sources = nil
    try JSONEncoder().encode(backup).write(to: directory.appendingPathComponent("last-good.json"))
    let bundled = try national([row("번들신규", equipment: "평행봉")], capturedAt: "2026-10-23")
    let bundleURL = directory.appendingPathComponent("bundle.json")
    try JSONEncoder().encode(bundled).write(to: bundleURL)
    let suite = "CatalogMigration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = CatalogStore(defaults: defaults, directory: directory, bundledURL: bundleURL)

    XCTAssertEqual(store.places.map(\.id), cached.places.map(\.id))
    XCTAssertTrue(store.errorMessage?.contains("합치지 못해 저장된 목록을 유지") == true)
    XCTAssertEqual(try Data(contentsOf: currentURL), original)
  }

  func testManifestCombinesPartitionsOfOneSource() throws {
    let first = try CatalogMerge.national(national([row("가공원", equipment: "철봉")]), into: nil, replace: true)
    let second = try CatalogMerge.national(
      national([row("나공원", equipment: "평행봉")], capturedAt: "2026-10-22T00:00:00Z"), into: nil, replace: true)

    let result = try CatalogMerge.manifest([first, second], version: first.version, generatedAt: "2026-10-22")

    XCTAssertEqual(result.places.count, 2)
    XCTAssertEqual(result.sources?.count, 1)
    XCTAssertEqual(result.sources?.first?.rowCount, 2)
    XCTAssertEqual(result.sources?.first?.placeCount, 2)
    XCTAssertEqual(result.sources?.first?.missingCoordinateCount, 0)
    XCTAssertEqual(result.sources?.first?.regions, ["경기도 시험시"])
    let summary = try XCTUnwrap(result.sources?.first)
    XCTAssertEqual(summary.completeCapturedAt.flatMap { CatalogMerge.captureDate($0) }, CatalogMerge.captureDate("2026-10-22"))
  }

  func testManifestRejectsDuplicatePlacesAndConflictingSourceCaptureMetadata() throws {
    let first = try national([row("가공원", equipment: "철봉")])
    let second = try national([row("나공원", equipment: "평행봉")])
    XCTAssertThrowsError(try CatalogMerge.manifest([first, first], version: first.version, generatedAt: "2026-10-22"))
    var otherCapture = second
    otherCapture.sources?[0].capturedAt = "2026-10-23"
    XCTAssertThrowsError(try CatalogMerge.manifest([first, otherCapture], version: first.version, generatedAt: "2026-10-22"))
    var knownComplete = second
    knownComplete.sources?[0].completeCapturedAt = "2026-10-22"
    XCTAssertThrowsError(try CatalogMerge.manifest([first, knownComplete], version: first.version, generatedAt: "2026-10-22"))
    var oldComplete = first
    oldComplete.sources?[0].completeCapturedAt = "2026-10-21"
    XCTAssertThrowsError(try CatalogMerge.manifest([oldComplete, knownComplete], version: first.version, generatedAt: "2026-10-22"))
    var firstPartial = first
    firstPartial.sources?[0].partialCapturedAt = "2026-10-21"
    var secondPartial = second
    secondPartial.sources?[0].partialCapturedAt = "2026-10-22"
    XCTAssertThrowsError(try CatalogMerge.manifest([firstPartial, secondPartial], version: first.version, generatedAt: "2026-10-22"))
  }

  func testRejectsBrokenSourceCountsAndDownloadCeiling() throws {
    var pack = try national([row("가공원", equipment: "철봉")])
    pack.sources?[0].placeCount = 2
    XCTAssertThrowsError(try CatalogValidation.validate(pack))
    let table = NationalCatalogDownload.Header.Table(colNmList: [], svcTableNm: "wrong")
    XCTAssertThrowsError(try NationalCatalogDownload.Header(totalCount: 0, tableVO: table).validate())
    XCTAssertThrowsError(try NationalCatalogDownload.Header(totalCount: 50_001, tableVO: table).validate())
    XCTAssertThrowsError(try NationalCatalogDownload.Header(totalCount: 1, tableVO: table).validate())
  }

  func testRequestPreservesRepeatedColumnQueryItems() throws {
    let columns = ["INSTL_PLC_NM", "CTPV_NM", "SGG_NM", "LCTN_ROAD_NM_ADDR", "LCTN_LOTNO_ADDR",
      "LAT", "LOT", "SPRTGD_NM", "SPRTGD_QTY", "DATA_CRTR_YMD"]
    let header = NationalCatalogDownload.Header(totalCount: 11_674,
      tableVO: .init(colNmList: columns, svcTableNm: "tn_pubr_public_outdoor_exercise_eqmt_svc"))
    let parts = try XCTUnwrap(URLComponents(url: NationalCatalogDownload.pageURL(2, header: header), resolvingAgainstBaseURL: false))
    XCTAssertEqual(parts.host, "www.data.go.kr")
    XCTAssertEqual(parts.queryItems?.filter { $0.name == "colNmList" }.compactMap(\.value), columns)
    XCTAssertEqual(parts.queryItems?.first { $0.name == "page" }?.value, "2")
  }

  func testNationalRefreshPreservesRegionalIDsAndMatchingCoordinateEvidence() throws {
    var sourceRow = row("가공원", equipment: "철봉")
    sourceRow["LAT"] = ""; sourceRow["LOT"] = ""
    let nationalPack = try national([sourceRow])
    var regional = try XCTUnwrap(nationalPack.places.first)
    regional.id = "legacy-regional-park-1"
    regional.provenance.sourceURL = "https://example.org/regional"
    regional.name = "지역 보완 장소"
    let regionalPack = CatalogPack(schemaVersion: 1, version: 1, generatedAt: "2026-10-22", places: [regional])
    let (combined, conflicts) = try CatalogMerge.regional(regionalPack, into: nationalPack)
    XCTAssertEqual(conflicts, 0)
    let original = nationalPack.places[0]
    let entry = CoordinateSupplementPack.Entry(placeID: original.id, latitude: 37, longitude: 127,
      quality: .park, sourceURL: "https://example.org/park", method: "official-park-exact-match",
      capturedAt: "2026-10-26", matchedAddress: original.address)
    let (enriched, _) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [entry]), into: combined)
    XCTAssertEqual(enriched.sources?.first?.missingCoordinateCount, 0)
    let refreshed = try CatalogMerge.national(national([sourceRow], capturedAt: "2026-10-27"), into: enriched, replace: true)
    XCTAssertTrue(refreshed.places.contains { $0.id == regional.id })
    XCTAssertEqual(refreshed.places.first { $0.id == original.id }?.coordinateEvidence?.sourceURL, entry.sourceURL)
    sourceRow["DATA_CRTR_YMD"] = "2026-10-28"
    let changed = try CatalogMerge.national(national([sourceRow], capturedAt: "2026-10-29"), into: enriched, replace: true)
    XCTAssertNil(changed.places.first { $0.id == original.id }?.coordinate)
  }

  @MainActor func testCorruptOptionalSupplementsNeverHideBaseCatalog() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = directory.appendingPathComponent("catalog.json")
    let base = try national([row("기본 장소", equipment: "철봉")])
    try JSONEncoder().encode(base).write(to: bundle)
    try Data("invalid JSON".utf8).write(to: directory.appendingPathComponent("regional-equipment.json"))
    try Data("invalid JSON".utf8).write(to: directory.appendingPathComponent("coordinate-supplements.json"))
    let suite = "CatalogOptionalTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = CatalogStore(defaults: defaults, directory: directory, bundledURL: bundle)
    XCTAssertEqual(store.places.map(\.id), base.places.map(\.id))
    XCTAssertNil(store.errorMessage)
    XCTAssertTrue(store.supplementWarning?.contains("지역 보완") == true)
    XCTAssertTrue(store.supplementWarning?.contains("좌표 보완") == true)
  }

  func testRegionalMergeRefreshesMetadataAndSummariesForRetainedPlaces() throws {
    let old = try regionalPack(["기존 장소", "보존 장소"], capturedAt: "2026-10-22")
    var incoming = try regionalPack(["기존 장소"], capturedAt: "2026-10-26")
    incoming.version = 4
    incoming.places[0].regionName = "새 지역"
    incoming.sources?[0].regions = ["새 지역"]
    incoming.sources?[0].rowCount = 20
    let (merged, conflicts) = try CatalogMerge.regional(incoming, into: old)
    XCTAssertEqual(conflicts, 0)
    XCTAssertEqual(merged.version, 4)
    XCTAssertEqual(merged.generatedAt, "2026-10-26")
    XCTAssertEqual(merged.sources?.first?.capturedAt, "2026-10-26")
    XCTAssertEqual(merged.sources?.first?.rowCount, 20)
    XCTAssertEqual(merged.sources?.first?.placeCount, 2)
    XCTAssertEqual(merged.sources?.first?.missingCoordinateCount, 2)
    XCTAssertEqual(Set(merged.sources?.first?.regions ?? []), Set(["새 지역", old.places[1].regionName]))
    let target = try XCTUnwrap(merged.places.first { $0.name == "기존 장소" })
    let entry = CoordinateSupplementPack.Entry(placeID: target.id, latitude: 37, longitude: 127,
      quality: .address, sourceURL: "https://example.org/geocoder", method: "address-geocoding",
      capturedAt: "2026-10-26", matchedAddress: target.address)
    let (enriched, rejected) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [entry]), into: merged)
    XCTAssertEqual(rejected, 0)
    XCTAssertEqual(enriched.sources?.first?.missingCoordinateCount, 1)
    XCTAssertEqual(enriched.sources?.first?.rowCount, 20)

    var legacy = old
    for index in legacy.places.indices { legacy.places[index].sourceID = nil }
    let (migrated, _) = try CatalogMerge.regional(old, into: legacy)
    XCTAssertEqual(migrated.places.compactMap(\.sourceID), Array(repeating: "regional-source", count: 2))
  }

  func testRegionalRefreshRetainsMatchingCoordinateEvidenceAndPrioritizesNewSourceCoordinates() throws {
    let original = try regionalPack(["보완 장소"], capturedAt: "2026-10-22")
    let place = original.places[0]
    let entry = CoordinateSupplementPack.Entry(placeID: place.id, latitude: 37, longitude: 127,
      quality: .park, sourceURL: "https://example.org/park", method: "official-park-exact-match",
      capturedAt: "2026-10-26", matchedAddress: place.address, sourceRecordID: "park-1", matchedName: place.name)
    let (enriched, _) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [entry]), into: original)
    var incoming = try regionalPack(["보완 장소"], capturedAt: "2026-10-27")
    let (retained, conflicts) = try CatalogMerge.regional(incoming, into: enriched)
    XCTAssertEqual(conflicts, 0)
    XCTAssertEqual(retained.places[0].latitude, 37)
    XCTAssertEqual(retained.places[0].coordinateQuality, .park)
    XCTAssertEqual(retained.places[0].coordinateEvidence, enriched.places[0].coordinateEvidence)
    XCTAssertEqual(retained.sources?.first?.missingCoordinateCount, 0)
    var changedReference = incoming
    changedReference.places[0].provenance.referenceDate = "2026-10-28"
    let (stale, _) = try CatalogMerge.regional(changedReference, into: enriched)
    XCTAssertNil(stale.places[0].coordinate)
    XCTAssertNil(stale.places[0].coordinateEvidence)
    var conflictingSource = incoming
    conflictingSource.places[0].coordinateConflict = true
    let (unfilled, _) = try CatalogMerge.regional(conflictingSource, into: enriched)
    XCTAssertNil(unfilled.places[0].coordinate)
    XCTAssertNil(unfilled.places[0].coordinateEvidence)

    incoming.places[0].latitude = 37.1
    incoming.places[0].longitude = 127.1
    incoming.places[0].coordinateQuality = .facility
    incoming.sources?[0].missingCoordinateCount = 0
    let (sourceCoordinates, sourceConflicts) = try CatalogMerge.regional(incoming, into: enriched)
    XCTAssertEqual(sourceConflicts, 0)
    XCTAssertEqual(sourceCoordinates.places[0].latitude, 37.1)
    XCTAssertNil(sourceCoordinates.places[0].coordinateEvidence)
    incoming.places[0].latitude = 37.2
    incoming.places[0].provenance.capturedAt = "2026-10-28"
    let (keptSource, actualConflicts) = try CatalogMerge.regional(incoming, into: sourceCoordinates)
    XCTAssertEqual(actualConflicts, 1)
    XCTAssertEqual(keptSource.places[0].latitude, 37.1)
  }

  func testManifestRefreshRetainsEvidenceAndPrioritizesNewInventoryAndSourceCoordinates() throws {
    let original = try regionalPack(["보완 장소", "원좌표 우선", "제외 장소"], capturedAt: "2026-10-22")
    let entries = original.places.map { place in
      CoordinateSupplementPack.Entry(placeID: place.id, latitude: 37, longitude: 127,
        quality: .park, sourceURL: "https://example.org/park", method: "official-park-exact-match",
        capturedAt: "2026-10-26", matchedAddress: place.address, sourceRecordID: "park-" + place.id,
        matchedName: place.name)
    }
    let (enriched, _) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: entries), into: original)
    var incoming = try regionalPack(["보완 장소", "원좌표 우선", "새 장소"], capturedAt: "2026-10-27")
    incoming.version = 2
    let sourceIndex = try XCTUnwrap(incoming.places.firstIndex { $0.name == "원좌표 우선" })
    incoming.places[sourceIndex].latitude = 37.1
    incoming.places[sourceIndex].longitude = 127.1
    incoming.places[sourceIndex].coordinateQuality = .facility
    incoming.sources?[0].missingCoordinateCount = 2

    let refreshed = try CatalogMerge.manifest([incoming], version: 2, generatedAt: "2026-10-27",
      preservingCoordinatesFrom: enriched)

    XCTAssertEqual(Set(refreshed.places.map(\.id)), Set(incoming.places.map(\.id)))
    XCTAssertEqual(refreshed.version, 2)
    let retained = try XCTUnwrap(refreshed.places.first { $0.name == "보완 장소" })
    XCTAssertEqual(retained.latitude, 37)
    XCTAssertEqual(retained.longitude, 127)
    XCTAssertEqual(retained.coordinateQuality, .park)
    XCTAssertEqual(retained.coordinateEvidence, enriched.places.first { $0.id == retained.id }?.coordinateEvidence)
    XCTAssertEqual(retained.provenance.capturedAt, "2026-10-27")
    let source = try XCTUnwrap(refreshed.places.first { $0.name == "원좌표 우선" })
    XCTAssertEqual(source.latitude, 37.1)
    XCTAssertEqual(source.longitude, 127.1)
    XCTAssertEqual(source.coordinateQuality, .facility)
    XCTAssertNil(source.coordinateEvidence)
    XCTAssertNil(refreshed.places.first { $0.name == "새 장소" }?.coordinate)
    XCTAssertEqual(refreshed.sources?.first?.placeCount, 3)
    XCTAssertEqual(refreshed.sources?.first?.missingCoordinateCount, 1)
    XCTAssertEqual(refreshed.sources?.first?.capturedAt, "2026-10-27")
  }

  func testManifestRefreshRejectsChangedIdentityStaleEvidenceAndSourceConflicts() throws {
    let names = ["주소 변경", "기준일 변경", "오래된 근거", "이름 변경", "출처 변경", "좌표 충돌"]
    let original = try regionalPack(names, capturedAt: "2026-10-22")
    let entries = original.places.map { place in
      CoordinateSupplementPack.Entry(placeID: place.id, latitude: 37, longitude: 127,
        quality: .park, sourceURL: "https://example.org/park", method: "official-park-exact-match",
        capturedAt: "2026-10-26", matchedAddress: place.address, matchedName: place.name)
    }
    var (enriched, _) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: entries), into: original)
    // A schema-1 cache may already contain evidence older than its source date.
    let staleIndex = try XCTUnwrap(enriched.places.firstIndex { $0.name == "오래된 근거" })
    enriched.places[staleIndex].coordinateEvidence?.capturedAt = "2026-09-30"
    var incoming = try regionalPack(names, capturedAt: "2026-10-27")
    for index in incoming.places.indices {
      switch incoming.places[index].name {
      case "주소 변경": incoming.places[index].address = "시험로 2"
      case "기준일 변경": incoming.places[index].provenance.referenceDate = "2026-10-02"
      case "이름 변경": incoming.places[index].name = "바뀐 이름"
      case "출처 변경": incoming.places[index].provenance.sourceURL = "https://example.org/another-source"
      case "좌표 충돌": incoming.places[index].coordinateConflict = true
      default: break
      }
    }

    let refreshed = try CatalogMerge.manifest([incoming], version: incoming.version, generatedAt: "2026-10-27",
      preservingCoordinatesFrom: enriched)

    XCTAssertTrue(refreshed.places.allSatisfy { $0.coordinate == nil && $0.coordinateEvidence == nil })
    XCTAssertEqual(refreshed.sources?.first?.missingCoordinateCount, names.count)
  }

  @MainActor func testSupplementImportsPreserveCatalogAndReachSearchAndRecordChoices() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var base = try national([row("전국 장소", equipment: "철봉")])
    base.version = 5
    try JSONEncoder().encode(base).write(to: directory.appendingPathComponent("current.json"))
    let suite = "CatalogSupplementImport.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = CatalogStore(defaults: defaults, directory: directory, bundledURL: nil)
    let revision = store.revision
    store.toggleFavorite(base.places[0].id)
    let regional = try regionalPack(["지역 장소"], capturedAt: "2026-10-26")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(regional)) as? [String: Any])
    object["catalogRole"] = "regional-supplement"
    let importURL = directory.appendingPathComponent("regional.json")
    let regionalData = try JSONSerialization.data(withJSONObject: object)
    try regionalData.write(to: importURL)
    await store.importJSON(from: importURL)
    XCTAssertNil(store.errorMessage)
    XCTAssertEqual(store.version, 5)
    XCTAssertGreaterThan(store.revision, revision)
    let expectedIDs = Set(base.places.map(\.id) + regional.places.map(\.id))
    XCTAssertEqual(Set(store.places.map(\.id)), expectedIDs)
    XCTAssertEqual(Set(store.recordPlaceChoices.map(\.id)), expectedIDs)
    XCTAssertTrue(store.isFavorite(base.places[0].id))
    let target = regional.places[0]
    let entry = CoordinateSupplementPack.Entry(placeID: target.id, latitude: 37, longitude: 127,
      quality: .park, sourceURL: "https://example.org/park", method: "official-park-exact-match",
      capturedAt: "2026-10-26", matchedAddress: target.address)
    let coordinateData = try JSONEncoder().encode(CoordinateSupplementPack(schemaVersion: 1, entries: [entry]))
    try coordinateData.write(to: importURL)
    await store.importJSON(from: importURL)
    XCTAssertNil(store.errorMessage)
    XCTAssertEqual(Set(store.places.map(\.id)), expectedIDs)
    XCTAssertEqual(store.places.first { $0.id == target.id }?.coordinateQuality, .park)
    let saved = try CatalogValidation.decode(Data(contentsOf: directory.appendingPathComponent("current.json")))
    XCTAssertEqual(saved.sources?.first { $0.id == "regional-source" }?.missingCoordinateCount, 0)
    XCTAssertEqual(saved.places.first { $0.id == target.id }?.sourceID, "regional-source")
    let query = CatalogSearchQuery(revision: store.revision, text: "지역 장소", region: target.regionCode,
      equipmentKind: "철봉", favoritesOnly: false, favorites: [], latitude: nil, longitude: nil)
    XCTAssertEqual(CatalogSearch.results(in: store.places, query: query).map(\.id), [target.id])
    XCTAssertThrowsError(try CatalogStore.prepareImport(regionalData, existing: nil, minimumVersion: 0))
    XCTAssertThrowsError(try CatalogStore.prepareImport(coordinateData, existing: nil, minimumVersion: 0))
    object["entries"] = []
    let malformed = try JSONSerialization.data(withJSONObject: object)
    try malformed.write(to: importURL)
    await store.importJSON(from: importURL)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(Set(store.places.map(\.id)), expectedIDs)
    XCTAssertEqual(store.version, 5)
  }

  private func regionalPack(_ names: [String], capturedAt: String) throws -> CatalogPack {
    var result = try national(names.map { row($0, equipment: "철봉") }, capturedAt: capturedAt)
    for index in result.places.indices {
      result.places[index].id = "regional-" + result.places[index].name
      result.places[index].sourceID = "regional-source"
      result.places[index].provenance.sourceURL = "https://example.org/regional"
      result.places[index].latitude = nil
      result.places[index].longitude = nil
      result.places[index].coordinateQuality = .unknown
    }
    result.sources = [.init(id: "regional-source", capturedAt: capturedAt, rowCount: names.count,
      placeCount: names.count, missingCoordinateCount: names.count, regions: [result.places[0].regionName])]
    return result
  }

  private func row(_ name: String, equipment: String) -> [String: String] {
    ["INSTL_PLC_NM": name, "CTPV_NM": "경기도", "SGG_NM": "시험시",
      "LCTN_ROAD_NM_ADDR": "시험로 1", "LCTN_LOTNO_ADDR": "", "LAT": "37", "LOT": "127",
      "SPRTGD_NM": equipment, "SPRTGD_QTY": "1", "MNG_INST_NM": "시험기관",
      "INSTT_NM": "시험기관", "INSTT_CODE": "0000000", "DATA_CRTR_YMD": "2026-10-01"]
  }

  func testPublishedReleaseDoesNotUndoNewerDirectNationalRefresh() throws {
    let existing = try CatalogMerge.national(national([
      row("가공원", equipment: "새 철봉"), row("신규장소", equipment: "평행봉")
    ], capturedAt: "2026-10-26"), into: nil, replace: true)
    var published = try CatalogMerge.national(national([
      row("가공원", equipment: "이전 기구"), row("철거장소", equipment: "평행봉")
    ], capturedAt: "2026-10-22"), into: nil, replace: true)
    published.version = 20261027000000
    let merged = try CatalogMerge.manifest([published], version: published.version,
      generatedAt: "2026-10-27", preservingCoordinatesFrom: existing)
    XCTAssertEqual(Set(merged.places.map(\.name)), Set(["가공원", "신규장소"]))
    XCTAssertEqual(merged.places.first { $0.name == "가공원" }?.equipment.first?.name, "새 철봉")
    XCTAssertEqual(merged.sources?.first?.completeCapturedAt, "2026-10-26")
  }

  private func national(_ rows: [[String: String]], capturedAt: String = "2026-10-22") throws -> CatalogPack {
    try NationalEquipment.normalize(JSONSerialization.data(withJSONObject: rows), capturedAt: capturedAt)
  }

  func testSameNationalCaptureAcceptsNewlyPublishedCoordinateEvidence() throws {
    var sourceRow = row("가공원", equipment: "철봉")
    sourceRow["LAT"] = ""; sourceRow["LOT"] = ""
    let existing = try CatalogMerge.national(national([sourceRow]), into: nil, replace: true)
    let place = try XCTUnwrap(existing.places.first)
    let entry = CoordinateSupplementPack.Entry(placeID: place.id, latitude: 37, longitude: 127,
      quality: .park, sourceURL: "https://example.org/park", method: "official-park-exact-match",
      capturedAt: "2026-10-26", matchedAddress: place.address)
    var (published, _) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [entry]), into: existing)
    published.version = 100
    let merged = try CatalogMerge.manifest([published], version: 100, generatedAt: "2026-10-27",
      preservingCoordinatesFrom: existing)
    XCTAssertEqual(merged.places.first?.coordinateEvidence, published.places.first?.coordinateEvidence)
    XCTAssertNotNil(merged.places.first?.coordinate)
  }

  func testOlderPublishedCompleteCaptureStillContributesNewerPartialRows() throws {
    let existing = try CatalogMerge.national(national([
      row("가공원", equipment: "직접 갱신"), row("유지장소", equipment: "철봉")
    ], capturedAt: "2026-10-26"), into: nil, replace: true)
    let old = try CatalogMerge.national(national([
      row("가공원", equipment: "이전 기구"), row("철거장소", equipment: "철봉")
    ], capturedAt: "2026-10-22"), into: nil, replace: true)
    var published = try CatalogMerge.national(national([
      row("가공원", equipment: "새 부분 갱신"), row("추가장소", equipment: "평행봉")
    ], capturedAt: "2026-10-27"), into: old, replace: false)
    published.version = 100
    let merged = try CatalogMerge.manifest([published], version: 100, generatedAt: "2026-10-27",
      preservingCoordinatesFrom: existing)
    XCTAssertEqual(Set(merged.places.map(\.name)), Set(["가공원", "유지장소", "추가장소"]))
    XCTAssertEqual(merged.places.first { $0.name == "가공원" }?.equipment.first?.name, "새 부분 갱신")
    XCTAssertEqual(merged.sources?.first?.completeCapturedAt, "2026-10-26")
    XCTAssertEqual(merged.sources?.first?.partialCapturedAt, "2026-10-27")
  }
}
