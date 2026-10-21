import Foundation
import CoreLocation

struct CatalogSearchQuery: Hashable, Sendable {
  var revision: Int
  var text: String
  var region: String
  var equipmentKind: String
  var favoritesOnly: Bool
  var favorites: Set<String>
  var latitude: Double?
  var longitude: Double?
}

enum CatalogSearch {
  static func results(in places: [EquipmentPlace], query: CatalogSearchQuery) -> [EquipmentPlace] {
    let origin: CLLocation?
    if let latitude = query.latitude, let longitude = query.longitude {
      origin = CLLocation(latitude: latitude, longitude: longitude)
    } else { origin = nil }
    // Compute each distance once, instead of once per sort comparison.
    let candidates = places.filter { place in
      (query.region.isEmpty || place.regionCode == query.region)
        && (query.equipmentKind.isEmpty || place.equipmentKinds.contains(query.equipmentKind))
        && (!query.favoritesOnly || query.favorites.contains(place.id))
        && place.matches(query.text)
    }.map { (place: $0, distance: $0.distance(from: origin) ?? .greatestFiniteMagnitude) }
    return candidates.sorted { first, second in
      if origin != nil, first.distance != second.distance { return first.distance < second.distance }
      let comparison = first.place.name.localizedStandardCompare(second.place.name)
      return comparison == .orderedSame ? first.place.id < second.place.id : comparison == .orderedAscending
    }.map(\.place)
  }
}
