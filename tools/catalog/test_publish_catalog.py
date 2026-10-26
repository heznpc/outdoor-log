"""Offline release regressions. No API, deployment or user records are inputs."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from catalog_coordinates import apply_supplements
import fetch_national
import national_api
from normalize import NATIONAL_SOURCE_ID, NATIONAL_SOURCE_URL, from_national, source_summary, validate_pack
import publish_catalog as publish


def place(identity, source=NATIONAL_SOURCE_ID):
    return {"id": identity, "name": identity, "address": "서울특별시 종로구 시험로 1",
        "regionCode": "11110", "regionName": "서울특별시 종로구", "sourceID": source,
        "latitude": None, "longitude": None, "coordinateQuality": "unknown",
        "equipment": [{"name": "공중걷기", "count": None}], "equipmentCount": None,
        "equipmentInformationKnown": True, "facilityTypes": [],
        "provenance": {"provider": "시험기관", "datasetTitle": "공식 자료 시험 fixture",
            "sourceURL": NATIONAL_SOURCE_URL if source == NATIONAL_SOURCE_ID else "https://www.data.go.kr/data/15104705/fileData.do",
            "sourceRecordID": identity, "capturedAt": "2026-10-26T01:00:00Z",
            "license": "시험 자료"}}


def pack(places, row_count=None):
    source = places[0]["sourceID"]
    summary = {"id": source, "capturedAt": "2026-10-26T01:00:00Z",
        "completeCapturedAt": "2026-10-26T01:00:00Z",
        "rowCount": len(places) if row_count is None else row_count,
        "placeCount": len(places), "missingCoordinateCount": len(places),
        "regions": ["서울특별시 종로구"], "requiresPlaceSourceID": True}
    return {"schemaVersion": 1, "version": 20261026010000, "generatedAt": "2026-10-26T01:00:00Z",
            "places": places, "sources": [summary]}


def collected_national():
    row = {"INSTL_PLC_NM": "시험공원", "CTPV_NM": "서울특별시", "SGG_NM": "종로구",
        "LCTN_ROAD_NM_ADDR": "서울특별시 종로구 시험로 1", "LCTN_LOTNO_ADDR": "",
        "LAT": "", "LOT": "", "SPRTGD_NM": "공중걷기", "SPRTGD_QTY": "1",
        "DATA_CRTR_YMD": "2026-01-01", "MNG_INST_NM": "시험기관"}
    rows = [row, deepcopy(row)]
    header = {"transport": "official-api", "totalCount": 2,
        "tableVO": {"svcTableNm": fetch_national.SERVICE_TABLE, "colNmList": sorted(row)},
        "apiCollection": {"endpoint": national_api.API_URL, "pageSize": 1000, "pageCount": 1,
            "pages": [{"pageNo": 1, "rowCount": 2, "sha256": fetch_national.page_fingerprint(rows)}],
            "duplicateRowCount": 1, "crossPageDuplicateRowCount": 0, "boundaryPagesRechecked": [1],
            "coverage": "reported-api-rows", "snapshotIsolation": "not-provided-by-source"}}
    raw, header = fetch_national.prepare_snapshot(rows, header)
    config = {"sourceID": NATIONAL_SOURCE_ID, "sourceURL": NATIONAL_SOURCE_URL,
        "idPrefix": "national-equipment-", "provider": "시험기관", "datasetTitle": "시험자료",
        "license": "시험자료", "capturedAt": header["collectionProof"]["capturedAt"]}
    places = from_national(rows, config)
    result = {"schemaVersion": 1, "version": 20261026010000, "generatedAt": "2026-10-26T01:00:00Z",
        "places": places, "sources": [source_summary(config, 2, places, complete=True)]}
    return result, raw, header, config


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.pack = pack([place("national-equipment-one"), place("national-equipment-two")], 5)
        self.weights = {"national-equipment-one": 2, "national-equipment-two": 3}
        self.base = "https://catalog.example/outdoor-log"

    def test_shards_keep_exact_national_row_totals_and_valid_app_summaries(self):
        limit = len(publish.encoded(self.pack)) - 1
        fragments = publish.split_packs(self.pack, self.weights, maximum_bytes=limit)
        self.assertEqual(len(fragments), 2)
        self.assertEqual(sum(fragment["sources"][0]["rowCount"] for fragment, _ in fragments), 5)
        for fragment, payload in fragments:
            validate_pack(fragment)
            self.assertLessEqual(len(payload), limit)
            self.assertEqual(fragment["sources"][0]["missingCoordinateCount"], 1)

    def test_official_collection_proof_is_checked_against_normalized_places(self):
        candidate, raw, header, config = collected_national()
        proof, weights = publish.verified_national(candidate, raw, header, config)
        self.assertEqual(proof["rowCount"], 2)
        self.assertEqual(list(weights.values()), [2])
        candidate["places"][0]["name"] = "검증되지 않은 변경"
        with self.assertRaises(ValueError):
            publish.verified_national(candidate, raw, header, config)

    def test_corrupted_api_bytes_cannot_publish(self):
        candidate, raw, header, config = collected_national()
        with self.assertRaises(ValueError):
            publish.verified_national(candidate, raw + b" ", header, config)

    def test_regional_raw_rows_are_counted_once_across_shards(self):
        regional = pack([place("regional-one", "regional:fixture"), place("regional-two", "regional:fixture")], 101)
        fragments = publish.split_packs(regional, {}, maximum_bytes=len(publish.encoded(regional)) - 1)
        self.assertEqual([fragment["sources"][0]["rowCount"] for fragment, _ in fragments], [101, 0])
        self.assertEqual(sum(len(fragment["places"]) for fragment, _ in fragments), 2)

    def test_manifest_hashes_lengths_counts_and_versions_match_exact_bytes(self):
        files, manifest = publish.release_files(self.pack, {"transport": "official-api"}, self.weights, self.base, {})
        for entry in manifest["packs"]:
            relative = entry["url"].removeprefix(self.base + "/")
            payload = files[relative]
            decoded = json.loads(payload)
            self.assertEqual(entry["sha256"], hashlib.sha256(payload).hexdigest())
            self.assertEqual(entry["byteCount"], len(payload))
            self.assertEqual(entry["placeCount"], len(decoded["places"]))
            self.assertEqual(decoded["version"], manifest["version"])
        self.assertEqual(json.loads(files["manifest.json"]), manifest)
        self.assertFalse(json.loads(files["coverage.json"])["completeInventory"])

    def test_total_limit_rejects_collection_even_when_individual_packs_fit(self):
        with patch.object(publish, "MAXIMUM_BYTES", 1):
            with self.assertRaises(ValueError):
                publish.split_packs(self.pack, self.weights)

    def test_oversized_single_place_is_rejected(self):
        with self.assertRaises(ValueError):
            publish.split_packs(self.pack, self.weights, maximum_bytes=10)

    def test_urls_reject_credentials_queries_fragments_and_build_setting_injection(self):
        for value in ("http://catalog.example", "https://key@catalog.example", "https://catalog.example/?key=private",
                      "https://catalog.example/#fragment", "https://catalog.example/../escape",
                      "https://catalog.example/$(OTHER)", "https://catalog.example/\nSETTING=x"):
            with self.subTest(url=value), self.assertRaises(ValueError):
                publish.public_base_url(value)

    def test_xcconfig_preserves_double_slash_without_starting_a_comment(self):
        value = publish.xcconfig(self.base)
        self.assertEqual(value, "OUTDOOR_LOG_CATALOG_MANIFEST_URL = https:/$()/catalog.example/outdoor-log/manifest.json\n")
        self.assertNotIn("//", value)

    def test_verified_previous_release_survives_new_deployment(self):
        files, _ = publish.release_files(self.pack, {}, self.weights, self.base, {})
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "site"
            publish.write_release(output, files)
            retained = publish.previous_release(output, self.base, self.pack["version"] + 1)
            self.assertNotIn("manifest.json", retained)
            self.assertTrue(all(name.startswith(f'releases/{self.pack["version"]}/') for name in retained))
            for name, payload in retained.items():
                self.assertEqual(payload, files[name])

    def test_corrupt_previous_release_and_version_rollback_abort(self):
        files, manifest = publish.release_files(self.pack, {}, self.weights, self.base, {})
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "site"
            publish.write_release(output, files)
            with self.assertRaises(ValueError):
                publish.previous_release(output, self.base, self.pack["version"])
            path = output / manifest["packs"][0]["url"].removeprefix(self.base + "/")
            altered = json.loads(path.read_bytes())
            altered["places"][0]["name"] = "변경된 자료"
            path.write_bytes(publish.encoded(altered))
            with self.assertRaises(ValueError):
                publish.previous_release(output, self.base, self.pack["version"] + 1)

    def test_existing_release_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "site"
            publish.write_release(output, {"manifest.json": b"old"})
            with self.assertRaises(ValueError):
                publish.write_release(output, {"manifest.json": b"new"})
            self.assertEqual((output / "manifest.json").read_bytes(), b"old")

    def test_live_release_is_restored_without_a_local_cache(self):
        files, manifest = publish.release_files(self.pack, {}, self.weights, self.base, {})
        requested = []
        def fetch(url, limit):
            requested.append(url)
            return files[url.removeprefix(self.base + "/")]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "restored"
            publish.restore_published_release(self.base, output, deployment_exists=True, fetch=fetch)
            retained = publish.previous_release(output, self.base, self.pack["version"] + 1)
            self.assertEqual(requested.count(self.base + "/manifest.json"), 2)
            for entry in manifest["packs"]:
                relative = entry["url"].removeprefix(self.base + "/")
                self.assertEqual(retained[relative], files[relative])

    def test_missing_cache_never_implies_first_deployment(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                publish.previous_release(Path(temporary) / "absent", self.base, self.pack["version"] + 1)

    def test_first_publication_requires_explicit_choice_empty_history_and_http_404(self):
        def missing(url, limit):
            raise publish.PublicFileMissing("HTTP 404")
        with tempfile.TemporaryDirectory() as temporary:
            for exists, first in ((True, True), (True, False), (False, False)):
                output = Path(temporary) / f"denied-{exists}-{first}"
                with self.subTest(exists=exists, first=first), self.assertRaises(ValueError):
                    publish.restore_published_release(self.base, output, exists, first, fetch=missing)
                self.assertFalse(output.exists())
            output = Path(temporary) / "first"
            publish.restore_published_release(self.base, output, False, True, fetch=missing)
            self.assertEqual(publish.previous_release(output, self.base, self.pack["version"]), {})

    def test_network_failure_is_not_first_publication_even_when_explicitly_requested(self):
        def unavailable(url, limit):
            raise ValueError("network unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "first"
            with self.assertRaises(ValueError):
                publish.restore_published_release(self.base, output, False, True, fetch=unavailable)
            self.assertFalse(output.exists())

    def test_first_publication_flag_does_not_discard_an_existing_live_manifest(self):
        files, _ = publish.release_files(self.pack, {}, self.weights, self.base, {})
        def fetch(url, limit):
            return files[url.removeprefix(self.base + "/")]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "existing"
            publish.restore_published_release(self.base, output, False, True, fetch=fetch)
            self.assertTrue((output / "manifest.json").is_file())
            self.assertFalse((output / "first-deployment.json").exists())

    def test_missing_or_corrupted_live_pack_aborts_before_writing_restore(self):
        files, manifest = publish.release_files(self.pack, {}, self.weights, self.base, {})
        pack_path = manifest["packs"][0]["url"].removeprefix(self.base + "/")
        with tempfile.TemporaryDirectory() as temporary:
            for missing in (False, True):
                output = Path(temporary) / f"bad-{missing}"
                def fetch(url, limit):
                    relative = url.removeprefix(self.base + "/")
                    if relative == pack_path:
                        if missing:
                            raise publish.PublicFileMissing("HTTP 404")
                        return files[relative] + b" "
                    return files[relative]
                with self.subTest(missing=missing), self.assertRaises(ValueError):
                    publish.restore_published_release(self.base, output, True, fetch=fetch)
                self.assertFalse(output.exists())

    def test_foreign_pack_origin_is_rejected_without_fetching_it(self):
        files, manifest = publish.release_files(self.pack, {}, self.weights, self.base, {})
        manifest["packs"][0]["url"] = "https://outside.example/untrusted.json"
        requested = []
        def fetch(url, limit):
            requested.append(url)
            return publish.encoded(manifest)
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                publish.restore_published_release(self.base, Path(temporary) / "bad", True, fetch=fetch)
            self.assertEqual(requested, [self.base + "/manifest.json"])

    def test_manifest_change_during_restoration_aborts(self):
        files, _ = publish.release_files(self.pack, {}, self.weights, self.base, {})
        reads = 0
        def fetch(url, limit):
            nonlocal reads
            relative = url.removeprefix(self.base + "/")
            if relative == "manifest.json":
                reads += 1
                if reads == 2:
                    return files[relative] + b" "
            return files[relative]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "racing"
            with self.assertRaises(ValueError):
                publish.restore_published_release(self.base, output, True, fetch=fetch)
            self.assertFalse(output.exists())

    def test_legacy_attribution_updates_missing_coordinate_summary_after_enrichment(self):
        source = "data-go-kr:15104705"
        legacy = pack([place("gimhae-equipment-one", source)])
        del legacy["places"][0]["sourceID"]
        del legacy["sources"][0]["requiresPlaceSourceID"]
        attributed = publish.attribute_sources(legacy)
        entry = {"placeID": "gimhae-equipment-one", "latitude": 37.57, "longitude": 126.98,
            "quality": "park", "sourceURL": "https://www.data.go.kr/data/15012890/standard.do",
            "method": "official-park-exact-name-address", "capturedAt": "2026-10-26T02:00:00Z",
            "matchedAddress": legacy["places"][0]["address"], "matchedName": legacy["places"][0]["name"]}
        updated, _ = apply_supplements(attributed, {"schemaVersion": 1, "entries": [entry]})
        validate_pack(updated)
        self.assertEqual(updated["sources"][0]["missingCoordinateCount"], 0)
        self.assertNotIn("sourceID", legacy["places"][0])

    def test_coverage_lists_missing_provinces_without_claiming_complete_inventory(self):
        report = publish.coverage_report(self.pack, {}, {})
        self.assertEqual(len(report["provinces"]), 17)
        seoul = next(item for item in report["provinces"] if item["province"] == "서울특별시")
        jeju = next(item for item in report["provinces"] if item["province"] == "제주특별자치도")
        self.assertEqual(seoul["missingCoordinateCount"], 2)
        self.assertEqual(jeju["placeCount"], 0)
        self.assertTrue(all(not item["completeInventory"] for item in report["provinces"]))


if __name__ == "__main__":
    unittest.main()
