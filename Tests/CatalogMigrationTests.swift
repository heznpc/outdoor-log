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
    XCTAssertEqual(result.sources?.first?.regions, ["경기도"])
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

  private func row(_ name: String, equipment: String) -> [String: String] {
    ["INSTL_PLC_NM": name, "CTPV_NM": "경기도", "SGG_NM": "시험시",
      "LCTN_ROAD_NM_ADDR": "시험로 1", "LCTN_LOTNO_ADDR": "", "LAT": "37", "LOT": "127",
      "SPRTGD_NM": equipment, "SPRTGD_QTY": "1", "MNG_INST_NM": "시험기관",
      "INSTT_NM": "시험기관", "INSTT_CODE": "0000000", "DATA_CRTR_YMD": "2026-10-01"]
  }

  private func national(_ rows: [[String: String]], capturedAt: String = "2026-10-22") throws -> CatalogPack {
    try NationalEquipment.normalize(JSONSerialization.data(withJSONObject: rows), capturedAt: capturedAt)
  }
}
