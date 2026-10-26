"""Official national-equipment API transport and pure response validation.

Contract: https://www.data.go.kr/data/15139207/standard.do (2026-10-26).
The documented page limit is 1,000. The source supplies no stable row ID or
snapshot/version token: duplicate records are retained, and a complete traversal
means the reported API rows, not every facility or an atomic source snapshot.
"""
import hashlib
import json
import math
import os
import re
from collections import Counter
from http.client import HTTPException
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from xml.etree import ElementTree


API_URL = "https://api.data.go.kr/openapi/tn_pubr_public_outdoor_exercise_eqmt_api"
MAXIMUM_ROWS = 250_000
MAXIMUM_BYTES = 60 * 1024 * 1024
MAXIMUM_PAGE_SIZE = 1_000
SERVICE_TABLE = "tn_pubr_public_outdoor_exercise_eqmt_svc"
SERVICE_KEY_ENV = "DATA_GO_KR_SERVICE_KEY"
API_FIELDS = {
    "instlPlcNm": "INSTL_PLC_NM", "ctpvNm": "CTPV_NM", "sggNm": "SGG_NM",
    "lctnRoadNmAddr": "LCTN_ROAD_NM_ADDR", "lctnLotnoAddr": "LCTN_LOTNO_ADDR",
    "lat": "LAT", "lot": "LOT", "sprtgdNm": "SPRTGD_NM", "sprtgdQty": "SPRTGD_QTY",
    "mngInstNm": "MNG_INST_NM", "mngInstTelno": "MNG_INST_TELNO",
    "dataCrtrYmd": "DATA_CRTR_YMD", "instt_code": "INSTT_CODE", "instt_nm": "INSTT_NM",
}
API_RECORD_FIELDS = {"instlPlcNm", "ctpvNm", "sggNm"}
API_FIELD_ALIASES = {"instt_code": "insttCode", "instt_nm": "insttNm"}


class CollectionError(ValueError):
    """Safe diagnostic: never include request URLs, service keys or raw bodies."""


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Checking geturl() after urlopen() is too late: a redirect may already
        # have forwarded the query credential. Refuse even same-host redirects.
        raise CollectionError("API redirect refused before forwarding credentials")


def load_service_key(key_file=None, environ=None):
    environ = os.environ if environ is None else environ
    if key_file is None:
        value = environ.get(SERVICE_KEY_ENV, "")
    else:
        try:
            with Path(key_file).open("rb") as handle:
                encoded = handle.read(8_193)
            value = encoded.decode("ascii")
        except (OSError, UnicodeError):
            raise CollectionError("Cannot read the service-key file as ASCII") from None
    if not isinstance(value, str) or not value.strip() or len(value) > 8_192:
        raise CollectionError("Set DATA_GO_KR_SERVICE_KEY or provide --service-key-file")
    value = value.strip()
    # The portal offers encoded and decoded keys. Decode percent escapes once,
    # then urlencode once. A literal '+' is part of the key, never a space.
    if "%" in value:
        if re.search(r"%(?![0-9A-Fa-f]{2})", value):
            raise CollectionError("Service key contains an invalid percent escape")
        value = unquote(value, encoding="ascii", errors="replace")
    if not re.fullmatch(r"[A-Za-z0-9+/=._~-]+", value):
        raise CollectionError("Service key contains unsupported characters")
    return value


def api_url(service_key, page, page_size):
    return API_URL + "?" + urlencode({"serviceKey": service_key, "pageNo": page,
                                     "numOfRows": page_size, "type": "json"})


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CollectionError("API JSON contains duplicate object keys")
        result[key] = value
    return result


def _invalid_number(value):
    raise CollectionError("API JSON contains a non-finite number")


def _safe_code(value):
    return value if isinstance(value, str) and re.fullmatch(r"[0-9]{2}", value) else "unknown"


def decode_payload(encoded):
    """Decode JSON success/error envelopes and reject XML gateway errors safely."""
    try:
        text = encoded.decode("utf-8-sig")
    except UnicodeError:
        raise CollectionError("API response is not UTF-8") from None
    if text.lstrip().startswith("<"):
        code = "unknown"
        if "<!DOCTYPE" not in text.upper() and "<!ENTITY" not in text.upper():
            try:
                root = ElementTree.fromstring(text)
                code = _safe_code(root.findtext(".//returnReasonCode"))
            except ElementTree.ParseError:
                pass
        raise CollectionError(f"API returned XML instead of JSON (error code {code})")
    try:
        payload = json.loads(text, object_pairs_hook=_unique_object, parse_constant=_invalid_number)
    except (ValueError, RecursionError):
        raise CollectionError("API returned invalid JSON") from None
    if isinstance(payload, dict) and "OpenAPI_ServiceResponse" in payload:
        gateway = payload.get("OpenAPI_ServiceResponse")
        header = gateway.get("cmmMsgHeader") if isinstance(gateway, dict) else None
        code = _safe_code(header.get("returnReasonCode")) if isinstance(header, dict) else "unknown"
        raise CollectionError(f"API gateway rejected the request (error code {code})")
    return payload


def get_api_json(url, timeout):
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or parsed.netloc != "api.data.go.kr"
            or parsed.path != urlsplit(API_URL).path or parsed.fragment):
        raise CollectionError("API request must use the fixed official HTTPS endpoint")
    request = Request(url, headers={"Accept": "application/json",
                                   "User-Agent": "OutdoorLog-Catalog/1.0"})
    try:
        with build_opener(NoRedirects()).open(request, timeout=timeout) as response:
            encoded = response.read(MAXIMUM_BYTES + 1)
    except HTTPError as error:
        try:
            encoded = error.read(MAXIMUM_BYTES + 1)
        except (OSError, ValueError, HTTPException):
            raise CollectionError(f"API HTTP request failed (status {error.code})") from None
        finally:
            error.close()
        if len(encoded) <= MAXIMUM_BYTES:
            try:
                decode_payload(encoded)
            except CollectionError as failure:
                raise CollectionError(str(failure)) from None
        raise CollectionError(f"API HTTP request failed (status {error.code})") from None
    except (URLError, OSError, ValueError, HTTPException) as error:
        if isinstance(error, CollectionError):
            raise error from None
        # urllib exceptions can contain the complete URL including the key.
        raise CollectionError("API network request failed; verify connectivity and credentials") from None
    if len(encoded) > MAXIMUM_BYTES:
        raise CollectionError("API response exceeds the catalog resource limit")
    return decode_payload(encoded)


def _integer(value, label, minimum, maximum):
    if isinstance(value, str) and re.fullmatch(r"[0-9]{1,9}", value):
        value = int(value)
    if type(value) is not int or not minimum <= value <= maximum:
        raise CollectionError(f"Invalid API {label}")
    return value


def canonical_record(row):
    if not isinstance(row, dict) or not API_RECORD_FIELDS.issubset(row):
        raise CollectionError("API record is missing national equipment fields")
    canonical = {}
    for source, target in API_FIELDS.items():
        names = (source, API_FIELD_ALIASES[source]) if source in API_FIELD_ALIASES else (source,)
        values = [row[name] for name in names if name in row]
        for value in values:
            if (value is not None and (type(value) not in (str, int, float)
                    or isinstance(value, float) and not math.isfinite(value))):
                raise CollectionError("API record contains an invalid field value")
        if len(values) > 1 and any(value != values[0] for value in values[1:]):
            raise CollectionError("API record contains conflicting provider field aliases")
        # Optional/null fields may be omitted, and providers may add fields that
        # this catalog does not consume. Keep only this explicit canonical map.
        canonical[target] = values[0] if values else None
    return canonical


def parse_page(payload, page, page_size, expected_total=None):
    response = payload.get("response") if isinstance(payload, dict) else None
    if not isinstance(response, dict):
        raise CollectionError("API response envelope is missing")
    header, body = response.get("header"), response.get("body")
    if not isinstance(header, dict) or header.get("resultCode") != "00":
        code = _safe_code(header.get("resultCode")) if isinstance(header, dict) else "unknown"
        raise CollectionError(f"API result failed (error code {code})")
    if not isinstance(body, dict):
        raise CollectionError("API response body is missing")
    total = _integer(body.get("totalCount"), "totalCount", 1, MAXIMUM_ROWS)
    returned_page = _integer(body.get("pageNo"), "pageNo", 1, MAXIMUM_ROWS)
    returned_size = _integer(body.get("numOfRows"), "numOfRows", 1, MAXIMUM_PAGE_SIZE)
    if returned_page != page or returned_size != page_size:
        raise CollectionError("API response pagination does not match the requested page")
    if expected_total is not None and total != expected_total:
        raise CollectionError("API totalCount changed during collection; retry the snapshot")
    items = body.get("items")
    if isinstance(items, dict) and set(items) == {"item"}:
        items = items["item"]
        if isinstance(items, dict):
            items = [items]
    expected = min(page_size, total - (page - 1) * page_size)
    if (expected <= 0 or not isinstance(items, list) or len(items) != expected):
        raise CollectionError(f"API page {page} is incomplete or has unexpected extra rows")
    return total, [canonical_record(row) for row in items]


def row_fingerprint(row):
    return hashlib.sha256(json.dumps(row, sort_keys=True, ensure_ascii=False,
        separators=(",", ":"), allow_nan=False).encode("utf-8")).hexdigest()


def page_fingerprint(rows):
    # Keep duplicate multiplicity while ignoring server order within a page.
    return hashlib.sha256("\n".join(sorted(row_fingerprint(row) for row in rows)).encode("ascii")).hexdigest()


def collect_official_api(service_key, timeout, page_size=MAXIMUM_PAGE_SIZE, fetch=get_api_json):
    page_size = _integer(page_size, "page size", 1, MAXIMUM_PAGE_SIZE)
    total, first_rows = parse_page(fetch(api_url(service_key, 1, page_size), timeout), 1, page_size)
    page_count = math.ceil(total / page_size)
    rows, pages, page_digests, previous_rows = [], [], set(), Counter()
    cross_page_duplicates = received_bytes = 0
    for page in range(1, page_count + 1):
        if page == 1:
            batch = first_rows
        else:
            _, batch = parse_page(fetch(api_url(service_key, page, page_size), timeout),
                                  page, page_size, total)
        received_bytes += len(json.dumps(batch, ensure_ascii=False, allow_nan=False).encode("utf-8"))
        if received_bytes > MAXIMUM_BYTES:
            raise CollectionError("API collection exceeds the catalog resource limit")
        digest = page_fingerprint(batch)
        if digest in page_digests:
            raise CollectionError("API repeated an entire page; coverage cannot be established")
        page_digests.add(digest)
        fingerprints = Counter(row_fingerprint(row) for row in batch)
        cross_page_duplicates += sum(count for value, count in fingerprints.items() if value in previous_rows)
        previous_rows.update(fingerprints)
        pages.append({"pageNo": page, "rowCount": len(batch), "sha256": digest})
        rows.extend(batch)
    # There is no snapshot token. Re-read boundaries as a drift check, without
    # pretending that unchanged counts/boundaries prove an atomic database read.
    rechecked_pages = sorted({1, page_count})
    for page in rechecked_pages:
        _, batch = parse_page(fetch(api_url(service_key, page, page_size), timeout), page, page_size, total)
        if page_fingerprint(batch) != pages[page - 1]["sha256"]:
            raise CollectionError("API boundary page changed during collection; retry the snapshot")
    header = {"transport": "official-api", "totalCount": total,
              "tableVO": {"svcTableNm": SERVICE_TABLE, "colNmList": list(API_FIELDS.values())},
              "apiCollection": {"endpoint": API_URL, "pageSize": page_size, "pageCount": page_count,
                  "pages": pages, "boundaryPagesRechecked": rechecked_pages,
                  "duplicateRowCount": total - len(previous_rows),
                  "crossPageDuplicateRowCount": cross_page_duplicates,
                  "coverage": "reported-api-rows", "snapshotIsolation": "not-provided-by-source"}}
    return rows, header


def validate_api_header(header):
    """Validate traversal evidence before normalizer accepts an API proof."""
    total = _integer(header.get("totalCount"), "header totalCount", 1, MAXIMUM_ROWS)
    metadata = header.get("apiCollection")
    if not isinstance(metadata, dict) or metadata.get("endpoint") != API_URL:
        raise CollectionError("Official API collection metadata is missing")
    size = _integer(metadata.get("pageSize"), "header pageSize", 1, MAXIMUM_PAGE_SIZE)
    count = _integer(metadata.get("pageCount"), "header pageCount", 1, MAXIMUM_ROWS)
    if count != math.ceil(total / size):
        raise CollectionError("Official API page count does not match totalCount")
    pages = metadata.get("pages")
    if not isinstance(pages, list) or len(pages) != count:
        raise CollectionError("Official API page proofs are incomplete")
    digests = set()
    for page, proof in enumerate(pages, start=1):
        if (not isinstance(proof, dict) or type(proof.get("pageNo")) is not int or proof["pageNo"] != page
                or type(proof.get("rowCount")) is not int
                or proof["rowCount"] != min(size, total - (page - 1) * size)
                or not isinstance(proof.get("sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", proof["sha256"])
                or proof["sha256"] in digests):
            raise CollectionError("Official API page proof is invalid or repeated")
        digests.add(proof["sha256"])
    duplicates = _integer(metadata.get("duplicateRowCount"), "duplicateRowCount", 0, total - 1)
    _integer(metadata.get("crossPageDuplicateRowCount"), "crossPageDuplicateRowCount", 0, duplicates)
    boundaries = metadata.get("boundaryPagesRechecked")
    if (not isinstance(boundaries, list) or any(type(page) is not int for page in boundaries)
            or boundaries != sorted({1, count})
            or metadata.get("coverage") != "reported-api-rows"
            or metadata.get("snapshotIsolation") != "not-provided-by-source"):
        raise CollectionError("Official API coverage evidence is incomplete")
    return total
