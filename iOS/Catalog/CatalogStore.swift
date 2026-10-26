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
  private(set) var hasOfficialAPIKey = false
  private(set) var supplementWarning: String?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let directory: URL?
  @ObservationIgnored private let bundledURL: URL?
  @ObservationIgnored private let regionalURL: URL?
  @ObservationIgnored private let coordinateSupplementURL: URL?
  @ObservationIgnored private let serviceKeyStorage: any CatalogServiceKeyStorage
  @ObservationIgnored private var currentPack: CatalogPack?
  @ObservationIgnored private var placeIDs = Set<String>()

  init(defaults: UserDefaults = .standard, directory: URL? = nil,
    bundledURL: URL? = Bundle.main.url(forResource: "catalog", withExtension: "json"),
    regionalURL: URL? = nil, coordinateSupplementURL: URL? = nil,
    serviceKeyStorage: any CatalogServiceKeyStorage = CatalogServiceKeychain(),
    loadImmediately: Bool = true) {
    self.defaults = defaults
    self.directory = directory ?? (try? ProtectedFile.directory().appendingPathComponent("Catalog", isDirectory: true))
    self.bundledURL = bundledURL
    self.regionalURL = regionalURL ?? bundledURL?.deletingLastPathComponent().appendingPathComponent("regional-equipment.json")
    self.coordinateSupplementURL = coordinateSupplementURL ?? bundledURL?.deletingLastPathComponent().appendingPathComponent("coordinate-supplements.json")
    self.serviceKeyStorage = serviceKeyStorage
    manifestURL = defaults.string(forKey: "catalog.manifestURL") ?? ""
    favoriteIDs = Set(defaults.stringArray(forKey: "catalog.favoriteIDs") ?? [])
    hasOfficialAPIKey = (try? serviceKeyStorage.load()) != nil
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
    acceptLoaded(Self.readSnapshot(directory: directory, bundledURL: bundledURL,
      regionalURL: regionalURL, coordinateSupplementURL: coordinateSupplementURL))
  }

  func loadIfNeeded() async {
    guard currentPack == nil, !isRefreshing else { return }
    isRefreshing = true
    updateProgress = "저장된 장소 목록을 읽는 중"
    defer { isRefreshing = false; updateProgress = "" }
    let directory = directory, bundledURL = bundledURL
    let regionalURL = regionalURL, coordinateSupplementURL = coordinateSupplementURL
    let result = await Task.detached(priority: .userInitiated) {
      Self.readSnapshot(directory: directory, bundledURL: bundledURL,
        regionalURL: regionalURL, coordinateSupplementURL: coordinateSupplementURL)
    }.value
    acceptLoaded(result)
  }

  private func acceptLoaded(_ result: LoadedSnapshot) {
    if let pack = result.pack { apply(pack) }
    status = result.status
    errorMessage = result.error
    supplementWarning = result.supplementWarning
  }

  nonisolated private static func readSnapshot(directory: URL?, bundledURL: URL?,
    regionalURL: URL?, coordinateSupplementURL: URL?) -> LoadedSnapshot {
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
          return withSupplements(LoadedSnapshot(pack: cached, status: "\(label) · \(cached.places.count)곳",
            error: previousWarning + "앱에 포함된 새 자료를 합치지 못해 저장된 목록을 유지합니다. 원본은 유지했습니다. " + error.localizedDescription),
            regionalURL: regionalURL, coordinateSupplementURL: coordinateSupplementURL)
        }
        return withSupplements(LoadedSnapshot(pack: pack, status: "\(label) · \(pack.places.count)곳",
          error: failedLocalRead ? "저장된 파일을 읽지 못해 이전 정상 목록을 표시합니다. 원본은 유지했습니다." : nil),
          regionalURL: regionalURL, coordinateSupplementURL: coordinateSupplementURL)
      } catch { failedLocalRead = true }
    }
    if let bundled {
      return withSupplements(LoadedSnapshot(pack: bundled, status: "앱에 포함된 공개 데이터 · \(bundled.places.count)곳",
        error: failedLocalRead ? "저장된 파일을 읽지 못해 앱에 포함된 목록을 표시합니다. 원본은 유지했습니다." : nil),
        regionalURL: regionalURL, coordinateSupplementURL: coordinateSupplementURL)
    }
    return LoadedSnapshot(pack: nil, status: "",
      error: "사용 가능한 장소 목록이 없습니다. 데이터 설정에서 전국 자료를 갱신하거나 JSON을 가져오세요.")
  }

  nonisolated private static func withSupplements(_ snapshot: LoadedSnapshot,
    regionalURL: URL?, coordinateSupplementURL: URL?) -> LoadedSnapshot {
    var result = snapshot
    guard var pack = snapshot.pack else { return result }
    var warnings: [String] = []
    if let url = regionalURL, FileManager.default.fileExists(atPath: url.path) {
      do {
        let (merged, conflicts) = try CatalogMerge.regional(CatalogValidation.decode(readBounded(url)), into: pack)
        pack = merged
        if conflicts > 0 { warnings.append("식별자가 충돌한 지역 자료 \(conflicts)곳을 제외했습니다.") }
      } catch { warnings.append("지역 보완 파일을 적용하지 못해 기본 목록을 유지합니다.") }
    }
    if let url = coordinateSupplementURL, FileManager.default.fileExists(atPath: url.path) {
      do {
        let entries = try JSONDecoder().decode(CoordinateSupplementPack.self, from: readBounded(url))
        let (merged, rejected) = try CatalogMerge.coordinates(entries, into: pack)
        pack = merged
        if rejected > 0 { warnings.append("주소·시점·좌표가 맞지 않거나 중복된 좌표 보완 \(rejected)건을 제외했습니다.") }
      } catch { warnings.append("좌표 보완 파일을 적용하지 못해 기존 위치 정보를 유지합니다.") }
    }
    result.pack = pack
    result.supplementWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
    return result
  }

  func configureOfficialAPIKey(_ value: String) throws {
    let key = try OfficialNationalCatalogDownload.normalizedServiceKey(value)
    try serviceKeyStorage.save(key)
    hasOfficialAPIKey = true
  }

  func removeOfficialAPIKey() throws {
    try serviceKeyStorage.delete()
    hasOfficialAPIKey = false
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

  func refreshNational(usePortalFallback: Bool = false) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    errorMessage = nil
    updateProgress = "공공데이터 수집 범위를 확인하는 중"
    defer { isRefreshing = false; updateProgress = "" }
    do {
      let progress: @Sendable (String) async -> Void = { [weak self] progress in
        await MainActor.run { self?.updateProgress = progress }
      }
      let incoming: CatalogPack
      if usePortalFallback {
        incoming = try await NationalCatalogDownload.fetch(progress: progress)
      } else {
        guard let key = try serviceKeyStorage.load() else {
          throw CatalogError.invalid("장소 데이터 설정에서 공식 API 인증키를 저장하거나 키 없는 포털 공개 파일 받기를 선택하세요")
        }
        incoming = try await OfficialNationalCatalogDownload.fetch(serviceKey: key, progress: progress)
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
      let result = try await Self.fetchManifest(url, minimumVersion: minimumVersion,
        preservingCoordinatesFrom: currentPack)
      try Task.checkCancellation()
      try await install(result)
      status = "카탈로그 갱신 완료 · \(places.count)곳"
    } catch is CancellationError {
      status = "갱신을 취소했습니다. 기존 목록을 유지합니다."
    } catch { errorMessage = error.localizedDescription }
  }

  nonisolated private static func fetchManifest(_ url: URL, minimumVersion: Int,
    preservingCoordinatesFrom existing: CatalogPack?) async throws -> CatalogPack {
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
    return try CatalogMerge.manifest(packs, version: manifest.version, generatedAt: manifest.generatedAt,
      preservingCoordinatesFrom: existing)
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
        try Self.prepareImport(Self.readBounded(url), existing: existing, minimumVersion: minimumVersion)
      }.value
      try Task.checkCancellation()
      try await install(prepared.pack)
      status = prepared.status
    } catch is CancellationError {
      status = "가져오기를 취소했습니다. 기존 목록을 유지합니다."
    } catch { errorMessage = error.localizedDescription }
  }

  nonisolated static func prepareImport(_ data: Data, existing: CatalogPack?, minimumVersion: Int)
    throws -> (pack: CatalogPack, status: String) {
    guard data.count <= CatalogValidation.maximumCollectionBytes else { throw CatalogError.tooLarge }
    let root = try JSONSerialization.jsonObject(with: data)
    if let object = root as? [String: Any] {
      if let role = object["catalogRole"] {
        guard role as? String == "regional-supplement", object["entries"] == nil else {
          throw CatalogError.invalid("지원하지 않거나 서로 섞인 카탈로그 보완 형식입니다")
        }
        let incoming = try CatalogValidation.decode(data)
        guard let existing else { throw CatalogError.invalid("지역 보완을 적용할 기존 장소 목록이 없습니다") }
        let (merged, conflicts) = try CatalogMerge.regional(incoming, into: existing)
        return (merged, "지역 보완 가져오기 완료 · 기존 장소 유지 · 충돌 \(conflicts)건 제외")
      }
      if object["entries"] != nil {
        guard object["places"] == nil else { throw CatalogError.invalid("장소 목록과 좌표 보완을 한 파일에 섞을 수 없습니다") }
        let incoming = try JSONDecoder().decode(CoordinateSupplementPack.self, from: data)
        guard let existing else { throw CatalogError.invalid("좌표 보완을 적용할 기존 장소 목록이 없습니다") }
        let (merged, rejected) = try CatalogMerge.coordinates(incoming, into: existing)
        return (merged, "좌표 보완 가져오기 완료 · 기존 장소 유지 · 불일치 \(rejected)건 제외")
      }
      if object["schemaVersion"] != nil {
        let pack = try CatalogValidation.decode(data)
        guard pack.version >= minimumVersion else { throw CatalogError.olderVersion }
        return (pack, "카탈로그 가져오기 완료 · \(pack.places.count)곳")
      }
    }
    let incoming = try NationalEquipment.normalize(data, capturedAt: ISO8601DateFormatter().string(from: Date()))
    return (try CatalogMerge.national(incoming, into: existing, replace: false),
      "포털 파일의 장소를 추가·갱신했습니다. 파일에 없는 기존 장소는 유지합니다.")
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
    let regionalURL = regionalURL, coordinateSupplementURL = coordinateSupplementURL
    let task = Task.detached(priority: .utility) {
      try CatalogValidation.validate(pack)
      let supplemented = Self.withSupplements(LoadedSnapshot(pack: pack, status: "", error: nil),
        regionalURL: regionalURL, coordinateSupplementURL: coordinateSupplementURL)
      let installed = supplemented.pack ?? pack
      try Task.checkCancellation()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if let previous { try ProtectedFile.write(previous, to: directory.appendingPathComponent("last-good.json")) }
      try Task.checkCancellation()
      try ProtectedFile.write(installed, to: directory.appendingPathComponent("current.json"))
      return supplemented
    }
    let installed = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    // Once the atomic write succeeds, memory must match disk, even if the
    // caller is cancelled at the end of the write.
    apply(installed.pack ?? pack)
    supplementWarning = installed.supplementWarning
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
  var supplementWarning: String? = nil
}
