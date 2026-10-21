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
  var includeParkReferences = false
}

enum CatalogSearch {
  static func results(in places: [EquipmentPlace], query: CatalogSearchQuery) -> [EquipmentPlace] {
    let origin: CLLocation?
    if let latitude = query.latitude, let longitude = query.longitude {
      origin = CLLocation(latitude: latitude, longitude: longitude)
    } else { origin = nil }
    let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Compute each distance once, instead of once per sort comparison.
    var candidates: [(place: EquipmentPlace, distance: CLLocationDistance)] = []
    for place in places {
      if Task.isCancelled { return [] }
      guard query.includeParkReferences || query.favoritesOnly || !place.isParkReference,
        query.region.isEmpty || place.regionCode == query.region,
        query.equipmentKind.isEmpty || place.equipmentKinds.contains(query.equipmentKind),
        !query.favoritesOnly || query.favorites.contains(place.id),
        text.isEmpty || place.matches(text) else { continue }
      candidates.append((place, place.distance(from: origin) ?? .greatestFiniteMagnitude))
    }
    let sorted = try? candidates.sorted { first, second in
      if Task.isCancelled { throw CancellationError() }
      if origin != nil, first.distance != second.distance { return first.distance < second.distance }
      let comparison = first.place.name.localizedStandardCompare(second.place.name)
      return comparison == .orderedSame ? first.place.id < second.place.id : comparison == .orderedAscending
    }
    if Task.isCancelled { return [] }
    return sorted?.map(\.place) ?? []
  }
}
