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
