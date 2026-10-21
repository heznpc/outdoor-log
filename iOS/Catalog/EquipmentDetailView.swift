import SwiftUI
import MapKit

@MainActor struct EquipmentDetailView: View {
  let place: EquipmentPlace
  let store: CatalogStore
  let onRecord: (String, String) -> Void

  var body: some View {
    List {
      Section {
        Text(place.name).font(.title2.bold()).textSelection(.enabled)
        Text(place.address.isEmpty ? "주소 미제공" : place.address).textSelection(.enabled)
        Label(place.regionName + (place.locality.map { " · \($0)" } ?? ""), systemImage: "map")
        Label(place.coverageTitle, systemImage: place.isParkReference ? "tree" : "dumbbell")
          .font(.subheadline).foregroundStyle(.secondary)
        if place.isParkReference {
          Text("공원 자료를 참고한 장소입니다. 운동기구 설치 여부는 확인되지 않았습니다.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Button { onRecord(place.id, place.name) } label: {
          Label("이 장소에서 운동 기록", systemImage: "plus.circle.fill")
        }.buttonStyle(.borderedProminent).padding(.vertical, 6)
        Button { store.toggleFavorite(place) } label: {
          Label(store.isFavorite(place) ? "즐겨찾기 해제" : "즐겨찾기에 추가",
            systemImage: store.isFavorite(place) ? "star.fill" : "star")
        }
      }
      Section("위치와 길찾기") {
        if let coordinate = place.coordinate {
          Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)))) {
            Marker(place.name, coordinate: coordinate)
          }.frame(height: 220).accessibilityLabel("\(place.name)의 \(place.coordinateQuality.title)")
        }
        Text(place.coordinateQuality.title).font(.headline)
        Text(place.coordinateQuality.explanation).font(.subheadline).foregroundStyle(.secondary)
        if let coordinate = place.coordinate {
          Text("위도 \(coordinate.latitude.formatted(.number.precision(.fractionLength(6)))), 경도 \(coordinate.longitude.formatted(.number.precision(.fractionLength(6))))")
            .font(.caption).textSelection(.enabled)
          Button {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            item.name = place.name
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
          } label: { Label("Apple 지도에서 도보 길찾기", systemImage: "arrow.triangle.turn.up.right.diamond") }
        } else if let url = addressSearchURL {
          Link(destination: url) { Label("Apple 지도에서 주소 검색", systemImage: "magnifyingglass") }
        }
      }
      Section("운동기구") {
        if let total = place.equipmentCount { LabeledContent("공개된 기구 총수량", value: "\(total)개") }
        if place.isNationalEquipment {
          Text("기구명은 제공기관의 원문입니다. 여러 기구가 묶여 있는 이름의 수량을 기구별 개수로 나눌 수는 없습니다. 중복 여부가 불분명한 자료는 총수량을 합산하지 않습니다.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        if place.equipmentInformationKnown {
          ForEach(Array(place.equipment.enumerated()), id: \.offset) { _, item in
            LabeledContent(item.name, value: item.count.map { "\($0)개" } ?? "수량 미확인")
          }
          if place.equipment.isEmpty { Text("제공된 기구 목록이 없습니다.").foregroundStyle(.secondary) }
        } else {
          Text("개별 운동기구의 종류와 기구별 수량을 확인할 수 없습니다.")
          if place.isParkReference {
            Text("공원 시설 항목에 야외체력단련시설이 표시되어도 개별 기구나 현재 이용 가능 여부는 확인되지 않았습니다.")
              .font(.subheadline).foregroundStyle(.secondary)
          } else {
            Text("원자료의 시설 정보만으로 개별 기구 목록을 추정하지 않습니다.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
        }
        if !place.facilityTypes.isEmpty {
          LabeledContent("원자료 시설 분류", value: place.facilityTypes.joined(separator: " · "))
        }
        Text("고장·철거·교체, 운영시간, 이용요금, 무장애 접근 정보는 미확인입니다. 현장 안내를 확인하세요.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Section("공개 데이터 출처") {
        LabeledContent("제공기관", value: place.provenance.provider)
        LabeledContent("데이터", value: place.provenance.datasetTitle)
        LabeledContent("자료 기준일", value: place.provenance.referenceDate ?? "미제공")
        LabeledContent("수집 시점", value: place.provenance.capturedAt)
        if let department = place.managingDepartment { LabeledContent("담당부서", value: department) }
        LabeledContent("원자료 식별자", value: place.provenance.sourceRecordID)
        Text(place.provenance.license).font(.footnote)
        if let note = place.provenance.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        if let url = try? CatalogValidation.httpsURL(place.provenance.sourceURL) {
          Link("제공기관의 원자료 보기", destination: url)
        }
      }
    }
    .navigationTitle("시설 상세")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var addressSearchURL: URL? {
    guard !place.address.isEmpty else { return nil }
    var url = URLComponents(string: "https://maps.apple.com/")
    url?.queryItems = [URLQueryItem(name: "q", value: place.name + " " + place.address)]
    return url?.url
  }
}
