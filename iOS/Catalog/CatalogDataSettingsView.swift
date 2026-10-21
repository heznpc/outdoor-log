import SwiftUI
import UniformTypeIdentifiers

@MainActor struct CatalogDataSettingsView: View {
  let store: CatalogStore
  @Environment(\.dismiss) private var dismiss
  @State private var manifest = ""
  @State private var importPresented = false
  @State private var restorePresented = false
  @State private var formError: String?

  var body: some View {
    Form {
      Section("현재 데이터") {
        LabeledContent("장소", value: "\(store.places.count)곳")
        LabeledContent("버전", value: "\(store.version)")
        LabeledContent("생성 시점", value: store.generatedAt)
        Text(store.status).font(.footnote)
        ForEach(store.regions, id: \.code) { region in
          LabeledContent(region.name, value: "\(store.places.filter { $0.regionCode == region.code }.count)곳")
        }
        Text("현재 등록 지역만 검색할 수 있습니다. 출처와 기준일이 있는 다른 지역 데이터도 같은 형식으로 가져올 수 있습니다.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Section {
        TextField("https://…/manifest.json", text: $manifest, axis: .vertical)
          .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
          .accessibilityLabel("데이터 manifest HTTPS 주소")
        Button("주소 저장") {
          do { try store.configureManifest(manifest); formError = nil }
          catch { formError = error.localizedDescription }
        }.disabled(store.isRefreshing)
        Button {
          do {
            try store.configureManifest(manifest)
            formError = nil
            Task { await store.refresh() }
          } catch { formError = error.localizedDescription }
        } label: { Label("저장하고 데이터 갱신", systemImage: "arrow.clockwise") }
        .disabled(store.isRefreshing || manifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      } header: { Text("선택 사항 · 데이터 서버") }
      footer: {
        Text("기본 서버는 설정되어 있지 않습니다. 신뢰하는 공개 데이터 제공자의 manifest 주소를 입력하세요. 수동 갱신 시 해당 서버에 접속하며 위치·즐겨찾기·운동 기록은 전송하지 않습니다. 주소를 비워 저장하면 연결을 해제합니다.")
      }
      Section {
        Button { importPresented = true } label: { Label("카탈로그 JSON 가져오기", systemImage: "square.and.arrow.down") }
          .disabled(store.isRefreshing)
        Button("앱에 포함된 목록으로 복원") { restorePresented = true }.disabled(store.isRefreshing)
      } header: { Text("파일로 관리") }
      footer: {
        Text("가져오기는 전체 카탈로그를 교체합니다. 즐겨찾기와 운동 기록은 유지되지만 새 파일에 없는 장소는 검색에 나타나지 않습니다. 제공자가 준비한 카탈로그 JSON 파일을 선택하세요. 지원 형식·버전·출처·좌표를 확인한 뒤 저장하며 실패하면 기존 목록을 유지합니다.")
      }
      if store.isRefreshing {
        Section { ProgressView("데이터 검증 및 저장 중") }
      }
      if let error = formError ?? store.errorMessage {
        Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
      }
    }
    .navigationTitle("장소 데이터")
    .scrollDismissesKeyboard(.interactively)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
    .onAppear { manifest = store.manifestURL }
    .fileImporter(isPresented: $importPresented, allowedContentTypes: [.json]) { result in
      switch result {
      case .success(let url): Task { await store.importJSON(from: url) }
      case .failure(let error): formError = error.localizedDescription
      }
    }
    .confirmationDialog("가져온 목록을 앱에 포함된 공개 데이터로 교체할까요?", isPresented: $restorePresented, titleVisibility: .visible) {
      Button("기본 목록으로 복원") { store.restoreBundledSnapshot() }
      Button("취소", role: .cancel) {}
    }
  }
}
