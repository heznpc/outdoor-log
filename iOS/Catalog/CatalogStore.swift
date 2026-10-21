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
  private(set) var updateProgress = ""
  private(set) var errorMessage: String?
  private(set) var favoriteIDs = Set<String>()
  private(set) var manifestURL: String
  private(set) var regions: [(code: String, name: String)] = []
  private(set) var equipmentKinds: [String] = []
  private(set) var recordPlaceChoices: [PlaceChoice] = []
  private(set) var nationalSummary: CatalogSourceSummary?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let directory: URL?
  @ObservationIgnored private let bundledURL: URL?
  @ObservationIgnored private var currentPack: CatalogPack?
  @ObservationIgnored private var placeIDs = Set<String>()

  init(defaults: UserDefaults = .standard, directory: URL? = nil,
    bundledURL: URL? = Bundle.main.url(forResource: "catalog", withExtension: "json"),
    loadImmediately: Bool = true) {
    self.defaults = defaults
    self.directory = directory ?? (try? ProtectedFile.directory().appendingPathComponent("Catalog", isDirectory: true))
    self.bundledURL = bundledURL
    manifestURL = defaults.string(forKey: "catalog.manifestURL") ?? ""
    favoriteIDs = Set(defaults.stringArray(forKey: "catalog.favoriteIDs") ?? [])
    if loadImmediately { load() }
  }

  var hasNationalCatalog: Bool { nationalSummary != nil }
  var unavailableFavoriteIDs: [String] { favoriteIDs.subtracting(placeIDs).sorted() }
  func isFavorite(_ place: EquipmentPlace) -> Bool { favoriteIDs.contains(place.id) }
  func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }
  func toggleFavorite(_ place: EquipmentPlace) { toggleFavorite(place.id) }
  func toggleFavorite(_ id: String) {
    if favoriteIDs.contains(id) { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }
    defaults.set(Array(favoriteIDs).sorted(), forKey: "catalog.favoriteIDs")
  }

  // Synchronous entry retained for small fixtures and explicit local reloads.
  // App startup uses loadIfNeeded so national JSON decoding is off MainActor.
  func load() {
    guard !isRefreshing else { return }
    acceptLoaded(Self.readSnapshot(directory: directory, bundledURL: bundledURL))
  }

  func loadIfNeeded() async {
    guard currentPack == nil, !isRefreshing else { return }
    isRefreshing = true
    updateProgress = "저장된 장소 목록을 읽는 중"
    defer { isRefreshing = false; updateProgress = "" }
    let directory = directory, bundledURL = bundledURL
    let result = await Task.detached(priority: .userInitiated) {
      Self.readSnapshot(directory: directory, bundledURL: bundledURL)
    }.value
    acceptLoaded(result)
  }

  private func acceptLoaded(_ result: LoadedSnapshot) {
    if let pack = result.pack { apply(pack) }
    status = result.status
    errorMessage = result.error
  }

  nonisolated private static func readSnapshot(directory: URL?, bundledURL: URL?) -> LoadedSnapshot {
    let bundled = bundledURL.flatMap { try? CatalogValidation.decode(readBounded($0)) }
    var failedLocalRead = false
    for (url, label) in [
      (directory?.appendingPathComponent("current.json"), "저장된 목록"),
      (directory?.appendingPathComponent("last-good.json"), "이전 정상 목록")
    ] {
      guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
      do {
        let cached = try CatalogValidation.decode(readBounded(url))
        let pack: CatalogPack
        do {
          pack = try bundled.map { try CatalogMerge.adoptingBundledNational($0, into: cached) } ?? cached
        } catch {
          let previousWarning = failedLocalRead ? "저장된 파일을 읽지 못해 이전 정상 목록을 선택했습니다. " : ""
          return LoadedSnapshot(pack: cached, status: "\(label) · \(cached.places.count)곳",
            error: previousWarning + "앱에 포함된 새 자료를 합치지 못해 저장된 목록을 유지합니다. 원본은 유지했습니다. " + error.localizedDescription)
        }
        return LoadedSnapshot(pack: pack, status: "\(label) · \(pack.places.count)곳",
          error: failedLocalRead ? "저장된 파일을 읽지 못해 이전 정상 목록을 표시합니다. 원본은 유지했습니다." : nil)
      } catch { failedLocalRead = true }
    }
    if let bundled {
      return LoadedSnapshot(pack: bundled, status: "앱에 포함된 공개 데이터 · \(bundled.places.count)곳",
        error: failedLocalRead ? "저장된 파일을 읽지 못해 앱에 포함된 목록을 표시합니다. 원본은 유지했습니다." : nil)
    }
    return LoadedSnapshot(pack: nil, status: "",
      error: "사용 가능한 장소 목록이 없습니다. 데이터 설정에서 전국 자료를 갱신하거나 JSON을 가져오세요.")
  }

  func configureManifest(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { _ = try CatalogValidation.httpsURL(trimmed) }
    manifestURL = trimmed
    defaults.set(trimmed, forKey: "catalog.manifestURL")
  }

  func reload() async {
    if manifestURL.isEmpty { await refreshNational() } else { await refresh() }
  }

  func clearError() { errorMessage = nil }

  func refreshNational() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    errorMessage = nil
    updateProgress = "공공데이터 수집 범위를 확인하는 중"
    defer { isRefreshing = false; updateProgress = "" }
    do {
      let incoming = try await NationalCatalogDownload.fetch { [weak self] progress in
        await MainActor.run { self?.updateProgress = progress }
      }
      let existing = currentPack
      let result = try await Task.detached(priority: .utility) {
        try CatalogMerge.national(incoming, into: existing, replace: true)
      }.value
      try Task.checkCancellation()
      try await install(result)
      status = "전국 공개 기구 자료 갱신 · \(nationalSummary?.rowCount ?? 0)행을 \(nationalSummary?.placeCount ?? 0)개 장소 항목으로 정리"
    } catch is CancellationError {
      status = "갱신을 취소했습니다. 기존 목록을 유지합니다."
    } catch { errorMessage = error.localizedDescription }
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    errorMessage = nil
    updateProgress = "공개 카탈로그를 내려받는 중"
    defer { isRefreshing = false; updateProgress = "" }
    do {
      let url = try CatalogValidation.httpsURL(manifestURL)
      let minimumVersion = version
      let result = try await Self.fetchManifest(url, minimumVersion: minimumVersion)
      try Task.checkCancellation()
      try await install(result)
      status = "카탈로그 갱신 완료 · \(places.count)곳"
    } catch is CancellationError {
      status = "갱신을 취소했습니다. 기존 목록을 유지합니다."
    } catch { errorMessage = error.localizedDescription }
  }

  nonisolated private static func fetchManifest(_ url: URL, minimumVersion: Int) async throws -> CatalogPack {
    let bytes = try await CatalogDownload.fetch(url, limit: 512 * 1024)
    let manifest = try JSONDecoder().decode(CatalogManifest.self, from: bytes)
    try CatalogValidation.validate(manifest)
    guard manifest.version >= minimumVersion else { throw CatalogError.olderVersion }
    var packs: [CatalogPack] = []
    for item in manifest.packs {
      try Task.checkCancellation()
      let data = try await CatalogDownload.fetch(try CatalogValidation.httpsURL(item.url), limit: item.byteCount)
      guard data.count == item.byteCount, sha256(data) == item.sha256.lowercased() else { throw CatalogError.hashMismatch }
      let pack = try CatalogValidation.decode(data)
      guard pack.version == manifest.version, pack.places.count == item.placeCount else {
        throw CatalogError.invalid("manifest와 파일의 버전·장소 수가 다릅니다")
      }
      packs.append(pack)
    }
    return try CatalogMerge.manifest(packs, version: manifest.version, generatedAt: manifest.generatedAt)
  }

  func importJSON(from url: URL) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    errorMessage = nil
    updateProgress = "파일의 출처와 장소 정보를 확인하는 중"
    defer { isRefreshing = false; updateProgress = "" }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let existing = currentPack
      let minimumVersion = version
      let prepared = try await Task.detached(priority: .utility) {
        let data = try Self.readBounded(url)
        let root = try JSONSerialization.jsonObject(with: data)
        if let object = root as? [String: Any], object["schemaVersion"] != nil {
          let pack = try CatalogValidation.decode(data)
          guard pack.version >= minimumVersion else { throw CatalogError.olderVersion }
          return (pack, false)
        }
        let incoming = try NationalEquipment.normalize(data,
          capturedAt: ISO8601DateFormatter().string(from: Date()))
        return (try CatalogMerge.national(incoming, into: existing, replace: false), true)
      }.value
      try Task.checkCancellation()
      try await install(prepared.0)
      status = prepared.1
        ? "포털 파일의 장소를 추가·갱신했습니다. 파일에 없는 기존 장소는 유지합니다."
        : "카탈로그 가져오기 완료 · \(places.count)곳"
    } catch is CancellationError {
      status = "가져오기를 취소했습니다. 기존 목록을 유지합니다."
    } catch { errorMessage = error.localizedDescription }
  }

  func restoreBundledSnapshot() async {
    guard !isRefreshing, let bundledURL else { return }
    isRefreshing = true
    errorMessage = nil
    defer { isRefreshing = false }
    do {
      let pack = try await Task.detached(priority: .utility) {
        try CatalogValidation.decode(Self.readBounded(bundledURL))
      }.value
      try Task.checkCancellation()
      try await install(pack)
      status = "앱에 포함된 목록으로 복원했습니다. 즐겨찾기와 운동 기록은 유지합니다."
    } catch { errorMessage = error.localizedDescription }
  }

  private func install(_ pack: CatalogPack) async throws {
    guard let directory else { throw LocalDataError.storageUnavailable }
    let previous = currentPack
    let task = Task.detached(priority: .utility) {
      try CatalogValidation.validate(pack)
      try Task.checkCancellation()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if let previous { try ProtectedFile.write(previous, to: directory.appendingPathComponent("last-good.json")) }
      try Task.checkCancellation()
      try ProtectedFile.write(pack, to: directory.appendingPathComponent("current.json"))
    }
    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    // Once the atomic write succeeds, memory must match disk, even if the
    // caller is cancelled at the end of the write.
    apply(pack)
  }

  private func apply(_ pack: CatalogPack) {
    currentPack = pack
    version = pack.version
    generatedAt = pack.generatedAt
    places = pack.places
    placeIDs = Set(places.map(\.id))
    regions = Dictionary(grouping: places, by: \.regionCode).compactMap { key, values in
      values.first.map { (code: key, name: $0.regionName) }
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    equipmentKinds = Set(places.flatMap(\.equipmentKinds)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    recordPlaceChoices = places.map { PlaceChoice(id: $0.id, name: $0.name, detail: $0.regionName + " · " + $0.address) }
    nationalSummary = pack.sources?.first { $0.id == NationalEquipment.sourceID }
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

private struct LoadedSnapshot: Sendable {
  var pack: CatalogPack?
  var status: String
  var error: String?
}
