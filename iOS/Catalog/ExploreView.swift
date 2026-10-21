import SwiftUI
import MapKit

@MainActor struct ExploreView: View {
  let store: CatalogStore
  let onRecord: (String, String) -> Void
  @State private var location = CatalogLocation()
  @State private var query = ""
  @State private var region = ""
  @State private var equipmentKind = ""
  @State private var favoritesOnly = false
  @State private var includeParkReferences = false
  @State private var viewMode = 0
  @State private var sortByDistance = true
  @State private var sheet: ExploreSheet?
  @State private var pendingRecord: (id: String, name: String)?
  @State private var camera: MapCameraPosition = .automatic
  @State private var results: [EquipmentPlace] = []
  @State private var isSearching = true
  private let pinLimit = 100

  private enum ExploreSheet: Identifiable {
    case data, equipment, place(EquipmentPlace)
    var id: String {
      switch self {
      case .data: return "data"
      case .equipment: return "equipment-filter"
      case .place(let place): return place.id
      }
    }
  }

  private var searchQuery: CatalogSearchQuery {
    let origin = sortByDistance ? location.usableLocation : nil
    return CatalogSearchQuery(revision: store.revision, text: query, region: region,
      equipmentKind: equipmentKind, favoritesOnly: favoritesOnly, favorites: store.favoriteIDs,
      latitude: origin?.coordinate.latitude, longitude: origin?.coordinate.longitude,
      includeParkReferences: includeParkReferences)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        controls
        if favoritesOnly, !store.unavailableFavoriteIDs.isEmpty {
          Text("현재 자료에 없는 즐겨찾기 \(store.unavailableFavoriteIDs.count)곳 · 보존됨")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8)
        }
        if let error = store.errorMessage {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle")
            Text(error).font(.footnote)
            Spacer(minLength: 0)
            Button("닫기") { store.clearError() }.font(.footnote)
          }
          .padding().background(.yellow.opacity(0.12))
        }
        if store.isRefreshing && store.places.isEmpty {
          ProgressView(store.updateProgress.isEmpty ? "장소 목록 불러오는 중" : store.updateProgress)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.places.isEmpty {
          ContentUnavailableView {
            Label("장소 목록이 없습니다", systemImage: "map")
          } description: {
            Text("데이터 설정에서 전국 공개 자료를 받거나 공개 데이터 파일을 가져오세요.")
          } actions: {
            Button("다시 불러오기") { Task { await store.reload() } }
            Button("데이터 설정") { sheet = .data }
          }
        } else if isSearching && results.isEmpty {
          ProgressView("장소 검색 중").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
          ContentUnavailableView {
            Label("검색 결과가 없습니다", systemImage: "magnifyingglass")
          } description: {
            Text(favoritesOnly ? "즐겨찾기에 추가한 장소와 검색 조건을 확인하세요. 현재 목록에 없는 장소는 나타나지 않을 수 있습니다." : "지역·기구·검색어를 바꿔보세요. 포함 지역은 공개 자료에 따라 다릅니다. 데이터 설정에서 갱신 현황을 확인할 수 있습니다.")
          } actions: {
            Button("검색 조건 초기화") {
              query = ""; region = ""; equipmentKind = ""; favoritesOnly = false; includeParkReferences = false
            }
            Button("데이터 설정") { sheet = .data }
          }
        } else if viewMode == 0 {
          placesList(results)
        } else {
          placesMap(results)
        }
      }
      .navigationTitle("운동시설 찾기")
      .searchable(text: $query, prompt: "기구 종류, 시설명, 주소")
      .task(id: searchQuery) {
        let request = searchQuery
        let snapshot = store.places
        isSearching = true
        do {
          try await Task.sleep(for: .milliseconds(180))
          let search = Task.detached(priority: .userInitiated) {
            CatalogSearch.results(in: snapshot, query: request)
          }
          let found = await withTaskCancellationHandler {
            await search.value
          } onCancel: {
            search.cancel()
          }
          try Task.checkCancellation()
          guard request == searchQuery else { return }
          results = found
          isSearching = false
        } catch { /* A newer query owns the loading state. */ }
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { sheet = .data } label: { Label("데이터 설정", systemImage: "externaldrive") }
        }
      }
      .navigationDestination(for: String.self) { id in
        if let place = store.places.first(where: { $0.id == id }) {
          EquipmentDetailView(place: place, store: store, onRecord: onRecord)
        } else {
          ContentUnavailableView("목록에서 찾을 수 없는 장소입니다", systemImage: "mappin.slash",
            description: Text("목록 갱신으로 장소가 변경됐을 수 있습니다. 검색 화면으로 돌아가 주세요."))
        }
      }
      .sheet(item: $sheet, onDismiss: {
        if let pending = pendingRecord {
          pendingRecord = nil
          onRecord(pending.id, pending.name)
        }
      }) { item in
        NavigationStack {
          switch item {
          case .data: CatalogDataSettingsView(store: store)
          case .equipment: EquipmentKindPicker(store: store, selection: $equipmentKind)
          case .place(let place):
            EquipmentDetailView(place: place, store: store) { id, name in
              pendingRecord = (id: id, name: name)
              sheet = nil
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { sheet = nil } } }
          }
        }
      }
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          Menu {
            Picker("지역", selection: $region) {
              Text("모든 등록 지역").tag("")
              ForEach(store.regions, id: \.code) { item in Text(item.name).tag(item.code) }
            }
          } label: {
            Label(region.isEmpty ? "모든 지역" : store.regions.first(where: { $0.code == region })?.name ?? "선택 지역",
              systemImage: "map")
          }
          Button { sheet = .equipment } label: {
            Label(equipmentKind.isEmpty ? "기구 종류" : equipmentKind, systemImage: "dumbbell")
              .lineLimit(1).frame(maxWidth: 240, minHeight: 44, alignment: .leading)
          }
          .accessibilityLabel("운동기구 종류 필터")
          .accessibilityValue(equipmentKind.isEmpty ? "모든 기구, 미확인 포함" : equipmentKind)
          .accessibilityHint("기구 이름을 검색해 선택합니다")
          Button { favoritesOnly.toggle() } label: {
            Label("즐겨찾기", systemImage: favoritesOnly ? "star.fill" : "star")
          }
          .accessibilityValue(favoritesOnly ? "즐겨찾기만 표시" : "전체 표시")
          Toggle(isOn: Binding(get: { includeParkReferences || favoritesOnly }, set: { includeParkReferences = $0 })) {
            Label("공원 참조 포함", systemImage: "tree")
          }
          .toggleStyle(.button)
          .disabled(favoritesOnly)
          .accessibilityHint("개별 운동기구가 확인되지 않은 공원 자료를 함께 표시합니다. 즐겨찾기에서는 공원도 항상 포함합니다.")
          Menu {
            Picker("정렬", selection: $sortByDistance) {
              Text("가까운 순 · 위치 필요").tag(true)
              Text("이름순").tag(false)
            }
          } label: { Label(sortByDistance && location.usableLocation != nil ? "가까운 순" : "이름순", systemImage: "arrow.up.arrow.down") }
        }.buttonStyle(.bordered).controlSize(.large)
      }
      HStack(alignment: .top) {
        Button { location.requestFromUser() } label: {
          Label(location.isRequesting ? "확인 중" : "내 위치", systemImage: "location")
        }
        .buttonStyle(.bordered).controlSize(.large).disabled(location.isRequesting)
        VStack(alignment: .leading, spacing: 4) {
          Text(location.message).font(.caption).foregroundStyle(.secondary)
          if location.permissionDenied, let url = URL(string: UIApplication.openSettingsURLString) {
            Link("설정에서 위치 권한 변경", destination: url).font(.caption)
          }
        }
      }
      HStack {
        Text("\(results.count)곳").font(.subheadline.weight(.semibold)).accessibilityLabel("검색 결과 \(results.count)곳")
        if isSearching { ProgressView().controlSize(.small).accessibilityLabel("검색 결과 갱신 중") }
        Spacer()
        Picker("보기 방식", selection: $viewMode) {
          Text("목록").tag(0)
          Text("지도").tag(1)
        }.pickerStyle(.segmented).frame(maxWidth: 200)
      }
    }.padding(.horizontal).padding(.vertical, 10)
  }

  private func placesList(_ places: [EquipmentPlace]) -> some View {
    List {
      Section {
        ForEach(places) { place in
          NavigationLink(value: place.id) {
            CatalogPlaceRow(place: place, favorite: store.isFavorite(place),
              distance: place.distance(from: location.usableLocation))
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { store.toggleFavorite(place) } label: {
              Label(store.isFavorite(place) ? "즐겨찾기 해제" : "즐겨찾기", systemImage: "star")
            }.tint(.orange)
          }
        }
      } footer: {
        Text("공개 자료에 등록된 장소만 표시하며 모든 지역·시설을 포함하지는 않습니다. 공원 참조는 운동기구 설치를 뜻하지 않습니다. 기구의 현재 상태·이용 가능 여부는 미확인이고, 거리는 대표 좌표까지의 직선거리입니다.")
      }
    }.listStyle(.plain)
      .refreshable { await store.reload() }
  }

  private func placesMap(_ places: [EquipmentPlace]) -> some View {
    let coordinatePlaces = places.filter { $0.coordinate != nil }
    let displayed = Array(coordinatePlaces.prefix(pinLimit))
    return VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("검색 \(places.count)곳 중 지도 \(displayed.count)곳 · 좌표 없음 \(places.count - coordinatePlaces.count)곳")
          .font(.caption.weight(.medium))
        if coordinatePlaces.count > pinLimit {
          Text("현재 정렬의 앞 \(pinLimit)곳을 표시합니다. 지역·기구·검색어로 범위를 좁히거나 목록에서 전체 결과를 확인하세요.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if displayed.contains(where: \.isParkReference) {
          Text("공원 참조의 좌표는 운동기구 위치나 설치 여부를 뜻하지 않습니다.").font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8)
      if displayed.isEmpty {
        ContentUnavailableView("표시할 좌표가 없습니다", systemImage: "mappin.slash",
          description: Text("목록에서 주소와 제공 정보를 확인하세요."))
      } else {
        Map(position: $camera) {
          ForEach(displayed) { place in
            if let coordinate = place.coordinate {
              Annotation(place.name, coordinate: coordinate) {
                Button { sheet = .place(place) } label: {
                  Image(systemName: place.coordinateQuality == .park ? "tree.fill" : "figure.strengthtraining.traditional")
                    .font(.title3).padding(12).foregroundStyle(.white)
                    .background(place.coordinateQuality == .park ? Color.gray : Color.accentColor, in: Circle())
                }
                .accessibilityLabel("\(place.name), \(place.coordinateQuality.title), 상세 보기")
              }
            }
          }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .onChange(of: displayed.map(\.id)) { _, _ in camera = .automatic }
      }
    }
  }
}

@MainActor private struct EquipmentKindPicker: View {
  let store: CatalogStore
  @Binding var selection: String
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var results: [String] = []
  @State private var totalMatches = 0
  @State private var completedRequest: SearchRequest?
  private let resultLimit = 60

  private struct SearchRequest: Equatable, Sendable {
    let text: String
    let revision: Int
  }

  private var searchRequest: SearchRequest {
    SearchRequest(text: query.trimmingCharacters(in: .whitespacesAndNewlines), revision: store.revision)
  }

  var body: some View {
    List {
      Section("현재 선택") {
        Text(selection.isEmpty ? "모든 기구 · 미확인 포함" : selection)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("현재 선택: \(selection.isEmpty ? "모든 기구, 미확인 포함" : selection)")
        if !selection.isEmpty {
          if !store.equipmentKinds.contains(selection) {
            Text("현재 자료에 없는 기구 조건도 유지됩니다. 다른 기구를 선택하거나 필터를 해제할 수 있습니다.")
              .font(.footnote).foregroundStyle(.secondary)
          }
          Button("기구 필터 해제") { selection = ""; dismiss() }
            .frame(minHeight: 44)
            .accessibilityHint("모든 기구와 기구가 미확인인 장소를 포함합니다")
        }
      }
      Section {
        if completedRequest != searchRequest {
          ProgressView("기구 검색 중")
        } else if store.isRefreshing && store.equipmentKinds.isEmpty {
          ProgressView("기구 목록 불러오는 중")
        } else if results.isEmpty {
          if store.equipmentKinds.isEmpty {
            Text("등록된 기구 종류가 없습니다.").foregroundStyle(.secondary)
          } else {
            ContentUnavailableView.search(text: query)
          }
        } else {
          ForEach(results, id: \.self) { kind in
            Button {
              selection = kind
              dismiss()
            } label: {
              HStack(alignment: .top) {
                Text(kind).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if kind == selection { Image(systemName: "checkmark").accessibilityHidden(true) }
              }
              .frame(minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
            }
            .accessibilityLabel(kind)
            .accessibilityValue(kind == selection ? "현재 선택" : "")
            .accessibilityHint("이 기구로 장소 목록을 필터링합니다")
          }
        }
      } header: {
        Text("기구 종류 검색")
      } footer: {
        if completedRequest == searchRequest {
          if totalMatches > resultLimit {
            Text("검색 결과 \(totalMatches)개 중 앞 \(resultLimit)개입니다. 기구 이름을 더 입력해 범위를 좁혀주세요.")
          } else {
            Text("검색 결과 \(totalMatches)개")
          }
        }
      }
    }
    .navigationTitle("기구 종류 선택")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $query, prompt: "기구 이름 검색")
    .scrollDismissesKeyboard(.interactively)
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
    .task(id: searchRequest) {
      let request = searchRequest
      let snapshot = store.equipmentKinds
      let limit = resultLimit
      do {
        if !request.text.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
        let search = Task.detached(priority: .userInitiated) { () -> (kinds: [String], count: Int) in
          let terms = request.text.split(whereSeparator: \.isWhitespace).map(String.init)
          if terms.isEmpty { return (Array(snapshot.prefix(limit)), snapshot.count) }
          var found: [String] = []
          var count = 0
          for kind in snapshot {
            if Task.isCancelled { return ([], 0) }
            if terms.allSatisfy({ kind.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
              count += 1
              if found.count < limit { found.append(kind) }
            }
          }
          return (found, count)
        }
        let found = await withTaskCancellationHandler {
          await search.value
        } onCancel: {
          search.cancel()
        }
        try Task.checkCancellation()
        guard request == searchRequest else { return }
        results = found.kinds
        totalMatches = found.count
        completedRequest = request
      } catch { /* Only the current query and catalog revision publish results. */ }
    }
  }
}

private struct CatalogPlaceRow: View {
  let place: EquipmentPlace
  let favorite: Bool
  let distance: CLLocationDistance?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(place.name).font(.headline).fixedSize(horizontal: false, vertical: true)
        if favorite { Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityLabel("즐겨찾기") }
      }
      Text(place.address.isEmpty ? "주소 미제공" : place.address).font(.subheadline).foregroundStyle(.secondary)
      Text(place.equipmentSummary).font(.subheadline)
      Text(place.coverageTitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
      HStack {
        Text(place.coordinateQuality.title)
        if let distance { Text(distance < 1000 ? "약 \(Int(distance.rounded()))m" : "약 \((distance / 1000).formatted(.number.precision(.fractionLength(1))))km") }
      }.font(.caption).foregroundStyle(.secondary)
    }.padding(.vertical, 6)
  }
}
