"""Offline fixtures only. This suite never calls a geocoding service."""
import unittest
import hashlib

from catalog_coordinates import apply_supplements, match_park_coordinates, retain_previous_entries, validate_supplements
from enrich_coordinates import parse_vworld, park_source_metadata


def place(**changes):
    value = {"id": "test-place", "name": "샘공원", "address": "부산광역시 북구 구포동 1200",
        "regionName": "부산광역시 북구", "latitude": None, "longitude": None,
        "coordinateQuality": "unknown", "provenance": {"note": "", "sourceURL": "https://example.org/source"}}
    value.update(changes)
    return value


def evidence(**changes):
    value = {"placeID": "test-place", "latitude": 35.2, "longitude": 129.0,
        "quality": "park", "sourceURL": "https://www.data.go.kr/data/15012890/standard.do",
        "method": "official-park-exact-name-and-address", "sourceRecordID": "park-1",
        "capturedAt": "2026-10-26", "matchedName": "샘공원",
        "matchedAddress": "부산광역시 북구 구포동 1200"}
    value.update(changes)
    return value


class CoordinateEvidenceTests(unittest.TestCase):
    def apply(self, locations, entries):
        return apply_supplements({"places": locations}, {"schemaVersion": 1, "entries": entries})

    def test_attributed_match_fills_only_missing_coordinates(self):
        original = place()
        result, counts = self.apply([original], [evidence()])
        self.assertEqual(counts["applied"], 1)
        self.assertIsNone(original["latitude"])
        self.assertEqual(result["places"][0]["coordinateQuality"], "park")
        self.assertEqual(result["places"][0]["coordinateEvidence"]["sourceRecordID"], "park-1")

    def test_source_coordinate_cannot_be_replaced(self):
        result, counts = self.apply([place(latitude=35.1, longitude=129.1, coordinateQuality="facility")], [evidence()])
        self.assertEqual(result["places"][0]["latitude"], 35.1)
        self.assertEqual(counts["alreadyLocated"], 1)

    def test_previous_evidence_survives_an_already_enriched_input(self):
        previous = {"schemaVersion": 1, "entries": [evidence()]}
        updated, _ = self.apply([place()], previous["entries"])
        self.assertEqual(retain_previous_entries(updated, previous), previous["entries"])
        updated["places"][0]["latitude"] += 0.01
        self.assertEqual(retain_previous_entries(updated, previous), [])

    def test_source_reference_date_invalidates_older_evidence(self):
        target = place(provenance={"referenceDate": "2026-10-27"})
        result, counts = self.apply([target], [evidence()])
        self.assertIsNone(result["places"][0]["latitude"])
        self.assertEqual(counts["olderEvidence"], 1)
        self.assertEqual(retain_previous_entries({"places": [target]},
            {"schemaVersion": 1, "entries": [evidence()]}), [])

    def test_regional_missing_count_reflects_coordinate_supplements(self):
        pack = {"places": [place(sourceID="regional:one")],
                "sources": [{"id": "regional:one", "missingCoordinateCount": 1}]}
        updated, _ = apply_supplements(pack, {"schemaVersion": 1, "entries": [evidence()]})
        self.assertEqual(updated["sources"][0]["missingCoordinateCount"], 0)

    def test_changed_address_or_name_invalidates_evidence(self):
        for changes in [{"address": "다른 주소"}, {"name": "다른 공원"}]:
            result, counts = self.apply([place(**changes)], [evidence()])
            self.assertIsNone(result["places"][0]["latitude"])
            self.assertEqual(counts["identityMismatch"], 1)

    def test_ambiguous_entries_and_source_conflicts_stay_unlocated(self):
        for entries, target in [([evidence(), evidence(latitude=35.3)], place()),
                                ([evidence()], place(coordinateConflict=True)),
                                ([evidence()], place(provenance={"note": "원본 좌표가 서로 달라 대표 좌표 미선택"}))]:
            result, _ = self.apply([target], entries)
            self.assertIsNone(result["places"][0]["latitude"])

    def test_evidence_requires_valid_https_time_quality_and_coordinates(self):
        for change in [{"sourceURL": "http://example.org"}, {"capturedAt": "invalid"},
                       {"quality": "precise"}, {"latitude": float("nan")}, {"latitude": True}]:
            with self.assertRaises(ValueError):
                validate_supplements({"schemaVersion": 1, "entries": [evidence(**change)]})

    def test_park_join_accepts_spacing_but_rejects_same_name_different_lot(self):
        row = {"PARK_NM": "샘 공원", "LNMADR": "부산광역시 북구 구포동 1200", "RDNMADR": "",
               "LATITUDE": "35.2", "LONGITUDE": "129.0", "MANAGE_NO": "park-1"}
        joined = match_park_coordinates([place(), place(id="other", address="부산광역시 북구 구포동 1201")],
                                       [row], "2026-10-26")
        self.assertEqual([entry["placeID"] for entry in joined], ["test-place"])
        self.assertEqual(joined[0]["quality"], "park")

    def test_park_join_rejects_multiple_official_identifiers(self):
        row = {"PARK_NM": "샘공원", "LNMADR": place()["address"], "LATITUDE": 35.2,
               "LONGITUDE": 129.0, "MANAGE_NO": "park-1"}
        self.assertEqual(match_park_coordinates([place()], [row, {**row, "MANAGE_NO": "park-2"}], "2026-10-26"), [])

    def test_park_capture_is_bound_to_source_bytes_instead_of_conversion_time(self):
        raw = b'[{"MANAGE_NO":"park-1"}]'
        digest = hashlib.sha256(raw).hexdigest()
        source = {"sourceURL": "https://www.data.go.kr/data/15012890/standard.do",
                  "sha256": digest, "rowCount": 1, "capturedAt": "2024-01-01"}
        _, captured, actual = park_source_metadata(raw, {"sources": [source]})
        self.assertEqual((captured, actual), ("2024-01-01", digest))
        for changed in [{**source, "sha256": "0" * 64}, {**source, "rowCount": 2}]:
            with self.assertRaises(ValueError):
                park_source_metadata(raw, {"sources": [changed]})

    def test_address_geocode_requires_exact_returned_address_and_crs(self):
        address = place()["address"]
        response = {"response": {"status": "OK", "input": {"type": "PARCEL", "address": address},
            "refined": {"text": address}, "result": {"crs": "EPSG:4326", "point": {"x": "129.0", "y": "35.2"}}}}
        self.assertEqual(parse_vworld(response, address, "PARCEL"), (35.2, 129.0))
        response["response"]["refined"]["text"] += "-1"
        self.assertIsNone(parse_vworld(response, address, "PARCEL"))
        response["response"]["refined"]["text"] = address
        response["response"]["result"]["crs"] = "EPSG:5179"
        with self.assertRaises(ValueError):
            parse_vworld(response, address, "PARCEL")

    def test_geocoding_error_is_distinct_from_no_match(self):
        self.assertIsNone(parse_vworld({"response": {"status": "NOT_FOUND"}}, "주소", "PARCEL"))
        with self.assertRaises(ValueError):
            parse_vworld({"response": {"status": "ERROR"}}, "주소", "PARCEL")


if __name__ == "__main__":
    unittest.main()
