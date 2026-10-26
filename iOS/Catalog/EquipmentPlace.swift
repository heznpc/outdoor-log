import Foundation
import CoreLocation

enum CoordinateQuality: String, Codable, Sendable {
  case equipment, facility, park, address, unknown

  var title: String {
    switch self {
    case .equipment: return "운동기구 위치"
    case .facility: return "시설 대표 위치"
    case .park: return "공원 대표 위치"
    case .address: return "주소로 추정한 위치"
    case .unknown: return "위치 미확인"
    }
  }

  var explanation: String {
    switch self {
    case .equipment: return "제공기관이 운동기구 위치로 공개한 좌표입니다. 현장 오차가 있을 수 있습니다."
    case .facility: return "제공기관의 시설 대표 좌표입니다. 개별 기구 위치와 다를 수 있습니다."
    case .park: return "공원 대표 좌표입니다. 운동기구의 위치나 설치 여부를 뜻하지 않습니다."
    case .address: return "공개 주소를 좌표로 변환한 추정 위치입니다. 건물·필지 중심일 수 있으며 운동기구 위치와 다를 수 있습니다."
    case .unknown: return "확인된 좌표가 없어 지도와 거리 계산에서 제외합니다. 주소로 장소를 찾아보세요."
    }
  }
}

struct EquipmentItem: Codable, Hashable, Sendable {
  var name: String
  var count: Int?
}

struct PlaceProvenance: Codable, Hashable, Sendable {
  var provider: String
  var datasetTitle: String
  var sourceURL: String
  var sourceRecordID: String
  var referenceDate: String?
  var capturedAt: String
  var license: String
  var note: String?
}

struct CoordinateEvidence: Codable, Hashable, Sendable {
  var sourceURL: String
  var method: String
  var capturedAt: String
  var matchedAddress: String
  var sourceRecordID: String? = nil
  var matchedName: String? = nil
}

struct EquipmentPlace: Identifiable, Codable, Sendable {
  var id: String
  var name: String
  var address: String
  var regionCode: String
  var regionName: String
  var locality: String?
  var latitude: Double?
  var longitude: Double?
  var coordinateQuality: CoordinateQuality
  var equipment: [EquipmentItem]
  var equipmentCount: Int?
  var facilityTypes: [String]
  var equipmentInformationKnown: Bool
  var managingDepartment: String?
  var provenance: PlaceProvenance
  var coordinateEvidence: CoordinateEvidence? = nil
  // A source-coordinate conflict must not become an apparently missing value
  // that a supplemental estimate can silently fill.
  var coordinateConflict: Bool? = nil
  // Optional for older schema-1 places; retained so regional source summaries
  // describe the places actually present after merging and coordinate filling.
  var sourceID: String? = nil

  var isNationalEquipment: Bool {
    id.hasPrefix("national-equipment-") && provenance.sourceURL == NationalEquipment.sourceURL
  }

  var catalogSourceID: String? {
    isNationalEquipment ? NationalEquipment.sourceID : sourceID
  }

  var isParkReference: Bool {
    !isNationalEquipment && (coordinateQuality == .park || provenance.datasetTitle.contains("도시공원"))
      && !equipmentInformationKnown
  }

  var coverageTitle: String {
    if isParkReference { return "공원 참고 자료 · 기구 설치 미확인" }
    return equipment.isEmpty ? "설치 장소 · 기구 종류 미제공" : "공개 기구 목록 있음"
  }

  var coordinate: CLLocationCoordinate2D? {
    guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
      (-90...90).contains(latitude), (-180...180).contains(longitude),
      coordinateQuality != .unknown else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  var equipmentKinds: [String] {
    equipment.flatMap { item in
      let components = item.name.split(separator: "+")
      guard components.count > 1 else { return [item.name] }
      // These are filter aliases only. Keep the source compound name and count
      // on the item; a combined machine does not imply a count for each part.
      let kinds = components.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: #"\s*\([0-9]+\s*(?:개|대)?\)$"#, with: "", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      return [item.name] + kinds
    }
  }
  var equipmentSummary: String {
    if !equipmentInformationKnown { return "개별 운동기구 종류·수량 미확인" }
    if equipment.isEmpty { return "제공된 운동기구 목록 없음" }
    return equipment.prefix(4).map(\.name).joined(separator: " · ")
      + (equipment.count > 4 ? " 외 \(equipment.count - 4)종" : "")
  }

  func distance(from location: CLLocation?) -> CLLocationDistance? {
    guard let location, let coordinate else { return nil }
    return location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
  }

  func matches(_ query: String) -> Bool {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let text = ([name, address, regionName, locality ?? ""] + equipmentKinds + facilityTypes)
      .joined(separator: " ")
    return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
  }
}

struct CatalogPack: Codable, Sendable {
  var schemaVersion: Int
  var version: Int
  var generatedAt: String
  var places: [EquipmentPlace]
  // Optional so existing schema-1 snapshots remain readable.
  var sources: [CatalogSourceSummary]? = nil
}

struct CatalogSourceSummary: Codable, Sendable {
  var id: String
  var capturedAt: String
  var rowCount: Int
  var placeCount: Int
  var missingCoordinateCount: Int
  var regions: [String]
  // Optional for schema-1 caches that did not distinguish full and partial inputs.
  // Last verified full download or trusted bundled snapshot.
  var completeCapturedAt: String? = nil
  // Last partial file input still represented in the merged source.
  var partialCapturedAt: String? = nil
  // New regional sources declare this explicitly; legacy summaries may have
  // no per-place source IDs and remain readable without the marker.
  var requiresPlaceSourceID: Bool? = nil
}

struct CatalogManifest: Codable, Sendable {
  struct Pack: Codable, Sendable {
    var url: String
    var byteCount: Int
    var sha256: String
    var placeCount: Int
  }
  var schemaVersion: Int
  var version: Int
  var generatedAt: String
  var packs: [Pack]
}

enum CatalogError: LocalizedError {
  case invalid(String)
  case unsupportedSchema
  case tooLarge
  case insecureURL
  case network(Int)
  case hashMismatch
  case olderVersion

  var errorDescription: String? {
    switch self {
    case .invalid(let reason): return "데이터를 적용하지 않았습니다: \(reason)"
    case .unsupportedSchema: return "지원하지 않는 데이터 형식입니다. schemaVersion 1이 필요합니다."
    case .tooLarge: return "데이터 크기 제한을 초과했습니다. 기존 목록을 유지합니다."
    case .insecureURL: return "사용자 정보가 없는 HTTPS 주소를 입력해 주세요."
    case .network(let status): return "데이터 서버에 연결하지 못했습니다(\(status)). 기존 목록을 유지합니다."
    case .hashMismatch: return "파일 크기 또는 SHA-256 검증에 실패했습니다. 기존 목록을 유지합니다."
    case .olderVersion: return "현재 목록보다 오래된 버전입니다. 기존 목록을 유지합니다."
    }
  }
}

enum CatalogValidation {
  static let schemaVersion = 1
  static let maximumPackBytes = 20 * 1024 * 1024
  static let maximumCollectionBytes = 60 * 1024 * 1024
  static let maximumPlaces = 250_000

  static func httpsURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https",
      url.host?.isEmpty == false, url.user == nil, url.password == nil,
      url.fragment == nil else { throw CatalogError.insecureURL }
    return url
  }

  static func decode(_ data: Data) throws -> CatalogPack {
    guard data.count <= maximumCollectionBytes else { throw CatalogError.tooLarge }
    let pack = try JSONDecoder().decode(CatalogPack.self, from: data)
    try validate(pack)
    return pack
  }

  static func validate(_ pack: CatalogPack) throws {
    guard pack.schemaVersion == schemaVersion else { throw CatalogError.unsupportedSchema }
    guard pack.version > 0, !pack.generatedAt.isEmpty,
      pack.places.count <= maximumPlaces else { throw CatalogError.invalid("버전 또는 장소 수 오류") }
    var ids = Set<String>()
    var validatedCaptureDates = Set<String>()
    for place in pack.places {
      guard !place.id.isEmpty, place.id.count <= 200, ids.insert(place.id).inserted,
        !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        place.name.count <= 500, place.address.count <= 1000,
        !place.regionCode.isEmpty, !place.regionName.isEmpty,
        place.regionCode.count <= 100, place.regionName.count <= 200,
        place.equipment.count <= 1000, place.facilityTypes.count <= 100,
        place.facilityTypes.allSatisfy({ $0.count <= 500 }),
        place.equipment.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 500
          && ($0.count.map { (0...100_000).contains($0) } ?? true) }),
        place.equipmentCount.map({ (0...1_000_000).contains($0) }) ?? true,
        !place.provenance.provider.isEmpty, !place.provenance.datasetTitle.isEmpty,
        !place.provenance.sourceRecordID.isEmpty, !place.provenance.capturedAt.isEmpty,
        !place.provenance.license.isEmpty else { throw CatalogError.invalid("누락·중복 또는 유효하지 않은 장소 정보") }
      if let sourceID = place.sourceID {
        guard !sourceID.isEmpty, sourceID.count <= 200,
          !place.isNationalEquipment || sourceID == NationalEquipment.sourceID else {
          throw CatalogError.invalid("장소의 출처 식별자 오류")
        }
      }
      _ = try httpsURL(place.provenance.sourceURL)
      if place.isNationalEquipment, validatedCaptureDates.insert(place.provenance.capturedAt).inserted {
        guard CatalogMerge.captureDate(place.provenance.capturedAt) != nil else {
          throw CatalogError.invalid("전국 장소의 수집 시각 형식 오류")
        }
      }
      let bothMissing = place.latitude == nil && place.longitude == nil
      if let evidence = place.coordinateEvidence {
        _ = try httpsURL(evidence.sourceURL)
        guard !bothMissing, !evidence.method.isEmpty, evidence.method.count <= 500,
          !evidence.matchedAddress.isEmpty, evidence.matchedAddress == place.address,
          evidence.matchedName.map({ $0 == place.name }) ?? true,
          CatalogMerge.captureDate(evidence.capturedAt) != nil,
          place.coordinateConflict != true else {
          throw CatalogError.invalid("좌표 보완 근거 또는 일치 주소 오류")
        }
      }
      if place.coordinateQuality == .address, place.coordinateEvidence == nil {
        throw CatalogError.invalid("주소 추정 좌표에는 출처·방법·수집일·일치 주소가 필요합니다")
      }
      if place.coordinateConflict == true, !bothMissing {
        throw CatalogError.invalid("충돌한 원좌표를 확정 위치로 표시할 수 없습니다")
      }
      if bothMissing {
        guard place.coordinateQuality == .unknown else { throw CatalogError.invalid("좌표 없는 장소의 품질 표시 오류") }
      } else {
        guard place.coordinate != nil else { throw CatalogError.invalid("위경도 범위 또는 좌표 품질 오류") }
      }
    }
    guard (pack.sources?.count ?? 0) <= 100 else {
      throw CatalogError.invalid("출처 수가 허용 범위를 초과합니다")
    }
    var sourceIDs = Set<String>()
    for source in pack.sources ?? [] {
      guard !source.id.isEmpty, sourceIDs.insert(source.id).inserted,
        !source.capturedAt.isEmpty, (0...maximumPlaces).contains(source.rowCount),
        (0...maximumPlaces).contains(source.placeCount),
        (0...source.placeCount).contains(source.missingCoordinateCount),
        source.regions.count <= 1000, source.regions.allSatisfy({ !$0.isEmpty && $0.count <= 200 })
      else { throw CatalogError.invalid("출처별 수집 정보 오류") }
      for timestamp in [source.completeCapturedAt, source.partialCapturedAt].compactMap({ $0 })
        where validatedCaptureDates.insert(timestamp).inserted {
        guard CatalogMerge.captureDate(timestamp) != nil else {
          throw CatalogError.invalid("출처별 수집 시각 형식 오류")
        }
      }
      if source.id == NationalEquipment.sourceID {
        if validatedCaptureDates.insert(source.capturedAt).inserted {
          guard CatalogMerge.captureDate(source.capturedAt) != nil else {
            throw CatalogError.invalid("전국 자료의 수집 시각 형식 오류")
          }
        }
        let matching = pack.places.filter(\.isNationalEquipment)
        guard source.rowCount > 0, source.placeCount > 0,
          matching.count == source.placeCount,
          matching.filter({ $0.coordinate == nil }).count == source.missingCoordinateCount,
          Set(matching.map(\.regionName)) == Set(source.regions)
        else { throw CatalogError.invalid("전국 자료의 장소 수·지역 집계 불일치") }
      }
    }
    if pack.places.contains(where: \.isNationalEquipment), !sourceIDs.contains(NationalEquipment.sourceID) {
      throw CatalogError.invalid("전국 자료의 출처별 수집 정보가 없습니다")
    }
    let regionalPlaces = Dictionary(grouping: pack.places.filter { !$0.isNationalEquipment && $0.sourceID != nil },
      by: { $0.sourceID! })
    for (sourceID, places) in regionalPlaces {
      guard let source = pack.sources?.first(where: { $0.id == sourceID }),
        source.placeCount == places.count,
        source.missingCoordinateCount == places.filter({ $0.coordinate == nil }).count,
        Set(source.regions) == Set(places.map(\.regionName)) else {
        throw CatalogError.invalid("지역 자료의 출처별 장소 수·지역 집계 불일치")
      }
    }
    for source in pack.sources ?? [] where source.requiresPlaceSourceID == true
      && source.id != NationalEquipment.sourceID && regionalPlaces[source.id] == nil {
      guard source.placeCount == 0, source.missingCoordinateCount == 0, source.regions.isEmpty else {
        throw CatalogError.invalid("지역 자료의 출처별 장소 수·지역 집계 불일치")
      }
    }
  }

  static func validate(_ manifest: CatalogManifest) throws {
    guard manifest.schemaVersion == schemaVersion else { throw CatalogError.unsupportedSchema }
    guard manifest.version > 0, !manifest.generatedAt.isEmpty,
      !manifest.packs.isEmpty, manifest.packs.count <= 100 else { throw CatalogError.invalid("manifest 구성 오류") }
    var byteTotal = 0
    var placeTotal = 0
    var urls = Set<URL>()
    for item in manifest.packs {
      let url = try httpsURL(item.url)
      guard urls.insert(url).inserted, (1...maximumPackBytes).contains(item.byteCount),
        (0...maximumPlaces).contains(item.placeCount), item.sha256.count == 64,
        item.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit })
      else { throw CatalogError.invalid("pack 크기·해시·주소 오류") }
      byteTotal += item.byteCount
      placeTotal += item.placeCount
    }
    guard byteTotal <= maximumCollectionBytes, placeTotal <= maximumPlaces else { throw CatalogError.tooLarge }
  }
}
