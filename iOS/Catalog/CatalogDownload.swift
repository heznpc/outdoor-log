import Foundation

private final class HTTPSRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let requiredHost: String?
  init(requiredHost: String?) { self.requiredHost = requiredHost }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    let url = request.url.flatMap { try? CatalogValidation.httpsURL($0.absoluteString) }
    let allowed = url != nil && (requiredHost == nil || url?.host?.lowercased() == requiredHost)
    completionHandler(allowed ? request : nil)
  }
}

enum CatalogDownload {
  static func fetch(_ url: URL, limit: Int, requiredHost: String? = nil) async throws -> Data {
    _ = try CatalogValidation.httpsURL(url.absoluteString)
    if let requiredHost, url.host?.lowercased() != requiredHost { throw CatalogError.insecureURL }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration,
      delegate: HTTPSRedirectPolicy(requiredHost: requiredHost), delegateQueue: nil)
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
