import XCTest
@testable import OutdoorLog

final class CatalogTests: XCTestCase {
  func testSearchCombinesEquipmentAddressAndRegionTerms() {
    let place = fixture()
    XCTAssertTrue(place.matches("철봉 김해"))
    XCTAssertFalse(place.matches("철봉 제주"))
    XCTAssertTrue(place.matches("  "))
  }

  func testEquipmentFilterIncludesCompoundComponentsWithoutChangingInventory() {
    var compound = fixture()
    compound.id = "compound"
    compound.equipment = [EquipmentItem(name: "역기당기기+평행봉", count: 2)]
    let originalEquipment = compound.equipment
    var query = CatalogSearchQuery(revision: 0, text: "", region: "", equipmentKind: "평행봉",
      favoritesOnly: false, favorites: [], latitude: nil, longitude: nil)
    XCTAssertEqual(CatalogSearch.results(in: [fixture(), compound], query: query).map(\.id), [compound.id])
    query.equipmentKind = "역기당기기"
    XCTAssertEqual(CatalogSearch.results(in: [compound], query: query).map(\.id), [compound.id])
    query.equipmentKind = "역기당기기+평행봉"
    XCTAssertEqual(CatalogSearch.results(in: [compound], query: query).map(\.id), [compound.id])
    query.equipmentKind = "평행"
    XCTAssertTrue(CatalogSearch.results(in: [compound], query: query).isEmpty)
    XCTAssertEqual(compound.equipment, originalEquipment)
  }

  func testCountedCompoundFilterKeepsUncertainSourceInventory() {
    var compound = fixture()
    compound.equipment = [EquipmentItem(name: "달리기(1) + 가로타기(1)", count: nil)]
    let query = CatalogSearchQuery(revision: 0, text: "", region: "", equipmentKind: "가로타기",
      favoritesOnly: false, favorites: [], latitude: nil, longitude: nil)
    XCTAssertEqual(CatalogSearch.results(in: [compound], query: query).map(\.id), [compound.id])
    XCTAssertEqual(compound.equipment, [EquipmentItem(name: "달리기(1) + 가로타기(1)", count: nil)])
  }

  func testParkFallbackDoesNotClaimEquipmentInventory() throws {
    var place = fixture()
    place.coordinateQuality = .park
    place.equipment = []
    place.equipmentInformationKnown = false
    place.facilityTypes = ["야외체력단련시설"]
    XCTAssertTrue(place.matches("야외체력단련시설"))
    XCTAssertTrue(place.equipmentKinds.isEmpty)
    XCTAssertTrue(place.equipmentSummary.contains("미확인"))
  }

  func testRejectsDuplicateIDsAndPartialCoordinates() throws {
    let place = fixture()
    XCTAssertThrowsError(try CatalogValidation.validate(pack([place, place])))
    var partial = place
    partial.longitude = nil
    XCTAssertThrowsError(try CatalogValidation.validate(pack([partial])))
    partial.latitude = nil
    partial.coordinateQuality = .unknown
    XCTAssertNoThrow(try CatalogValidation.validate(pack([partial])))
    XCTAssertNil(partial.coordinate)
  }

  func testNationalPlacesRequireSourceSummaryButLegacyCatalogsStillLoad() throws {
    var national = fixture()
    national.id = "national-equipment-fixture"
    national.provenance.sourceURL = NationalEquipment.sourceURL
    XCTAssertThrowsError(try CatalogValidation.validate(pack([national])))
    XCTAssertNoThrow(try CatalogValidation.validate(pack([fixture()])))
    var catalog = pack([national])
    catalog.sources = [CatalogSourceSummary(id: NationalEquipment.sourceID,
      capturedAt: "2026-10-22", rowCount: 1, placeCount: 1,
      missingCoordinateCount: 0, regions: [national.regionName])]
    XCTAssertNoThrow(try CatalogValidation.validate(catalog))
    catalog.sources?[0].capturedAt = "invalid"
    XCTAssertThrowsError(try CatalogValidation.validate(catalog))
    catalog.sources?[0].capturedAt = "2026-10-22"
    catalog.places[0].provenance.capturedAt = "invalid"
    XCTAssertThrowsError(try CatalogValidation.validate(catalog))
  }

  func testRejectsInvalidCoordinatesAndNegativeCount() throws {
    var place = fixture()
    place.latitude = 91
    XCTAssertThrowsError(try CatalogValidation.validate(pack([place])))
    place.latitude = 35
    place.equipment[0].count = -1
    XCTAssertThrowsError(try CatalogValidation.validate(pack([place])))
  }

  func testManifestRejectsBadHashInsecureURLAndDuplicatePacks() throws {
    let item = CatalogManifest.Pack(url: "https://example.org/data.json", byteCount: 100,
      sha256: String(repeating: "a", count: 64), placeCount: 1)
    var manifest = CatalogManifest(schemaVersion: 1, version: 2, generatedAt: "2026-10-22", packs: [item])
    XCTAssertNoThrow(try CatalogValidation.validate(manifest))
    manifest.packs.append(item)
    XCTAssertThrowsError(try CatalogValidation.validate(manifest))
    manifest.packs = [item]
    manifest.packs[0].sha256 = "bad"
    XCTAssertThrowsError(try CatalogValidation.validate(manifest))
    XCTAssertThrowsError(try CatalogValidation.httpsURL("http://example.org/data.json"))
    XCTAssertThrowsError(try CatalogValidation.httpsURL("https://user:password@example.org/data.json"))
  }

  func testDistanceSortRetainsMissingCoordinatesAtEnd() {
    var near = fixture()
    near.name = "Z 가까운 시설"
    var far = fixture()
    far.id = "far"; far.name = "A 먼 시설"; far.latitude = 36
    var missing = fixture()
    missing.id = "missing"; missing.name = "0 좌표 없음"
    missing.latitude = nil; missing.longitude = nil; missing.coordinateQuality = .unknown
    let query = CatalogSearchQuery(revision: 0, text: "", region: "", equipmentKind: "",
      favoritesOnly: false, favorites: [], latitude: 35, longitude: 128)
    XCTAssertEqual(CatalogSearch.results(in: [missing, far, near], query: query).map(\.id), [near.id, far.id, missing.id])
  }

  func testRegionAndFavoritesAreIndependentFilters() {
    var elsewhere = fixture(); elsewhere.id = "elsewhere"; elsewhere.regionCode = "other"
    let query = CatalogSearchQuery(revision: 0, text: "", region: "48250", equipmentKind: "철봉",
      favoritesOnly: true, favorites: [fixture().id, elsewhere.id], latitude: nil, longitude: nil)
    XCTAssertEqual(CatalogSearch.results(in: [fixture(), elsewhere], query: query).map(\.id), [fixture().id])
  }

  @MainActor func testCorruptCurrentFileLoadsLastGoodAndPreservesSource() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let corrupt = Data("broken".utf8)
    try corrupt.write(to: directory.appendingPathComponent("current.json"))
    try JSONEncoder().encode(pack([fixture()])).write(to: directory.appendingPathComponent("last-good.json"))
    let suite = "CatalogTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = CatalogStore(defaults: defaults, directory: directory, bundledURL: nil)
    XCTAssertEqual(store.places.map(\.id), [fixture().id])
    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("current.json")), corrupt)
  }

  @MainActor func testFavoritesAndManifestPersistAcrossStoreReload() throws {
    let suite = "CatalogTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = CatalogStore(defaults: defaults, directory: directory, bundledURL: nil)
    first.toggleFavorite(fixture())
    try first.configureManifest("https://example.org/catalog.json")
    let second = CatalogStore(defaults: defaults, directory: directory, bundledURL: nil)
    XCTAssertTrue(second.isFavorite(fixture()))
    XCTAssertEqual(second.manifestURL, "https://example.org/catalog.json")
  }

  @MainActor func testRejectedImportKeepsActiveCatalog() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try JSONEncoder().encode(pack([fixture()])).write(to: directory.appendingPathComponent("current.json"))
    var invalid = pack([fixture()]); invalid.schemaVersion = 99
    let imported = directory.appendingPathComponent("unsupported.json")
    try JSONEncoder().encode(invalid).write(to: imported)
    let suite = "CatalogTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = CatalogStore(defaults: defaults, directory: directory, bundledURL: nil)
    await store.importJSON(from: imported)
    XCTAssertEqual(store.version, 1)
    XCTAssertEqual(store.places.count, 1)
    XCTAssertNotNil(store.errorMessage)
  }

  func testKnownParkEquipmentRemainsSearchableWithoutClaimingEquipmentCoordinates() throws {
    var place = fixture()
    place.coordinateQuality = .park
    place.provenance.datasetTitle = "전국도시공원정보표준데이터"
    XCTAssertFalse(place.isParkReference)
    XCTAssertEqual(place.coverageTitle, "공개 기구 목록 있음")
    XCTAssertEqual(place.coordinateQuality.title, "공원 대표 위치")
    let query = CatalogSearchQuery(revision: 0, text: "", region: "", equipmentKind: "철봉",
      favoritesOnly: false, favorites: [], latitude: nil, longitude: nil)
    XCTAssertEqual(CatalogSearch.results(in: [place], query: query).map(\.id), [place.id])
    place.equipment = []
    place.equipmentCount = 3
    XCTAssertFalse(place.isParkReference)
    place.equipmentInformationKnown = false
    XCTAssertTrue(place.isParkReference)
    place.provenance.datasetTitle = "울산광역시 생활체육공원 현황"
    XCTAssertTrue(place.isParkReference)
    var allEquipment = query
    allEquipment.equipmentKind = ""
    XCTAssertTrue(CatalogSearch.results(in: [place], query: allEquipment).isEmpty)
  }

  func testParkCoordinatesDoNotHideConfirmedNationalInstallationWithUnknownInventory() throws {
    var place = fixture()
    place.id = "national-equipment-confirmed-installation"
    place.provenance.sourceURL = NationalEquipment.sourceURL
    place.latitude = nil; place.longitude = nil; place.coordinateQuality = .unknown
    place.equipment = []
    place.equipmentInformationKnown = false
    var original = pack([place])
    original.sources = [.init(id: NationalEquipment.sourceID, capturedAt: "2026-10-22", rowCount: 1,
      placeCount: 1, missingCoordinateCount: 1, regions: [place.regionName])]
    let entry = CoordinateSupplementPack.Entry(placeID: place.id, latitude: 35, longitude: 128,
      quality: .park, sourceURL: "https://example.org/park", method: "official-park-exact-match",
      capturedAt: "2026-10-26", matchedAddress: place.address)
    let (enriched, _) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [entry]), into: original)
    XCTAssertEqual(enriched.places[0].coordinateQuality, .park)
    XCTAssertFalse(enriched.places[0].isParkReference)
    XCTAssertEqual(enriched.places[0].coverageTitle, "설치 장소 · 기구 종류 미제공")
    let query = CatalogSearchQuery(revision: 1, text: "", region: "", equipmentKind: "",
      favoritesOnly: false, favorites: [], latitude: nil, longitude: nil)
    XCTAssertEqual(CatalogSearch.results(in: enriched.places, query: query).map(\.id), [place.id])
  }

  func testRegionalSourceIdentitySurvivesCodingAndRequiresAccurateSummary() throws {
    var place = fixture()
    place.sourceID = "regional-source"
    var sourcePack = pack([place])
    XCTAssertThrowsError(try CatalogValidation.validate(sourcePack))
    sourcePack.sources = [.init(id: "regional-source", capturedAt: "2026-10-22", rowCount: 3,
      placeCount: 1, missingCoordinateCount: 0, regions: [place.regionName], requiresPlaceSourceID: true)]
    let decoded = try CatalogValidation.decode(JSONEncoder().encode(sourcePack))
    XCTAssertEqual(decoded.places[0].sourceID, "regional-source")
    XCTAssertEqual(decoded.sources?.first?.requiresPlaceSourceID, true)
    var missingPlaces = decoded
    missingPlaces.places = []
    XCTAssertThrowsError(try CatalogValidation.validate(missingPlaces))
    missingPlaces.sources?[0].placeCount = 0
    missingPlaces.sources?[0].regions = []
    XCTAssertNoThrow(try CatalogValidation.validate(missingPlaces))
    sourcePack.sources?[0].missingCoordinateCount = 1
    XCTAssertThrowsError(try CatalogValidation.validate(sourcePack))
    sourcePack.sources?[0].missingCoordinateCount = 0
    sourcePack.sources?[0].regions = ["다른 지역"]
    XCTAssertThrowsError(try CatalogValidation.validate(sourcePack))
    XCTAssertNoThrow(try CatalogValidation.validate(pack([fixture()])))
  }

  func testRejectedRegionalPlacesLeaveAnAccurateEmptyMarkedSourceSummary() throws {
    var incoming = fixture()
    incoming.name = "다른 장소의 충돌 식별자"
    incoming.sourceID = "new-regional-source"
    var supplemental = pack([incoming])
    supplemental.sources = [.init(id: "new-regional-source", capturedAt: "2026-10-22", rowCount: 1,
      placeCount: 1, missingCoordinateCount: 0, regions: [incoming.regionName], requiresPlaceSourceID: true)]
    let (merged, conflicts) = try CatalogMerge.regional(supplemental, into: pack([fixture()]))
    XCTAssertEqual(conflicts, 1)
    XCTAssertEqual(merged.places[0].name, fixture().name)
    XCTAssertEqual(merged.sources?.first?.placeCount, 0)
    XCTAssertEqual(merged.sources?.first?.missingCoordinateCount, 0)
    XCTAssertEqual(merged.sources?.first?.regions, [])
    XCTAssertEqual(merged.sources?.first?.requiresPlaceSourceID, true)
  }

  func testAddressEstimateRequiresEvidenceAndKeepsProvenanceSeparate() throws {
    var place = fixture()
    place.coordinateQuality = .address
    XCTAssertThrowsError(try CatalogValidation.validate(pack([place])))
    place.coordinateEvidence = CoordinateEvidence(sourceURL: "https://example.org/geocode",
      method: "address-geocoding", capturedAt: "2026-10-26", matchedAddress: place.address)
    let decoded = try CatalogValidation.decode(JSONEncoder().encode(pack([place])))
    XCTAssertEqual(decoded.places[0].coordinateQuality, .address)
    XCTAssertEqual(decoded.places[0].provenance.sourceURL, "https://example.org/data")
    XCTAssertEqual(decoded.places[0].coordinateEvidence?.sourceURL, "https://example.org/geocode")
  }

  func testCoordinateSupplementRejectsMismatchesStaleEvidenceAndConflicts() throws {
    var place = fixture()
    place.latitude = nil; place.longitude = nil; place.coordinateQuality = .unknown
    let entry = CoordinateSupplementPack.Entry(placeID: place.id, latitude: 35, longitude: 128,
      quality: .park, sourceURL: "https://example.org/park", method: "official-park-exact-match",
      capturedAt: "2026-10-26", matchedAddress: place.address, sourceRecordID: "park-1", matchedName: place.name)
    let (applied, rejected) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [entry]), into: pack([place]))
    XCTAssertEqual(rejected, 0)
    XCTAssertEqual(applied.places[0].coordinateQuality, .park)
    XCTAssertEqual(applied.places[0].coordinateEvidence?.sourceRecordID, "park-1")
    var badAddress = entry; badAddress.matchedAddress += " 2"
    var badName = entry; badName.matchedName = "다른 공원"
    var stale = entry; stale.capturedAt = "2026-09-01"
    for invalid in [badAddress, badName, stale] {
      let (unchanged, rejected) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [invalid]), into: pack([place]))
      XCTAssertNil(unchanged.places[0].coordinate)
      XCTAssertEqual(rejected, 1)
    }
    let (duplicate, duplicateCount) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [entry, entry]), into: pack([place]))
    XCTAssertNil(duplicate.places[0].coordinate)
    XCTAssertEqual(duplicateCount, 2)
    place.coordinateConflict = true
    let (conflict, conflictCount) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [entry]), into: pack([place]))
    XCTAssertNil(conflict.places[0].coordinate)
    XCTAssertEqual(conflictCount, 1)
    var changed = entry; changed.latitude = 36
    let (original, originalCount) = try CatalogMerge.coordinates(.init(schemaVersion: 1, entries: [changed]), into: pack([fixture()]))
    XCTAssertEqual(original.places[0].latitude, 35)
    XCTAssertNil(original.places[0].coordinateEvidence)
    XCTAssertEqual(originalCount, 1)
  }

  @MainActor func testServiceKeyUsesDedicatedStorageAndMissingKeyDoesNotSelectPortal() async throws {
    let suite = "CatalogKeyTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = TestCatalogKeyStorage()
    let store = CatalogStore(defaults: defaults, bundledURL: nil, serviceKeyStorage: storage, loadImmediately: false)
    try store.configureOfficialAPIKey("test%2Bkey")
    XCTAssertTrue(store.hasOfficialAPIKey)
    XCTAssertEqual(try storage.load(), "test+key")
    XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("test+key") == true })
    try store.removeOfficialAPIKey()
    XCTAssertFalse(store.hasOfficialAPIKey)
    await store.refreshNational()
    XCTAssertTrue(store.errorMessage?.contains("인증키") == true)
  }

  private func fixture() -> EquipmentPlace {
    EquipmentPlace(id: "test-place", name: "시험 공원", address: "경상남도 김해시 시험로 1",
      regionCode: "48250", regionName: "경상남도 김해시", locality: "시험동",
      latitude: 35, longitude: 128, coordinateQuality: .facility,
      equipment: [EquipmentItem(name: "철봉", count: 2)], equipmentCount: 2, facilityTypes: [],
      equipmentInformationKnown: true, managingDepartment: nil,
      provenance: PlaceProvenance(provider: "시험 제공기관", datasetTitle: "시험용 자료",
        sourceURL: "https://example.org/data", sourceRecordID: "1", referenceDate: "2026-10-01",
        capturedAt: "2026-10-22", license: "시험 데이터", note: nil))
  }

  private func pack(_ places: [EquipmentPlace]) -> CatalogPack {
    CatalogPack(schemaVersion: 1, version: 1, generatedAt: "2026-10-22", places: places)
  }
}

private final class TestCatalogKeyStorage: CatalogServiceKeyStorage, @unchecked Sendable {
  private var value: String?
  func load() throws -> String? { value }
  func save(_ value: String) throws { self.value = value }
  func delete() throws { value = nil }
}
