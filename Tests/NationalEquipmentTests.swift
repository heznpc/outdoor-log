import Foundation
import XCTest
@testable import OutdoorLog

final class NationalEquipmentTests: XCTestCase {
  private let capturedAt = "2026-10-22T00:00:00Z"

  func testPublicSourceFixtureMatchesOfflineIdentityAndPreservesCompoundQuantity() throws {
    let pack = try normalize([row()])
    let place = try XCTUnwrap(pack.places.first)
    XCTAssertEqual(pack.schemaVersion, 1)
    XCTAssertEqual(pack.version, 1)
    XCTAssertEqual(pack.generatedAt, capturedAt)
    XCTAssertEqual(place.id, "national-equipment-5af5bb2bbd26619002215d22")
    XCTAssertEqual(place.regionCode, "national-region-cd3f6334e2110141")
    XCTAssertEqual(place.regionName, "충청남도 홍성군")
    XCTAssertEqual(place.equipment, [EquipmentItem(name: "입식사이클+체어웨이 외3종", count: 4)])
    XCTAssertEqual(place.equipmentCount, 4)
    XCTAssertTrue(place.equipmentInformationKnown)
    XCTAssertEqual(place.coordinateQuality, .facility)
    XCTAssertEqual(try XCTUnwrap(place.latitude), 36.61313848, accuracy: 0.00000001)
    XCTAssertEqual(try XCTUnwrap(place.longitude), 126.6950384, accuracy: 0.00000001)
    XCTAssertEqual(place.provenance.sourceURL, NationalEquipment.sourceURL)
    XCTAssertEqual(place.provenance.license,
      "공공데이터포털 공개 표준데이터. 제공기관별 이용허락범위는 원자료에서 확인하세요.")
    XCTAssertEqual(place.provenance.sourceRecordID,
      "설치장소 합성 ID 5af5bb2bbd26619002215d22 · 원본 1행")
    XCTAssertTrue(place.provenance.note?.contains("고유 장소 ID가 없어") == true)
    let summary = try XCTUnwrap(pack.sources?.first)
    XCTAssertEqual(summary.id, NationalEquipment.sourceID)
    XCTAssertEqual(summary.capturedAt, capturedAt)
    XCTAssertEqual(summary.rowCount, 1)
    XCTAssertEqual(summary.placeCount, 1)
    XCTAssertEqual(summary.missingCoordinateCount, 0)
    XCTAssertEqual(summary.regions, ["충청남도 홍성군"])
  }

  func testRowOrderDoesNotChangeNormalizedPlacesOrIDs() throws {
    let rows = [
      row(["SPRTGD_NM": "철봉", "SPRTGD_QTY": "2", "INSTT_NM": "제공기관 나"]),
      row(["SPRTGD_NM": "평행봉", "SPRTGD_QTY": "3", "INSTT_NM": "제공기관 가"]),
      row(["INSTL_PLC_NM": "다른 설치장소", "SPRTGD_NM": "허리돌리기"])
    ]
    let forward = try normalize(rows)
    let reversed = try normalize(Array(rows.reversed()))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    XCTAssertEqual(try encoder.encode(forward), try encoder.encode(reversed))
    XCTAssertEqual(forward.places.map(\.id), forward.places.map(\.id).sorted())
    let grouped = try XCTUnwrap(forward.places.first { $0.name == "산불대응센터" })
    XCTAssertEqual(grouped.equipment, [EquipmentItem(name: "철봉", count: 2),
      EquipmentItem(name: "평행봉", count: 3)])
    XCTAssertNil(grouped.equipmentCount)
    XCTAssertEqual(grouped.provenance.provider, "제공기관 가 · 제공기관 나")
    XCTAssertEqual(forward.sources?.first?.rowCount, 3)
    XCTAssertEqual(forward.sources?.first?.placeCount, 2)
  }

  func testIdentityTrimsOnlyEdgesAndExcludesInventoryCoordinatesAndDates() throws {
    let original = try normalize([row()]).places[0]
    let changed = try normalize([row([
      "INSTL_PLC_NM": " \t산불대응센터\n", "CTPV_NM": " 충청남도 ",
      "SPRTGD_NM": "새 기구명", "SPRTGD_QTY": "5", "LAT": "37", "LOT": "127",
      "DATA_CRTR_YMD": "2026-10-01", "INSTT_NM": "변경된 제공기관"
    ])]).places[0]
    XCTAssertEqual(original.id, changed.id)
    XCTAssertEqual(changed.name, "산불대응센터")
    let renamed = try normalize([row(["INSTL_PLC_NM": "산불 대응센터"])]).places[0]
    XCTAssertNotEqual(original.id, renamed.id)
    XCTAssertEqual(renamed.name, "산불 대응센터")
  }

  func testRepeatedRowsDoNotInflateEquipmentCounts() throws {
    let duplicate = row(["SPRTGD_NM": "철봉", "SPRTGD_QTY": "2"])
    let pack = try normalize([duplicate, duplicate])
    let place = pack.places[0]
    XCTAssertEqual(place.equipment, [EquipmentItem(name: "철봉", count: nil)])
    XCTAssertNil(place.equipmentCount)
    XCTAssertEqual(place.coordinateQuality, .facility)
    XCTAssertTrue(place.provenance.note?.contains("같은 기구명이 반복된 행") == true)
    XCTAssertEqual(pack.sources?.first?.rowCount, 2)
    XCTAssertEqual(pack.sources?.first?.placeCount, 1)
  }

  func testConflictingCoordinatesAndReferenceDatesRemainUnknown() throws {
    let pack = try normalize([row(), row([
      "LAT": "37", "LOT": "127", "DATA_CRTR_YMD": "2026-09-01"
    ])])
    let place = pack.places[0]
    XCTAssertNil(place.latitude)
    XCTAssertNil(place.longitude)
    XCTAssertEqual(place.coordinateQuality, .unknown)
    XCTAssertNil(place.provenance.referenceDate)
    XCTAssertTrue(place.provenance.note?.contains("원본 좌표가 서로 달라") == true)
    XCTAssertEqual(pack.sources?.first?.missingCoordinateCount, 1)
  }

  func testMissingCoordinateRowsDoNotEraseOneKnownCoordinatePair() throws {
    let place = try normalize([row(), row(["LAT": NSNull(), "LOT": NSNull()])]).places[0]
    XCTAssertEqual(place.coordinateQuality, .facility)
    XCTAssertEqual(try XCTUnwrap(place.latitude), 36.61313848, accuracy: 0.00000001)
  }

  func testNullSourceValuesRemainUnknownAndUseLotAddress() throws {
    let pack = try normalize([row([
      "LCTN_ROAD_NM_ADDR": NSNull(), "LAT": NSNull(), "LOT": NSNull(),
      "SPRTGD_NM": NSNull(), "SPRTGD_QTY": NSNull(), "DATA_CRTR_YMD": NSNull(),
      "MNG_INST_NM": NSNull(), "INSTT_NM": NSNull()
    ])])
    let place = pack.places[0]
    XCTAssertEqual(place.address, "충청남도 홍성군 홍성읍 내법리 234-6")
    XCTAssertEqual(place.coordinateQuality, .unknown)
    XCTAssertTrue(place.equipment.isEmpty)
    XCTAssertNil(place.equipmentCount)
    XCTAssertFalse(place.equipmentInformationKnown)
    XCTAssertNil(place.provenance.referenceDate)
    XCTAssertNil(place.managingDepartment)
    XCTAssertEqual(place.provenance.provider, "공공데이터포털 · 전국 지방자치단체")
    XCTAssertEqual(pack.sources?.first?.missingCoordinateCount, 1)
  }

  func testUnnamedQuantityIsKnownWithoutInventingEquipmentName() throws {
    let place = try normalize([row(["SPRTGD_NM": NSNull(), "SPRTGD_QTY": "0"])]).places[0]
    XCTAssertTrue(place.equipment.isEmpty)
    XCTAssertEqual(place.equipmentCount, 0)
    XCTAssertTrue(place.equipmentInformationKnown)
  }

  func testNonIntegerQuantityAndCompoundPunctuationAreNotInferred() throws {
    let place = try normalize([row([
      "SPRTGD_NM": "철봉/평행봉,허리돌리기", "SPRTGD_QTY": "3대"
    ])]).places[0]
    XCTAssertEqual(place.equipment, [EquipmentItem(name: "철봉/평행봉,허리돌리기", count: nil)])
    XCTAssertNil(place.equipmentCount)
    XCTAssertTrue(place.equipmentInformationKnown)
  }

  func testKoreanPortalExportColumnsAreAccepted() throws {
    let koreanRow: [String: Any] = [
      "설치장소명": "산불대응센터", "시도명": "충청남도", "시군구명": "홍성군",
      "소재지도로명주소": "충청남도 홍성군 홍성읍 내법길 82-270",
      "소재지지번주소": "충청남도 홍성군 홍성읍 내법리 234-6",
      "위도": "36.61313848", "경도": "126.6950384", "운동기구명": "입식사이클+체어웨이 외3종",
      "운동기구수량": "4", "관리기관명": "홍성군", "데이터기준일자": "2026-06-01",
      "제공기관명": "충청남도 홍성군"
    ]
    let pack = try normalize(["fields": koreanRow.keys.map { ["id": $0] }, "records": [koreanRow]])
    XCTAssertEqual(pack.places[0].id, "national-equipment-5af5bb2bbd26619002215d22")
    XCTAssertEqual(pack.places[0].equipmentCount, 4)
    XCTAssertEqual(pack.sources?.first?.rowCount, 1)
  }

  func testPortalDeclaredSchemaAllowsAllNullableRecordKeysToBeOmitted() throws {
    let columns = ["설치장소명", "시도명", "시군구명", "소재지도로명주소", "소재지지번주소",
      "위도", "경도", "운동기구명", "운동기구수량", "관리기관명", "데이터기준일자"]
    let sparseRecord = ["설치장소명": "산불대응센터", "시도명": "충청남도", "시군구명": "홍성군"]
    let pack = try normalize(["fields": columns.map { ["id": $0] }, "records": [sparseRecord]])
    let place = pack.places[0]
    XCTAssertEqual(place.name, "산불대응센터")
    XCTAssertEqual(place.address, "")
    XCTAssertTrue(place.equipment.isEmpty)
    XCTAssertNil(place.equipmentCount)
    XCTAssertFalse(place.equipmentInformationKnown)
    XCTAssertNil(place.latitude)
    XCTAssertNil(place.longitude)
    XCTAssertNil(place.managingDepartment)
    XCTAssertNil(place.provenance.referenceDate)
    XCTAssertEqual(pack.sources?.first?.missingCoordinateCount, 1)
  }

  func testRowsCanShareSchemaWithoutRepeatingNullableKeys() throws {
    var sparseRow = row(["INSTL_PLC_NM": "기구 정보 미공개 장소"])
    for key in ["LCTN_ROAD_NM_ADDR", "LCTN_LOTNO_ADDR", "LAT", "LOT", "SPRTGD_NM",
      "SPRTGD_QTY", "DATA_CRTR_YMD", "MNG_INST_NM", "INSTT_NM"] {
      sparseRow.removeValue(forKey: key)
    }
    let pack = try normalize([row(), sparseRow])
    let place = try XCTUnwrap(pack.places.first { $0.name == "기구 정보 미공개 장소" })
    XCTAssertFalse(place.equipmentInformationKnown)
    XCTAssertEqual(place.coordinateQuality, .unknown)
    XCTAssertEqual(pack.sources?.first?.rowCount, 2)
    XCTAssertEqual(pack.sources?.first?.placeCount, 2)
    XCTAssertThrowsError(try normalize([sparseRow]))
  }

  func testForeignOrMalformedDeclaredSchemaIsRejectedDespiteValidRecordShape() throws {
    XCTAssertThrowsError(try normalize(["fields": [["id": "공원명"], ["id": "공원구분"]],
      "records": [row()]]))
    XCTAssertThrowsError(try normalize(["fields": ["id": "설치장소명"], "records": [row()]]))
    XCTAssertThrowsError(try normalize(["fields": [["id": 1]], "records": [row()]]))
    XCTAssertThrowsError(try normalize(["fields": NSNull(), "records": [row()]]))
    XCTAssertThrowsError(try normalize([["공원명": "공원", "시도명": "충청남도", "시군구명": "홍성군"]]))
  }

  func testDeclaredColumnsCannotReplaceRequiredIdentityValues() throws {
    let fields = row().keys.map { ["id": $0] }
    var missingName = row()
    missingName.removeValue(forKey: "INSTL_PLC_NM")
    XCTAssertThrowsError(try normalize(["fields": fields, "records": [missingName]]))
    XCTAssertThrowsError(try normalize(["fields": fields, "records": [row(["SGG_NM": NSNull()])]]))
  }

  func testEnvelopeReportsActualRowsLeavingCompletenessToImporter() throws {
    let pack = try normalize([
      "sourceID": NationalEquipment.sourceID, "totalCount": 999, "records": [row()]
    ])
    XCTAssertEqual(pack.sources?.first?.rowCount, 1)
    XCTAssertThrowsError(try normalize(["sourceID": "another-source", "records": [row()]]))
  }

  func testInvalidCoreIdentityAndMissingColumnsRejectWholeInput() throws {
    XCTAssertThrowsError(try normalize([row(), row(["INSTL_PLC_NM": " \n"])]))
    XCTAssertThrowsError(try normalize([row(["CTPV_NM": NSNull()])]))
    XCTAssertThrowsError(try normalize([row(["SGG_NM": "홍성\u{001F}군"])]))
    var missing = row()
    missing.removeValue(forKey: "SPRTGD_NM")
    XCTAssertThrowsError(try normalize([missing]))
    XCTAssertThrowsError(try normalize([[String: Any]]()))
  }

  func testInvalidScalarTypesAndOversizedNamedQuantitiesRejectWholeInput() throws {
    XCTAssertThrowsError(try normalize([row(["LAT": true])]))
    XCTAssertThrowsError(try normalize([row(["SPRTGD_NM": ["철봉"]])]))
    let oversized = row(["SPRTGD_QTY": "100001"])
    XCTAssertThrowsError(try normalize([oversized, oversized]))
  }

  func testDownloadPageFingerprintIgnoresOrderingAndPreservesMultiplicity() throws {
    let first = row(), second = row(["INSTL_PLC_NM": "다른 장소"])
    XCTAssertEqual(try NationalCatalogDownload.pageFingerprint([first, second]),
      try NationalCatalogDownload.pageFingerprint([second, first]))
    XCTAssertNotEqual(try NationalCatalogDownload.pageFingerprint([first, second]),
      try NationalCatalogDownload.pageFingerprint([first, first, second]))
    XCTAssertNotEqual(try NationalCatalogDownload.pageFingerprint([first, first, second]),
      try NationalCatalogDownload.pageFingerprint([first, second, second]))
  }

  private func normalize(_ object: Any) throws -> CatalogPack {
    try NationalEquipment.normalize(JSONSerialization.data(withJSONObject: object), capturedAt: capturedAt)
  }

  private func row(_ replacements: [String: Any] = [:]) -> [String: Any] {
    var result: [String: Any] = [
      "INSTL_PLC_NM": "산불대응센터", "CTPV_NM": "충청남도", "SGG_NM": "홍성군",
      "LCTN_ROAD_NM_ADDR": "충청남도 홍성군 홍성읍 내법길 82-270",
      "LCTN_LOTNO_ADDR": "충청남도 홍성군 홍성읍 내법리 234-6",
      "LAT": "36.61313848", "LOT": "126.6950384", "SPRTGD_NM": "입식사이클+체어웨이 외3종",
      "SPRTGD_QTY": "4", "MNG_INST_NM": "홍성군", "DATA_CRTR_YMD": "2026-06-01",
      "INSTT_NM": "충청남도 홍성군"
    ]
    result.merge(replacements, uniquingKeysWith: { _, replacement in replacement })
    return result
  }
}
