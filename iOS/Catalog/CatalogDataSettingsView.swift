import SwiftUI
import UniformTypeIdentifiers

@MainActor struct CatalogDataSettingsView: View {
  let store: CatalogStore
  @Environment(\.dismiss) private var dismiss
  @State private var manifest = ""
  @State private var importPresented = false
  @State private var restorePresented = false
  @State private var formError: String?
  @State private var serviceKey = ""

  var body: some View {
    Form {
      Section {
        Text(store.refreshSourceTitle).font(.subheadline)
        Button {
          formError = nil
          Task { await store.reload() }
        } label: { Label("장소 목록 새로고침", systemImage: "arrow.clockwise") }
        .disabled(store.isRefreshing)
        if !store.status.isEmpty { Text(store.status).font(.footnote) }
      } header: { Text("공개 장소 자료 갱신") }
      footer: {
        Text("개인 인증키 없이 사용할 수 있습니다. 새 자료의 검증과 저장에 실패하면 기존 목록을 유지합니다. 위치·즐겨찾기·운동 기록은 전송하지 않습니다.")
      }
      Section {
        DisclosureGroup("공식 API 직접 연결") {
        LabeledContent("인증키", value: store.hasOfficialAPIKey ? "이 기기에 안전하게 저장됨" : "미설정")
        SecureField("공공데이터포털 API 인증키", text: $serviceKey)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityLabel("공공데이터포털 API 인증키 입력")
        Button(store.hasOfficialAPIKey ? "인증키 교체" : "인증키 저장") {
          do { try store.configureOfficialAPIKey(serviceKey); serviceKey = ""; formError = nil }
          catch { formError = error.localizedDescription }
        }.disabled(store.isRefreshing || serviceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if store.hasOfficialAPIKey {
          Button("저장된 인증키 삭제", role: .destructive) {
            do { try store.removeOfficialAPIKey(); serviceKey = ""; formError = nil }
            catch { formError = error.localizedDescription }
          }.disabled(store.isRefreshing)
        }
        Button {
          formError = nil
          Task { await store.refreshNational() }
        } label: {
          Label("공식 API로 전국 자료 받기", systemImage: "arrow.down.circle")
        }
        .disabled(store.isRefreshing || !store.hasOfficialAPIKey)
        Text("직접 API에 연결하려는 경우에만 활용 승인을 받은 인증키를 입력하세요. 인코딩·디코딩 키를 모두 지원하며 이 기기의 Keychain에 저장합니다.")
          .font(.footnote).foregroundStyle(.secondary)
        }
        DisclosureGroup("포털 원본 파일 직접 받기") {
        Button {
          formError = nil
          Task { await store.refreshNational(usePortalFallback: true) }
        } label: { Label("키 없이 포털 공개 파일 받기", systemImage: "doc.badge.arrow.down") }
        .disabled(store.isRefreshing)
        Text("포털의 다운로드 제한이나 경로 변경으로 실패할 수 있습니다. 전체 수집을 확인할 수 없으면 기존 목록을 유지합니다.")
          .font(.footnote).foregroundStyle(.secondary)
        }
      } header: { Text("원자료 직접 연결 · 고급 옵션") }
      Section {
        if let summary = store.nationalSummary {
          LabeledContent("최근 받은 자료의 행", value: "\(summary.rowCount)건")
          LabeledContent("현재 합친 장소 항목", value: "\(summary.placeCount)개")
          LabeledContent("좌표 미확인 · 지도 제외", value: "\(summary.missingCoordinateCount)개")
          LabeledContent("최근 자료 수집", value: summary.capturedAt)
          if let complete = summary.completeCapturedAt {
            LabeledContent("등록된 전체 행 수집", value: complete)
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
        Text("전체 행 수집은 전국 모든 시설을 포함한다는 뜻이 아닙니다. 제공기관별 등록 범위와 기준일이 다릅니다. 공개 파일의 경우 5만 행 제한과 다운로드 경로 변경에 영향을 받습니다.")
      }
      Section("현재 데이터") {
        LabeledContent("장소 · 공원 참조 포함", value: "\(store.places.count)곳")
        LabeledContent("버전", value: "\(store.version)")
        LabeledContent("생성 시점", value: store.generatedAt)
        Text(store.status).font(.footnote)
        LabeledContent("주소 추정 위치", value: "\(store.places.filter { $0.coordinateQuality == .address }.count)곳")
        LabeledContent("출처를 확인해 보완한 위치", value: "\(store.places.filter { $0.coordinateEvidence != nil }.count)곳")
        if let warning = store.supplementWarning {
          Label(warning, systemImage: "exclamationmark.triangle").font(.footnote)
        }
        if !store.unavailableFavoriteIDs.isEmpty {
          Text("현재 자료에 없는 즐겨찾기 \(store.unavailableFavoriteIDs.count)곳 · 보존됨")
            .font(.footnote).foregroundStyle(.secondary)
        }
        DisclosureGroup("현재 포함 지역 \(store.regions.count)개") {
          ForEach(store.regions, id: \.code) { region in
            Text(region.name)
          }
        }
        DisclosureGroup("시도별 수록 범위와 좌표 누락") {
          ForEach(store.regionCoverage) { region in
            VStack(alignment: .leading, spacing: 4) {
              Text(region.name).font(.subheadline.weight(.semibold))
              Text(region.equipmentPlaces == 0 ? "운동기구 설치 자료 미수록" :
                "설치 장소 \(region.equipmentPlaces)곳 · 좌표 미확인 \(region.missingCoordinates)곳")
                .font(.footnote)
              if region.parkReferences > 0 {
                Text("별도 공원 참고 \(region.parkReferences)곳 · 기구 설치 미확인")
                  .font(.footnote).foregroundStyle(.secondary)
              }
            }.accessibilityElement(children: .combine)
          }
          Text("미수록은 해당 지역에 운동기구가 없다는 뜻이 아닙니다. 장소 수는 공개자료의 항목 수이며 서로 다른 출처가 같은 시설을 가리킬 수 있습니다.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Text("등록되지 않은 지역의 시설이 없다는 뜻은 아닙니다. 기구 목록이 확인되지 않은 공원 참조는 기본 검색에서 숨기며 검색 화면에서 포함할 수 있습니다. 기구명이 공개된 공원은 검색에 포함하지만 공원 대표 좌표는 개별 기구 위치를 뜻하지 않습니다. 좌표 없는 장소도 목록에 남습니다.")
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
        Text("별도 제공자가 준비한 카탈로그가 있을 때만 주소를 입력하세요. 주소를 비워 저장하면 앱의 기본 공개 자료 갱신으로 돌아갑니다. 위치·즐겨찾기·운동 기록은 전송하지 않습니다.")
      }
      Section {
        Button { importPresented = true } label: { Label("공개 자료 또는 카탈로그 JSON 가져오기", systemImage: "square.and.arrow.down") }
          .disabled(store.isRefreshing)
        Button("앱에 포함된 목록으로 복원") { restorePresented = true }.disabled(store.isRefreshing)
      } header: { Text("파일로 관리") }
      footer: {
        Text("포털 원본 JSON과 지역 보완 JSON은 기존 장소를 유지하며 추가·갱신합니다. 좌표 보완 JSON은 식별자와 주소가 일치하고 원좌표가 없는 장소에만 적용합니다. 일반 카탈로그 JSON은 목록을 교체하고 앱에 포함된 지역·좌표 보완을 다시 적용합니다. 즐겨찾기와 운동 기록은 유지되지만 교체된 목록에 없는 장소는 검색에 나타나지 않을 수 있습니다. 파일 검증에 실패하면 기존 목록을 유지합니다.")
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
    .onDisappear { serviceKey = "" }
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
