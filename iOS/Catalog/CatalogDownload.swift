import Foundation
import CoreFoundation
import Security

private final class HTTPSRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let requiredHost: String?
  let allowsRedirects: Bool
  init(requiredHost: String?, allowsRedirects: Bool) {
    self.requiredHost = requiredHost
    self.allowsRedirects = allowsRedirects
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    let url = request.url.flatMap { try? CatalogValidation.httpsURL($0.absoluteString) }
    let allowed = allowsRedirects && url != nil && (requiredHost == nil || url?.host?.lowercased() == requiredHost)
    completionHandler(allowed ? request : nil)
  }
}

enum CatalogDownload {
  static func fetch(_ url: URL, limit: Int, requiredHost: String? = nil,
    allowsRedirects: Bool = true) async throws -> Data {
    _ = try CatalogValidation.httpsURL(url.absoluteString)
    if let requiredHost, url.host?.lowercased() != requiredHost { throw CatalogError.insecureURL }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration,
      delegate: HTTPSRedirectPolicy(requiredHost: requiredHost, allowsRedirects: allowsRedirects), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw CatalogError.network(0) }
    guard (200...299).contains(response.statusCode) else { throw CatalogError.network(response.statusCode) }
    guard response.expectedContentLength <= Int64(limit) else { throw CatalogError.tooLarge }
    // The portal serves JSON with text/html. Validate the body, not that MIME.
    var data = Data()
    for try await byte in bytes {
      if data.count >= limit { throw CatalogError.tooLarge }
      data.append(byte)
      if data.count % 65_536 == 0 { try Task.checkCancellation() }
    }
    try Task.checkCancellation()
    return data
  }
}

/// The key never enters UserDefaults, catalog files, progress, or server error text.
protocol CatalogServiceKeyStorage: Sendable {
  func load() throws -> String?
  func save(_ value: String) throws
  func delete() throws
}

struct CatalogServiceKeychain: CatalogServiceKeyStorage {
  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "OutdoorLog") + ".national-catalog",
     kSecAttrAccount as String: "data-go-kr-service-key",
     kSecAttrSynchronizable as String: false]
  }

  func load() throws -> String? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
      let key = String(data: data, encoding: .utf8) else { throw failure }
    return key
  }

  func save(_ value: String) throws {
    let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      let insert = query.merging(attributes) { _, new in new }
      guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw failure }
    } else if status != errSecSuccess { throw failure }
  }

  func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw failure }
  }

  private var failure: CatalogError {
    .invalid("API 인증키의 안전한 저장소에 접근하지 못했습니다. 기기 잠금을 해제하고 다시 시도하세요")
  }
}

enum OfficialNationalCatalogDownload {
  // Primary specification: https://www.data.go.kr/data/15139207/standard.do
  static let endpoint = "https://api.data.go.kr/openapi/tn_pubr_public_outdoor_exercise_eqmt_api"
  static let pageSize = 1_000
  struct Page {
    var totalCount: Int
    var rows: [[String: Any]]
  }

  static func normalizedServiceKey(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = trimmed.removingPercentEncoding ?? trimmed
    guard !key.isEmpty, key.count <= 4096, !key.contains(where: \.isWhitespace),
      !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw CatalogError.invalid("공공데이터포털에서 발급한 API 인증키를 입력하세요")
    }
    return key
  }

  static func pageURL(_ page: Int, serviceKey: String) throws -> URL {
    guard page > 0 else { throw CatalogError.invalid("공식 API 페이지 번호 오류") }
    var parts = URLComponents(string: endpoint)!
    parts.queryItems = [URLQueryItem(name: "serviceKey", value: try normalizedServiceKey(serviceKey)),
      URLQueryItem(name: "pageNo", value: String(page)), URLQueryItem(name: "numOfRows", value: String(pageSize)),
      URLQueryItem(name: "type", value: "json")]
    // URLComponents otherwise leaves '+' literal; form-query servers may read it as a space.
    parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let url = parts.url else { throw CatalogError.invalid("공식 API 요청 구성 오류") }
    return url
  }

  static func decodePage(_ data: Data, requestedPage: Int, expectedTotal: Int? = nil) throws -> Page {
    guard data.count <= CatalogValidation.maximumPackBytes else { throw CatalogError.tooLarge }
    guard requestedPage > 0 else { throw CatalogError.invalid("공식 API 페이지 번호 오류") }
    // Gateway errors may be XML, and resultMsg can reflect the service key.
    // Never propagate either body or a failing request URL into user-visible errors.
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let response = root["response"] as? [String: Any],
      let header = response["header"] as? [String: Any],
      let code = header["resultCode"] as? String else {
      throw CatalogError.invalid("공식 API가 JSON 응답을 반환하지 않았습니다. 인증키와 서비스 이용 승인을 확인하세요")
    }
    guard code == "00" else {
      let reason = ["20", "21", "30", "31", "32", "33"].contains(code)
        ? "공식 API 인증키 또는 서비스 이용 승인을 확인하세요"
        : (code == "22" ? "공식 API 요청 한도를 초과했습니다. 잠시 후 다시 시도하세요" : "공식 API가 정상 상태를 반환하지 않았습니다")
      throw CatalogError.invalid(reason)
    }
    guard let body = response["body"] as? [String: Any],
      let total = integer(body["totalCount"]), (1...CatalogValidation.maximumPlaces).contains(total),
      integer(body["pageNo"]) == requestedPage, integer(body["numOfRows"]) == pageSize,
      expectedTotal == nil || expectedTotal == total else {
      throw CatalogError.invalid("공식 API의 페이지·전체 행 수가 일치하지 않습니다. 기존 목록을 유지합니다")
    }
    let items = body["items"]
    let nestedItem = (items as? [String: Any])?["item"]
    let rows = items as? [[String: Any]] ?? nestedItem as? [[String: Any]]
      ?? (nestedItem as? [String: Any]).map { [$0] }
    guard let rows, requestedPage <= (total + pageSize - 1) / pageSize,
      rows.count == min(pageSize, total - (requestedPage - 1) * pageSize) else {
      throw CatalogError.invalid("공식 API에 누락된 페이지 또는 행이 있습니다")
    }
    return Page(totalCount: total, rows: rows)
  }

  private static func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
      guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
        number.doubleValue >= 0, number.doubleValue <= Double(CatalogValidation.maximumPlaces),
        number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
      return number.intValue
    }
    guard let string = value as? String, !string.isEmpty,
      string.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return Int(string)
  }

  static func fetch(serviceKey: String, progress: @escaping @Sendable (String) async -> Void) async throws -> CatalogPack {
    do {
      var rows: [[String: Any]] = []
      var fingerprints = Set<String>()
      var total: Int?
      var byteCount = 0
      var pageNumber = 1
      var firstFingerprint: String?
      var lastFingerprint: String?
      repeat {
        try Task.checkCancellation()
        await progress("공식 API 내려받는 중 · \(pageNumber)페이지")
        let data = try await CatalogDownload.fetch(pageURL(pageNumber, serviceKey: serviceKey),
          limit: CatalogValidation.maximumPackBytes, requiredHost: "api.data.go.kr", allowsRedirects: false)
        byteCount += data.count
        guard byteCount <= CatalogValidation.maximumCollectionBytes else { throw CatalogError.tooLarge }
        let page = try decodePage(data, requestedPage: pageNumber, expectedTotal: total)
        total = page.totalCount
        let fingerprint = try NationalCatalogDownload.pageFingerprint(page.rows)
        guard fingerprints.insert(fingerprint).inserted else { throw CatalogError.invalid("공식 API에서 같은 페이지가 반복되었습니다") }
        if firstFingerprint == nil { firstFingerprint = fingerprint }
        lastFingerprint = fingerprint
        rows.append(contentsOf: page.rows)
        pageNumber += 1
      } while rows.count < (total ?? 0)
      guard rows.count == total else {
        throw CatalogError.invalid("수집 중 공식 API 원본이 변경됐습니다. 잠시 후 다시 시도하세요")
      }
      // Recheck both boundaries, once for a one-page result. The service has no
      // snapshot token: this detects movement, but cannot prove an atomic snapshot.
      let lastPage = pageNumber - 1
      for boundary in (lastPage == 1 ? [1] : [1, lastPage]) {
        let checkData = try await CatalogDownload.fetch(pageURL(boundary, serviceKey: serviceKey),
          limit: CatalogValidation.maximumPackBytes, requiredHost: "api.data.go.kr", allowsRedirects: false)
        byteCount += checkData.count
        guard byteCount <= CatalogValidation.maximumCollectionBytes else { throw CatalogError.tooLarge }
        let check = try decodePage(checkData, requestedPage: boundary, expectedTotal: total)
        let expected = boundary == 1 ? firstFingerprint : lastFingerprint
        guard try NationalCatalogDownload.pageFingerprint(check.rows) == expected else {
          throw CatalogError.invalid("수집 중 공식 API 원본이 변경됐습니다. 잠시 후 다시 시도하세요")
        }
      }
      try Task.checkCancellation()
      return try NationalEquipment.normalizeOfficialRows(rows,
        capturedAt: ISO8601DateFormatter().string(from: Date()))
    } catch is CancellationError { throw CancellationError() }
    catch let error as CatalogError { throw error }
    catch {
      if Task.isCancelled { throw CancellationError() }
      throw CatalogError.invalid("공식 API 연결 또는 응답 검증에 실패했습니다. 인증키와 네트워크를 확인하세요")
    }
  }
}

enum NationalCatalogDownload {
  struct Header: Decodable, Equatable, Sendable {
    struct Table: Decodable, Equatable, Sendable {
      var colNmList: [String]
      var svcTableNm: String
    }
    var totalCount: Int
    var tableVO: Table

    func validate() throws {
      // The website's documented grid export ceiling is 50,000. Do not
      // silently turn a capped export into a supposedly complete snapshot.
      guard (1..<50_000).contains(totalCount) else {
        throw CatalogError.invalid("공개 다운로드 상한(50,000행)에 도달했거나 자료가 비어 있습니다. 정식 API로 수집한 카탈로그가 필요합니다")
      }
      let required = ["INSTL_PLC_NM", "CTPV_NM", "SGG_NM", "LCTN_ROAD_NM_ADDR",
        "LCTN_LOTNO_ADDR", "LAT", "LOT", "SPRTGD_NM", "SPRTGD_QTY", "DATA_CRTR_YMD"]
      guard tableVO.svcTableNm == "tn_pubr_public_outdoor_exercise_eqmt_svc",
        tableVO.colNmList.count <= 100,
        Set(required).isSubset(of: Set(tableVO.colNmList)) else {
        throw CatalogError.invalid("공공데이터 다운로드 형식이 변경됐습니다. 포털 JSON 파일을 직접 가져올 수 있습니다")
      }
    }
  }

  static let headerURL = URL(string: "https://www.data.go.kr/download/columList.json?pk=15139207&ext=JSON")!

  static func pageURL(_ page: Int, header: Header) throws -> URL {
    try header.validate()
    var parts = URLComponents(string: "https://www.data.go.kr/download/standard.json")!
    parts.queryItems = [URLQueryItem(name: "publicDataPk", value: "15139207")]
      + header.tableVO.colNmList.map { URLQueryItem(name: "colNmList", value: $0) }
      + [URLQueryItem(name: "totalCount", value: String(header.totalCount)),
         URLQueryItem(name: "svcTableNm", value: header.tableVO.svcTableNm),
         URLQueryItem(name: "perPage", value: "10000"), URLQueryItem(name: "page", value: String(page))]
    guard let url = parts.url else { throw CatalogError.invalid("공공데이터 요청 주소 오류") }
    return url
  }

  static func fetch(progress: @escaping @Sendable (String) async -> Void) async throws -> CatalogPack {
    let header = try await readHeader()
    let pageSize = 10_000
    let pageCount = (header.totalCount + pageSize - 1) / pageSize
    var rows: [[String: Any]] = []
    var hashes = Set<String>()
    var byteCount = 0
    for page in 1...pageCount {
      try Task.checkCancellation()
      await progress("공공데이터 내려받는 중 · \(page)/\(pageCount)페이지")
      let data = try await CatalogDownload.fetch(pageURL(page, header: header),
        limit: CatalogValidation.maximumPackBytes, requiredHost: "www.data.go.kr")
      byteCount += data.count
      guard byteCount <= CatalogValidation.maximumCollectionBytes else { throw CatalogError.tooLarge }
      guard let batch = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        batch.count == min(pageSize, header.totalCount - (page - 1) * pageSize) else {
        throw CatalogError.invalid("일부 페이지가 누락되거나 반복되었습니다. 기존 전국 목록을 유지합니다")
      }
      guard hashes.insert(try pageFingerprint(batch)).inserted else {
        throw CatalogError.invalid("같은 페이지가 반복되었습니다. 기존 전국 목록을 유지합니다")
      }
      rows.append(contentsOf: batch)
    }
    // A changed header during pagination cannot certify a complete download.
    guard try await readHeader() == header, rows.count == header.totalCount else {
      throw CatalogError.invalid("수집 중 원본 구성이 변경됐습니다. 잠시 후 다시 시도하세요")
    }
    await progress("전국 자료의 장소·좌표·출처를 확인하는 중")
    try Task.checkCancellation()
    return try NationalEquipment.normalize(JSONSerialization.data(withJSONObject: rows),
      capturedAt: ISO8601DateFormatter().string(from: Date()))
  }

  private static func readHeader() async throws -> Header {
    let data = try await CatalogDownload.fetch(headerURL, limit: 512 * 1024, requiredHost: "www.data.go.kr")
    let header = try JSONDecoder().decode(Header.self, from: data)
    try header.validate()
    return header
  }

  static func pageFingerprint(_ rows: [[String: Any]]) throws -> String {
    // Ignore row/key ordering but retain repeated rows: the source itself can
    // contain duplicates, while a repeated page must never replace the catalog.
    let hashes = try rows.map { row in
      CatalogStore.sha256(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
    }.sorted()
    return CatalogStore.sha256(Data(hashes.joined(separator: "\n").utf8))
  }
}
