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
      Section {
        Button {
          formError = nil
          Task { await store.refreshNational() }
        } label: {
          Label(store.hasNationalCatalog ? "전국 공공자료 다시 받기" : "전국 공공자료 받기", systemImage: "arrow.down.circle")
        }
        .disabled(store.isRefreshing)
        if let summary = store.nationalSummary {
          LabeledContent("최근 받은 자료의 행", value: "\(summary.rowCount)건")
          LabeledContent("현재 합친 장소 항목", value: "\(summary.placeCount)개")
          LabeledContent("좌표 미확인 · 지도 제외", value: "\(summary.missingCoordinateCount)개")
          LabeledContent("최근 자료 수집", value: summary.capturedAt)
          if let complete = summary.completeCapturedAt {
            LabeledContent("전체 다운로드 확인", value: complete)
          }
          if let partial = summary.partialCapturedAt {
            LabeledContent("부분 파일 반영", value: partial)
          }
          DisclosureGroup("자료에 포함된 지역 \(summary.regions.count)개") {
            Text(summary.regions.joined(separator: " · "))
              .font(.footnote).textSelection(.enabled)
          }
        } else {
          Text("전국 공공자료를 아직 받지 않았습니다. 현재 포함된 자료는 아래에서 확인할 수 있습니다.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Link("공공데이터포털에서 원자료 보기", destination: URL(string: "https://www.data.go.kr/data/15139207/standard.do")!)
      } header: { Text("전국 야외운동기구 공공자료") }
      footer: {
        Text("API 키 없이 포털 웹사이트의 공개 파일을 직접 내려받습니다. 다운로드 경로가 변경되면 갱신이 중단될 수 있으며, 이때 포털 JSON 파일을 직접 가져올 수 있습니다. 전체 다운로드는 포털에 등록된 행을 모두 받았다는 의미이며, 모든 지역·시설을 포함한다는 뜻은 아닙니다. 제공기관별 등록 범위와 기준일이 다릅니다. 좌표가 없거나 서로 다른 장소도 목록에는 남고 지도와 거리 계산에서는 제외됩니다. 갱신 요청에 위치·즐겨찾기·운동 기록을 포함하지 않습니다.")
      }
      Section("현재 데이터") {
        LabeledContent("장소 · 공원 참조 포함", value: "\(store.places.count)곳")
        LabeledContent("버전", value: "\(store.version)")
        LabeledContent("생성 시점", value: store.generatedAt)
        Text(store.status).font(.footnote)
        if !store.unavailableFavoriteIDs.isEmpty {
          Text("현재 자료에 없는 즐겨찾기 \(store.unavailableFavoriteIDs.count)곳 · 보존됨")
            .font(.footnote).foregroundStyle(.secondary)
        }
        DisclosureGroup("현재 포함 지역 \(store.regions.count)개") {
          ForEach(store.regions, id: \.code) { region in
            Text(region.name)
          }
        }
        Text("등록되지 않은 지역의 시설이 없다는 뜻은 아닙니다. 공원 참조는 기본 검색에서 숨기며, 검색 화면에서 포함할 수 있습니다. 즐겨찾기에는 공원도 표시합니다.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Section {
        DisclosureGroup("사용자 지정 카탈로그") {
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
          } label: { Label("저장하고 카탈로그 갱신", systemImage: "arrow.clockwise") }
          .disabled(store.isRefreshing || manifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      } header: { Text("고급 옵션") }
      footer: {
        Text("별도 제공자가 준비한 카탈로그가 있을 때만 manifest 주소를 입력하세요. 이 주소를 저장하면 목록의 새로고침에 사용됩니다. 주소를 비워 저장하면 전국 공공자료 갱신을 사용합니다. 위치·즐겨찾기·운동 기록은 전송하지 않습니다.")
      }
      Section {
        Button { importPresented = true } label: { Label("공개 자료 또는 카탈로그 JSON 가져오기", systemImage: "square.and.arrow.down") }
          .disabled(store.isRefreshing)
        Button("앱에 포함된 목록으로 복원") { restorePresented = true }.disabled(store.isRefreshing)
      } header: { Text("파일로 관리") }
      footer: {
        Text("포털 원본 JSON은 같은 식별자의 장소를 갱신하고 새 장소를 추가합니다. 파일에 빠진 기존 장소는 유지합니다. 카탈로그 JSON은 전체 목록을 교체합니다. 즐겨찾기와 운동 기록은 유지되지만 교체된 목록에 없는 장소는 검색에 나타나지 않을 수 있습니다. 파일 검증에 실패하면 기존 목록을 유지합니다.")
      }
      if store.isRefreshing {
        Section { ProgressView(store.updateProgress.isEmpty ? "데이터 검증 및 저장 중" : store.updateProgress) }
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
      Button("기본 목록으로 복원") { Task { await store.restoreBundledSnapshot() } }
      Button("취소", role: .cancel) {}
    }
  }
}
