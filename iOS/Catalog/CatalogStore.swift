import Foundation
import Observation
import CryptoKit

@MainActor @Observable
final class CatalogStore {
  private(set) var places: [EquipmentPlace] = []
  private(set) var version = 0
  private(set) var generatedAt = ""
  private(set) var revision = 0
  private(set) var isRefreshing = false
  private(set) var status = ""
  private(set) var errorMessage: String?
  private(set) var favoriteIDs = Set<String>()
  private(set) var manifestURL: String
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let directory: URL?
  @ObservationIgnored private let bundledURL: URL?
  @ObservationIgnored private var currentPack: CatalogPack?

  init(defaults: UserDefaults = .standard, directory: URL? = nil,
    bundledURL: URL? = Bundle.main.url(forResource: "catalog", withExtension: "json")) {
    self.defaults = defaults
    self.directory = directory ?? (try? ProtectedFile.directory().appendingPathComponent("Catalog", isDirectory: true))
    self.bundledURL = bundledURL
    manifestURL = defaults.string(forKey: "catalog.manifestURL") ?? ""
    favoriteIDs = Set(defaults.stringArray(forKey: "catalog.favoriteIDs") ?? [])
    load()
  }

  var regions: [(code: String, name: String)] {
    Dictionary(grouping: places, by: \.regionCode).compactMap { key, values in
      values.first.map { (code: key, name: $0.regionName) }
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var equipmentKinds: [String] {
    Set(places.flatMap(\.equipmentKinds)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  var placeChoices: [(id: String, name: String)] { places.map { (id: $0.id, name: $0.name) } }

  func isFavorite(_ place: EquipmentPlace) -> Bool { favoriteIDs.contains(place.id) }
  func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }

  func toggleFavorite(_ place: EquipmentPlace) { toggleFavorite(place.id) }
  func toggleFavorite(_ id: String) {
    if favoriteIDs.contains(id) { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }
    defaults.set(Array(favoriteIDs).sorted(), forKey: "catalog.favoriteIDs")
  }

  /// Disk first, then last verified disk copy, then the packaged public snapshot.
  /// Failed reads never overwrite any source file.
  func load() {
    guard !isRefreshing else { return }
    var failedLocalRead = false
    let candidates: [(URL?, String)] = [
      (directory?.appendingPathComponent("current.json"), "저장된 목록"),
      (directory?.appendingPathComponent("last-good.json"), "이전 정상 목록"),
      (bundledURL, "앱에 포함된 공개 데이터")
    ]
    for (url, description) in candidates {
      guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
      do {
        let data = try Self.readBounded(url)
        let pack = try CatalogValidation.decode(data)
        apply(pack)
        status = "\(description) · \(pack.places.count)곳"
        errorMessage = failedLocalRead ? "저장된 파일을 읽지 못해 사용 가능한 정상 목록을 표시합니다. 원본은 유지했습니다." : nil
        return
      } catch { failedLocalRead = true }
    }
    errorMessage = "사용 가능한 장소 목록을 읽지 못했습니다. 데이터 설정에서 JSON을 가져오거나 다시 불러와 주세요."
  }

  func configureManifest(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { _ = try CatalogValidation.httpsURL(trimmed) }
    manifestURL = trimmed
    defaults.set(trimmed, forKey: "catalog.manifestURL")
  }

  func reload() async {
    if manifestURL.isEmpty { load() } else { await refresh() }
  }

  func clearError() { errorMessage = nil }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    errorMessage = nil
    defer { isRefreshing = false }
    do {
      let url = try CatalogValidation.httpsURL(manifestURL)
      let bytes = try await CatalogDownload.fetch(url, limit: 512 * 1024)
      let manifest = try JSONDecoder().decode(CatalogManifest.self, from: bytes)
      try CatalogValidation.validate(manifest)
      guard manifest.version >= version else { throw CatalogError.olderVersion }
      var imported: [EquipmentPlace] = []
      for item in manifest.packs {
        try Task.checkCancellation()
        let data = try await CatalogDownload.fetch(try CatalogValidation.httpsURL(item.url), limit: item.byteCount)
        guard data.count == item.byteCount,
          Self.sha256(data) == item.sha256.lowercased() else { throw CatalogError.hashMismatch }
        let pack = try await Task.detached(priority: .utility) { try CatalogValidation.decode(data) }.value
        guard pack.version == manifest.version, pack.places.count == item.placeCount else {
          throw CatalogError.invalid("manifest와 pack의 버전 또는 장소 수가 다릅니다")
        }
        imported.append(contentsOf: pack.places)
      }
      let result = CatalogPack(schemaVersion: manifest.schemaVersion, version: manifest.version,
        generatedAt: manifest.generatedAt, places: imported)
      try CatalogValidation.validate(result)
      try Task.checkCancellation()
      try install(result)
      status = "데이터 갱신 완료 · \(places.count)곳"
    } catch is CancellationError {
      status = "갱신을 취소했습니다. 기존 목록을 유지합니다."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func importJSON(from url: URL) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    errorMessage = nil
    defer { isRefreshing = false }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let pack = try await Task.detached(priority: .utility) {
        try CatalogValidation.decode(Self.readBounded(url))
      }.value
      guard pack.version >= version else { throw CatalogError.olderVersion }
      try Task.checkCancellation()
      try install(pack)
      status = "가져오기 완료 · \(places.count)곳"
    } catch is CancellationError {
      status = "가져오기를 취소했습니다. 기존 목록을 유지합니다."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func restoreBundledSnapshot() {
    guard !isRefreshing, let bundledURL else { return }
    do {
      let pack = try CatalogValidation.decode(Self.readBounded(bundledURL))
      try install(pack)
      status = "앱에 포함된 목록으로 복원했습니다. 즐겨찾기는 유지합니다."
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func install(_ pack: CatalogPack) throws {
    guard let directory else { throw LocalDataError.storageUnavailable }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let currentPack {
      try ProtectedFile.write(currentPack, to: directory.appendingPathComponent("last-good.json"))
    }
    try ProtectedFile.write(pack, to: directory.appendingPathComponent("current.json"))
    apply(pack)
  }

  private func apply(_ pack: CatalogPack) {
    currentPack = pack
    version = pack.version
    generatedAt = pack.generatedAt
    places = pack.places
    revision += 1
  }

  nonisolated static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated private static func readBounded(_ url: URL) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber,
      size.int64Value <= Int64(CatalogValidation.maximumCollectionBytes) else { throw CatalogError.tooLarge }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= CatalogValidation.maximumCollectionBytes else { throw CatalogError.tooLarge }
    return data
  }
}

private final class HTTPSRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    let allowed = request.url.flatMap { try? CatalogValidation.httpsURL($0.absoluteString) } != nil
    completionHandler(allowed ? request : nil)
  }
}

private enum CatalogDownload {
  static func fetch(_ url: URL, limit: Int) async throws -> Data {
    _ = try CatalogValidation.httpsURL(url.absoluteString)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration, delegate: HTTPSRedirectPolicy(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw CatalogError.network(0) }
    guard (200...299).contains(response.statusCode) else { throw CatalogError.network(response.statusCode) }
    guard response.expectedContentLength <= Int64(limit) else { throw CatalogError.tooLarge }
    var data = Data()
    for try await byte in bytes {
      if data.count >= limit { throw CatalogError.tooLarge }
      data.append(byte)
      if data.count % 65_536 == 0 { try Task.checkCancellation() }
    }
    return data
  }
}
