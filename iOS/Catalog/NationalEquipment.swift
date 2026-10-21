import Foundation
import CoreFoundation
import CryptoKit

enum NationalEquipment {
  static let sourceID = "data-go-kr:15139207"
  static let sourceURL = "https://www.data.go.kr/data/15139207/standard.do"

  private static let identityFields = [
    "CTPV_NM", "SGG_NM", "INSTL_PLC_NM", "LCTN_ROAD_NM_ADDR", "LCTN_LOTNO_ADDR"
  ]
  private static let schemaFields = Set(identityFields + [
    "LAT", "LOT", "SPRTGD_NM", "SPRTGD_QTY", "DATA_CRTR_YMD", "MNG_INST_NM"
  ])
  private static let aliases = [
    "INSTL_PLC_NM": "설치장소명", "CTPV_NM": "시도명", "SGG_NM": "시군구명",
    "LCTN_ROAD_NM_ADDR": "소재지도로명주소", "LCTN_LOTNO_ADDR": "소재지지번주소",
    "LAT": "위도", "LOT": "경도", "SPRTGD_NM": "운동기구명", "SPRTGD_QTY": "운동기구수량",
    "MNG_INST_NM": "관리기관명", "MNG_INST_TELNO": "관리기관전화번호",
    "DATA_CRTR_YMD": "데이터기준일자", "INSTT_CODE": "제공기관코드", "INSTT_NM": "제공기관명"
  ]
  // Match str.strip() in the offline Python importer without changing interior whitespace.
  private static let sourceWhitespace = CharacterSet(charactersIn:
    "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{001C}\u{001D}\u{001E}\u{001F} "
      + "\u{0085}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}"
      + "\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}")

  private struct Group {
    var identity: [String]
    var rows: [[String: Any]]
  }

  private struct Coordinate: Hashable {
    var latitude: Double
    var longitude: Double
  }

  private struct Label {
    var name: String
    var counts: [Int?]
  }

  static func normalize(_ data: Data, capturedAt: String) throws -> CatalogPack {
    guard data.count <= CatalogValidation.maximumCollectionBytes else { throw CatalogError.tooLarge }
    guard !capturedAt.isEmpty else { throw CatalogError.invalid("전국 자료 수집일 누락") }
    let object = try JSONSerialization.jsonObject(with: data)
    let rawRows: Any
    let declaredFields: Any?
    if let envelope = object as? [String: Any] {
      if let claimedSource = envelope["sourceID"] {
        guard let claimedSource = claimedSource as? String, claimedSource == sourceID else {
          throw CatalogError.invalid("전국 실외운동기구 자료의 출처가 일치하지 않습니다.")
        }
      }
      guard let records = envelope["records"] else {
        throw CatalogError.invalid("전국 자료의 records 목록 누락")
      }
      rawRows = records
      declaredFields = envelope["fields"]
    } else {
      rawRows = object
      declaredFields = nil
    }
    guard let rows = rawRows as? [[String: Any]], !rows.isEmpty else {
      throw CatalogError.invalid("전국 실외운동기구 자료에 원본 행이 없습니다.")
    }
    guard rows.count <= CatalogValidation.maximumPlaces else { throw CatalogError.tooLarge }
    let columns: Set<String>
    if let declaredFields {
      columns = try fieldNames(declaredFields)
    } else {
      var observedColumns = Set<String>()
      for row in rows {
        observedColumns.formUnion(row.keys.map(canonicalField))
      }
      columns = observedColumns
    }
    guard schemaFields.isSubset(of: columns) else {
      throw CatalogError.invalid("전국 실외운동기구 자료의 컬럼 구성이 아닙니다.")
    }

    var groups: [Data: Group] = [:]
    for (index, rawRow) in rows.enumerated() {
      let row = canonicalRow(rawRow)
      // The portal declares every column in fields, but omits null-valued record keys.
      // Only the province, district and installation name must have a value in every row.
      let identity = try identityFields.map { try text(row[$0], field: $0) }
      guard identity.prefix(3).allSatisfy({ !$0.isEmpty }),
        !identity.contains(where: { $0.contains("\u{001F}") }) else {
        throw CatalogError.invalid("전국 자료 \(index + 1)행의 지역·설치장소 정보 오류")
      }
      let key = Data(identity.joined(separator: "\u{001F}").utf8)
      if groups[key] == nil { groups[key] = Group(identity: identity, rows: []) }
      groups[key]?.rows.append(row)
    }

    let places = try groups.values.map { group in
      try place(from: group, digest: digest(group.identity, length: 24), capturedAt: capturedAt)
    }.sorted { $0.id < $1.id }
    let summary = CatalogSourceSummary(id: sourceID, capturedAt: capturedAt,
      rowCount: rows.count, placeCount: places.count,
      missingCoordinateCount: places.filter { $0.latitude == nil }.count,
      regions: uniqueSorted(places.map(\.regionName)))
    let pack = CatalogPack(schemaVersion: 1, version: 1, generatedAt: capturedAt,
      places: places, sources: [summary])
    // Completeness against an envelope's totalCount belongs to the download/import boundary.
    try CatalogValidation.validate(pack)
    return pack
  }

  private static func place(from group: Group, digest: String, capturedAt: String) throws -> EquipmentPlace {
    let identity = group.identity
    let coordinates = Set(try group.rows.compactMap { try coordinate($0) })
    let chosenCoordinate = coordinates.count == 1 ? coordinates.first : nil
    var labels: [Data: Label] = [:]
    var quantities: [Int?] = []
    for row in group.rows {
      let name = try text(row["SPRTGD_NM"], field: "SPRTGD_NM")
      let count = quantity(try text(row["SPRTGD_QTY"], field: "SPRTGD_QTY"))
      quantities.append(count)
      if !name.isEmpty {
        guard count.map({ $0 <= 100_000 }) ?? true else {
          throw CatalogError.invalid("전국 자료의 기구 수량이 표시 가능 범위를 초과합니다.")
        }
        let key = Data(name.utf8)
        if labels[key] == nil { labels[key] = Label(name: name, counts: []) }
        labels[key]?.counts.append(count)
      }
    }
    let equipment = labels.values.sorted { scalarOrder($0.name, $1.name) }.map { label in
      EquipmentItem(name: label.name, count: label.counts.count == 1 ? label.counts[0] : nil)
    }
    let dates = try values("DATA_CRTR_YMD", in: group.rows)
    let providers = try values("INSTT_NM", in: group.rows)
    let departments = try values("MNG_INST_NM", in: group.rows)
    var notes = [
      "제공기관이 공개한 설치장소 자료이며 전국 모든 지역의 완전한 목록은 아닙니다. 시설 대표 좌표이며 현장 위치·운영·고장·철거 여부는 미확인입니다.",
      "원자료에 고유 장소 ID가 없어 시도·시군구·설치장소명·도로명주소·지번주소로 합성 ID를 생성했습니다. 주소나 명칭이 바뀌면 ID도 바뀔 수 있습니다.",
      "기구명은 복합 목록을 포함한 원문이며 행 수량을 개별 기구별로 나누지 않았습니다."
    ]
    if group.rows.count > 1 {
      notes.append("여러 원본 행을 묶은 장소입니다. 중복 보고와 개별 기구 행을 구별할 수 없어 총수량을 합산하지 않았습니다.")
    }
    if labels.values.contains(where: { $0.counts.count > 1 }) {
      notes.append("같은 기구명이 반복된 행은 표시를 합치고 해당 기구 수량을 미확인으로 남겼습니다.")
    }
    if coordinates.count > 1 {
      notes.append("같은 설치장소의 원본 좌표가 서로 달라 대표 좌표를 선택하지 않았습니다.")
    }
    if dates.count > 1 {
      notes.append("원본 행의 자료 기준일이 서로 달라 단일 기준일을 표시하지 않았습니다.")
    }
    return EquipmentPlace(id: "national-equipment-" + digest, name: identity[2],
      address: identity[3].isEmpty ? identity[4] : identity[3],
      regionCode: "national-region-" + self.digest(Array(identity.prefix(2)), length: 16),
      regionName: identity[0] + " " + identity[1], locality: nil,
      latitude: chosenCoordinate?.latitude, longitude: chosenCoordinate?.longitude,
      coordinateQuality: chosenCoordinate == nil ? .unknown : .facility,
      equipment: equipment, equipmentCount: group.rows.count == 1 ? quantities[0] : nil,
      facilityTypes: [], equipmentInformationKnown: !equipment.isEmpty || quantities.contains(where: { $0 != nil }),
      managingDepartment: departments.isEmpty ? nil : departments.joined(separator: " · "),
      provenance: PlaceProvenance(
        provider: providers.isEmpty ? "공공데이터포털 · 전국 지방자치단체" : providers.joined(separator: " · "),
        datasetTitle: "전국실외운동기구설치정보표준데이터", sourceURL: sourceURL,
        sourceRecordID: "설치장소 합성 ID \(digest) · 원본 \(group.rows.count)행",
        referenceDate: dates.count == 1 ? dates[0] : nil, capturedAt: capturedAt,
        license: "공공데이터포털 공개 표준데이터. 제공기관별 이용허락범위는 원자료에서 확인하세요.",
        note: notes.joined(separator: " ")))
  }

  private static func canonicalRow(_ row: [String: Any]) -> [String: Any] {
    var result = row
    for (key, alias) in aliases where result[key] == nil {
      if let value = row[alias] { result[key] = value }
    }
    return result
  }

  private static func canonicalField(_ field: String) -> String {
    aliases.first(where: { $0.value == field })?.key ?? field
  }

  private static func fieldNames(_ fields: Any) throws -> Set<String> {
    guard let fields = fields as? [Any], !fields.isEmpty, fields.count <= 100 else {
      throw CatalogError.invalid("전국 자료의 fields 컬럼 목록 오류")
    }
    return try Set(fields.map { field in
      let name: String?
      if let field = field as? String {
        name = field
      } else if let field = field as? [String: Any] {
        name = field["id"] as? String
      } else {
        name = nil
      }
      guard let name, !name.isEmpty else {
        throw CatalogError.invalid("전국 자료의 fields 컬럼 이름 오류")
      }
      return canonicalField(name)
    })
  }

  private static func text(_ value: Any?, field: String) throws -> String {
    guard let value, !(value is NSNull) else { return "" }
    let result: String
    if let string = value as? String {
      result = string
    } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      result = number.stringValue
    } else {
      throw CatalogError.invalid("전국 자료 \(field) 컬럼의 값 형식 오류")
    }
    return result.trimmingCharacters(in: sourceWhitespace)
  }

  private static func quantity(_ value: String) -> Int? {
    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
      let count = Int(value), (0...1_000_000).contains(count) else { return nil }
    return count
  }

  private static func coordinate(_ row: [String: Any]) throws -> Coordinate? {
    let latitudeText = try text(row["LAT"], field: "LAT")
    let longitudeText = try text(row["LOT"], field: "LOT")
    guard let latitude = Double(latitudeText), let longitude = Double(longitudeText),
      latitude.isFinite, longitude.isFinite,
      (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
    return Coordinate(latitude: latitude, longitude: longitude)
  }

  private static func digest(_ parts: [String], length: Int) -> String {
    let bytes = Data(parts.joined(separator: "\u{001F}").utf8)
    return SHA256.hash(data: bytes).prefix(length / 2).map { String(format: "%02x", $0) }.joined()
  }

  private static func values(_ field: String, in rows: [[String: Any]]) throws -> [String] {
    try uniqueSorted(rows.map { try text($0[field], field: field) }.filter { !$0.isEmpty })
  }

  private static func uniqueSorted(_ values: [String]) -> [String] {
    // Raw UTF-8 keys retain Python's distinction between composed/decomposed source text.
    let byBytes = Dictionary(values.map { (Data($0.utf8), $0) }, uniquingKeysWith: { first, _ in first })
    return byBytes.values.sorted(by: scalarOrder)
  }

  private static func scalarOrder(_ left: String, _ right: String) -> Bool {
    left.unicodeScalars.map(\.value).lexicographicallyPrecedes(right.unicodeScalars.map(\.value))
  }
}
