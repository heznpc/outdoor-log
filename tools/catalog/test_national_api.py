"""Offline contract tests; all responses are synthetic, never live API evidence."""
import copy
import hashlib
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request

import fetch_national
import national_api


def record(name):
    return {"instlPlcNm": name, "ctpvNm": "서울특별시", "sggNm": "종로구",
            "lctnRoadNmAddr": "", "lctnLotnoAddr": "서울특별시 종로구",
            "lat": "37.57", "lot": "126.98", "sprtgdNm": "공중걷기+허리돌리기",
            "sprtgdQty": "2", "mngInstNm": "종로구", "mngInstTelno": "",
            "dataCrtrYmd": "2026-01-01", "instt_code": "fixture", "instt_nm": "시험기관"}


def response(rows, page=1, size=2, total=None):
    return {"response": {"header": {"resultCode": "00", "resultMsg": "NORMAL_CODE"},
                         "body": {"items": rows, "pageNo": page, "numOfRows": size,
                                  "totalCount": len(rows) if total is None else total}}}


class ScriptedFetch:
    def __init__(self, pages):
        self.pages = pages
        self.requests = []

    def __call__(self, url, timeout):
        query = parse_qs(urlsplit(url).query)
        page = int(query["pageNo"][0])
        self.requests.append(page)
        return copy.deepcopy(self.pages[page])


class CredentialTests(unittest.TestCase):
    def test_encoded_and_decoded_keys_are_encoded_once(self):
        for value in ("test+/=", "test%2B%2F%3D"):
            with self.subTest(value=value):
                key = national_api.load_service_key(environ={"DATA_GO_KR_SERVICE_KEY": value})
                self.assertEqual(key, "test+/=")
                query = parse_qs(urlsplit(national_api.api_url(key, 1, 1000)).query)
                self.assertEqual(query, {"serviceKey": ["test+/="], "pageNo": ["1"],
                                         "numOfRows": ["1000"], "type": ["json"]})

    def test_missing_and_malformed_keys_do_not_leak(self):
        for key in ("", "private secret", "private%broken", "private%252B", "private\nsecret", "a" * 8193):
            with self.subTest(length=len(key)):
                with self.assertRaises(national_api.CollectionError) as caught:
                    national_api.load_service_key(environ={"DATA_GO_KR_SERVICE_KEY": key})
                self.assertNotIn("private", str(caught.exception))

    def test_key_file_takes_precedence_without_loading_other_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            key_file = Path(temporary) / "key"
            key_file.write_text("test%2B%2F%3D\n", encoding="ascii")
            self.assertEqual(national_api.load_service_key(key_file, {"DATA_GO_KR_SERVICE_KEY": "other"}),
                             "test+/=")

    def test_redirects_are_rejected_before_a_followup_request_exists(self):
        request = Request(national_api.api_url("private-key", 1, 1000))
        for location in ("https://outside.example/?serviceKey=private-key",
                         "http://api.data.go.kr/openapi/other", national_api.API_URL):
            with self.subTest(location=location):
                with self.assertRaises(national_api.CollectionError) as caught:
                    national_api.NoRedirects().redirect_request(request, None, 302, "Found", {}, location)
                self.assertNotIn("private-key", str(caught.exception))

    def test_nonofficial_urls_are_rejected_without_opening(self):
        with patch("national_api.build_opener") as opener:
            for url in ("http://api.data.go.kr/openapi/x", "https://other.example/",
                        "https://api.data.go.kr:444/openapi/x", national_api.API_URL + "/other"):
                with self.assertRaises(national_api.CollectionError):
                    national_api.get_api_json(url, 1)
            opener.assert_not_called()

    def test_transport_errors_never_include_request_url_or_body(self):
        url = national_api.api_url("private-key", 1, 1000)
        body = json.dumps({"OpenAPI_ServiceResponse": {"cmmMsgHeader": {
            "returnReasonCode": "30", "errMsg": "private-key"}}}).encode()
        failures = [URLError(url), HTTPError(url, 401, "private-key", {}, io.BytesIO(body))]
        for failure in failures:
            with self.subTest(failure=type(failure).__name__):
                with patch("national_api.build_opener") as opener:
                    opener.return_value.open.side_effect = failure
                    with self.assertRaises(national_api.CollectionError) as caught:
                        national_api.get_api_json(url, 1)
                    self.assertNotIn("private-key", str(caught.exception))
                    self.assertNotIn("serviceKey", str(caught.exception))


class PayloadTests(unittest.TestCase):
    def test_maps_documented_fields_without_splitting_or_guessing_values(self):
        row = national_api.canonical_record(record("시험장소"))
        self.assertEqual(row["INSTL_PLC_NM"], "시험장소")
        self.assertEqual(row["SPRTGD_NM"], "공중걷기+허리돌리기")
        self.assertEqual(row["SPRTGD_QTY"], "2")
        self.assertEqual(row["INSTT_NM"], "시험기관")
        self.assertEqual(set(row), set(national_api.API_FIELDS.values()))

    def test_optional_absence_stays_unknown(self):
        item = {"instlPlcNm": "시험", "ctpvNm": "서울특별시", "sggNm": "종로구"}
        parsed = national_api.canonical_record(item)
        self.assertIsNone(parsed["LAT"])
        self.assertIsNone(parsed["LCTN_ROAD_NM_ADDR"])
        self.assertIsNone(parsed["SPRTGD_NM"])
        self.assertIsNone(parsed["SPRTGD_QTY"])
        self.assertIsNone(parsed["DATA_CRTR_YMD"])

    def test_additional_provider_fields_do_not_change_the_canonical_record(self):
        item = record("시험")
        self.assertEqual(national_api.canonical_record(dict(item, extraProviderField={"value": "extra"})),
                         national_api.canonical_record(item))

    def test_provider_camel_case_aliases_match_the_documented_underscore_names(self):
        item = record("시험")
        expected = national_api.canonical_record(item)
        for source, alias in national_api.API_FIELD_ALIASES.items():
            item[alias] = item[source]
        self.assertEqual(national_api.canonical_record(item), expected)
        for source in national_api.API_FIELD_ALIASES:
            del item[source]
        self.assertEqual(national_api.canonical_record(item), expected)

    def test_conflicting_provider_aliases_are_rejected(self):
        for source, alias in national_api.API_FIELD_ALIASES.items():
            for value in ("different", None, True):
                item = record("시험")
                item[alias] = value
                with self.subTest(alias=alias, value=value):
                    with self.assertRaises(national_api.CollectionError):
                        national_api.canonical_record(item)

    def test_renamed_required_identity_field_is_not_silently_accepted(self):
        for field in national_api.API_RECORD_FIELDS:
            item = record("시험")
            item["renamedField"] = item.pop(field)
            with self.subTest(field=field):
                with self.assertRaises(national_api.CollectionError):
                    national_api.canonical_record(item)

    def test_string_paging_and_item_wrapper(self):
        payload = response([record("시험")], size=1)
        body = payload["response"]["body"]
        body.update({"items": {"item": record("시험")}, "pageNo": "1", "numOfRows": "1", "totalCount": "1"})
        total, rows = national_api.parse_page(payload, 1, 1)
        self.assertEqual(total, 1)
        self.assertEqual(len(rows), 1)

    def test_http_200_api_errors_are_not_data(self):
        for code in ("01", "03", "22", "30", "99", None, 0):
            with self.subTest(code=code):
                payload = response([record("시험")], size=1)
                payload["response"]["header"]["resultCode"] = code
                payload["response"]["header"]["resultMsg"] = "private-key"
                with self.assertRaises(national_api.CollectionError) as caught:
                    national_api.parse_page(payload, 1, 1)
                self.assertNotIn("private-key", str(caught.exception))

    def test_json_and_xml_gateway_errors_never_echo_messages(self):
        bodies = [b'{"OpenAPI_ServiceResponse":{"cmmMsgHeader":{"returnReasonCode":"20","errMsg":"private-key"}}}',
                  b'<OpenAPI_ServiceResponse><cmmMsgHeader><returnReasonCode>30</returnReasonCode><errMsg>private-key</errMsg></cmmMsgHeader></OpenAPI_ServiceResponse>',
                  b'{"private-key":', b'{"x":1,"x":2}', b'{"x":NaN}', b'\xff']
        for body in bodies:
            with self.subTest(body=body[:20]):
                with self.assertRaises(national_api.CollectionError) as caught:
                    national_api.decode_payload(body)
                self.assertNotIn("private-key", str(caught.exception))

    def test_pagination_and_record_errors_fail_closed(self):
        mutations = [("pageNo", 2), ("pageNo", True), ("numOfRows", 1),
                     ("totalCount", 0), ("totalCount", 250001), ("totalCount", 1.5),
                     ("items", []), ("items", [record("A")]),
                     ("items", [record("A"), record("B"), record("C")])]
        for field, value in mutations:
            with self.subTest(field=field, value=type(value).__name__):
                payload = response([record("A"), record("B")])
                payload["response"]["body"][field] = value
                with self.assertRaises(national_api.CollectionError):
                    national_api.parse_page(payload, 1, 2)
        for value in ([], {}, True, float("inf")):
            item = record("A")
            item["sprtgdQty"] = value
            with self.assertRaises(national_api.CollectionError):
                national_api.canonical_record(item)
        with self.assertRaises(national_api.CollectionError):
            national_api.canonical_record({"instlPlcNm": "A"})


class CollectionTests(unittest.TestCase):
    def test_all_pages_and_boundaries_are_checked_and_duplicates_retained(self):
        fetch = ScriptedFetch({1: response([record("A"), record("B")], total=4),
                               2: response([record("B"), record("C")], page=2, total=4)})
        rows, header = national_api.collect_official_api("test-key", 1, 2, fetch)
        self.assertEqual(fetch.requests, [1, 2, 1, 2])
        self.assertEqual([row["INSTL_PLC_NM"] for row in rows], ["A", "B", "B", "C"])
        self.assertEqual(header["apiCollection"]["duplicateRowCount"], 1)
        self.assertEqual(header["apiCollection"]["crossPageDuplicateRowCount"], 1)
        self.assertEqual(national_api.validate_api_header(header), 4)
        self.assertEqual(fetch_national.header_fields(header)[0], 4)

    def test_partial_final_page_and_single_page(self):
        fetch = ScriptedFetch({1: response([record("A"), record("B")], total=3),
                               2: response([record("C")], page=2, total=3)})
        rows, header = national_api.collect_official_api("test-key", 1, 2, fetch)
        self.assertEqual(len(rows), 3)
        self.assertEqual(header["apiCollection"]["pages"][1]["rowCount"], 1)
        single = ScriptedFetch({1: response([record("A")], total=1)})
        national_api.collect_official_api("test-key", 1, 2, single)
        self.assertEqual(single.requests, [1, 1])

    def test_reordered_repeated_whole_page_is_rejected(self):
        fetch = ScriptedFetch({1: response([record("A"), record("B")], total=4),
                               2: response([record("B"), record("A")], page=2, total=4)})
        with self.assertRaisesRegex(national_api.CollectionError, "entire page"):
            national_api.collect_official_api("test-key", 1, 2, fetch)

    def test_changed_total_wrong_page_and_short_page_are_rejected(self):
        for second in (response([record("C"), record("D")], page=2, total=5),
                       response([record("C"), record("D")], page=1, total=4),
                       response([record("C")], page=2, total=4)):
            fetch = ScriptedFetch({1: response([record("A"), record("B")], total=4), 2: second})
            with self.assertRaises(national_api.CollectionError):
                national_api.collect_official_api("test-key", 1, 2, fetch)

    def test_boundary_changes_with_same_total_are_rejected(self):
        fetch = ScriptedFetch({1: response([record("A"), record("B")], total=4),
                               2: response([record("C"), record("D")], page=2, total=4)})

        def changing(url, timeout):
            result = fetch(url, timeout)
            if len(fetch.requests) == 3:
                result["response"]["body"]["items"][0]["instlPlcNm"] = "changed"
            return result

        with self.assertRaisesRegex(national_api.CollectionError, "boundary page changed"):
            national_api.collect_official_api("test-key", 1, 2, changing)

    def test_snapshot_proof_uses_exact_bytes_and_contains_no_key(self):
        fetch = ScriptedFetch({1: response([record("A"), record("B")])})
        rows, header = national_api.collect_official_api("private-key", 1, 2, fetch)
        encoded, prepared = fetch_national.prepare_snapshot(rows, header)
        proof = prepared["collectionProof"]
        self.assertEqual(proof["schemaVersion"], 1)
        self.assertEqual(proof["sourceID"], "data-go-kr:15139207")
        self.assertEqual(proof["rowCount"], 2)
        self.assertEqual(proof["byteCount"], len(encoded))
        self.assertEqual(proof["sha256"], hashlib.sha256(encoded).hexdigest())
        self.assertEqual(json.loads(encoded), rows)
        self.assertNotIn("private-key", json.dumps(prepared))
        self.assertEqual(proof["snapshotIsolation"], "not-provided-by-source")

    def test_broken_page_proof_is_not_accepted(self):
        fetch = ScriptedFetch({1: response([record("A"), record("B")])})
        _, header = national_api.collect_official_api("test-key", 1, 2, fetch)
        for field, value in (("pages", []), ("pageCount", 2), ("boundaryPagesRechecked", []),
                             ("snapshotIsolation", "atomic"), ("endpoint", "https://other.example/"),
                             ("duplicateRowCount", -1)):
            broken = copy.deepcopy(header)
            broken["apiCollection"][field] = value
            with self.assertRaises(national_api.CollectionError):
                fetch_national.header_fields(broken)

    def test_api_failure_does_not_fall_back_or_publish(self):
        arguments = ["fetch_national.py", "--output", "/tmp/offline-fixture.json",
                     "--header-output", "/tmp/offline-fixture-header.json"]
        with patch("sys.argv", arguments), patch("fetch_national.load_service_key", return_value="test-key"), \
                patch("fetch_national.collect_official_api", side_effect=national_api.CollectionError("fixture failure")), \
                patch("fetch_national.collect_portal") as portal, \
                patch("fetch_national.publish_snapshot") as publish, redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                fetch_national.main()
            self.assertEqual(caught.exception.code, 1)
            portal.assert_not_called()
            publish.assert_not_called()

    def test_api_header_can_exceed_portal_cap_with_complete_page_metadata(self):
        total, size = 50_001, 1000
        count = 51
        header = {"transport": "official-api", "totalCount": total,
                  "tableVO": {"svcTableNm": national_api.SERVICE_TABLE,
                              "colNmList": list(national_api.API_FIELDS.values())},
                  "apiCollection": {"endpoint": national_api.API_URL, "pageSize": size,
                      "pageCount": count, "boundaryPagesRechecked": [1, count],
                      "duplicateRowCount": 0, "crossPageDuplicateRowCount": 0,
                      "coverage": "reported-api-rows", "snapshotIsolation": "not-provided-by-source",
                      "pages": [{"pageNo": page, "rowCount": min(size, total - (page - 1) * size),
                                 "sha256": f"{page:064x}"} for page in range(1, count + 1)]}}
        self.assertEqual(fetch_national.header_fields(header)[0], total)
        header["transport"] = "portal"
        with self.assertRaises(ValueError):
            fetch_national.header_fields(header)

    def test_legacy_portal_header_and_count_cap_are_preserved(self):
        header = {"totalCount": 2, "tableVO": {"svcTableNm": national_api.SERVICE_TABLE,
                                              "colNmList": list(national_api.API_FIELDS.values())}}
        self.assertEqual(fetch_national.header_fields(header)[0], 2)
        for count in (0, True, 50_000):
            with self.subTest(count=count):
                header["totalCount"] = count
                with self.assertRaises(ValueError):
                    fetch_national.header_fields(header)


if __name__ == "__main__":
    unittest.main()
