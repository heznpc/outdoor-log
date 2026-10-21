import Foundation
import CoreLocation
import Observation

@MainActor @Observable
final class CatalogLocation: NSObject, CLLocationManagerDelegate {
  private(set) var location: CLLocation?
  private(set) var message = "위치를 사용하거나 지역을 직접 선택하세요."
  private(set) var isRequesting = false
  private(set) var permissionDenied = false
  private(set) var reducedAccuracy = false
  @ObservationIgnored private let manager = CLLocationManager()
  @ObservationIgnored private var timeoutTask: Task<Void, Never>?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  var usableLocation: CLLocation? {
    guard let location, abs(location.timestamp.timeIntervalSinceNow) <= 300 else { return nil }
    return location
  }

  func request() {
    guard CLLocationManager.locationServicesEnabled() else {
      message = "기기의 위치 서비스가 꺼져 있습니다. 지역을 직접 선택할 수 있습니다."
      permissionDenied = true
      return
    }
    permissionDenied = false
    switch manager.authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse:
      reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
      isRequesting = true
      message = "현재 위치를 확인하고 있습니다."
      manager.requestLocation()
      timeoutTask?.cancel()
      timeoutTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(20))
        guard !Task.isCancelled, let self, self.isRequesting else { return }
        self.manager.stopUpdatingLocation()
        self.isRequesting = false
        self.message = "위치 확인 시간이 초과됐습니다. 다시 시도하거나 지역을 선택하세요."
      }
    case .denied, .restricted:
      location = nil
      permissionDenied = true
      isRequesting = false
      message = "위치 접근이 허용되지 않았습니다. 지역을 직접 선택할 수 있습니다."
    @unknown default:
      message = "위치를 사용할 수 없습니다. 지역을 직접 선택하세요."
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
      // This callback may occur on initialization. Only request a fix after user consent.
      reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
    } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
      location = nil
      permissionDenied = true
      message = "위치 접근이 허용되지 않았습니다. 지역을 직접 선택할 수 있습니다."
    }
    if awaitingPermission, manager.authorizationStatus != .notDetermined {
      awaitingPermission = false
      request()
    }
  }

  @ObservationIgnored private var awaitingPermission = false

  func requestFromUser() {
    awaitingPermission = manager.authorizationStatus == .notDetermined
    request()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    timeoutTask?.cancel()
    isRequesting = false
    guard let best = locations.filter({ $0.horizontalAccuracy >= 0
      && abs($0.timestamp.timeIntervalSinceNow) <= 120
      && CLLocationCoordinate2DIsValid($0.coordinate) })
      .min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) else {
      message = "새 위치를 확인하지 못했습니다. 다시 시도하거나 지역을 선택하세요."
      return
    }
    location = best
    let accuracy = best.horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))
    message = "\(reducedAccuracy ? "대략적인 위치" : "현재 위치") · 오차 약 \(accuracy)m. 거리는 직선거리입니다."
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    timeoutTask?.cancel()
    isRequesting = false
    message = "위치를 확인하지 못했습니다. 다시 시도하거나 지역을 선택하세요."
  }
}
