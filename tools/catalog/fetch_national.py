#!/usr/bin/env python3
"""Collect national equipment dataset 15139207 using its official HTTPS API.

Set DATA_GO_KR_SERVICE_KEY or use --service-key-file (decoded or percent-encoded
key). Keys are never accepted on the command line or written into collection
proofs. The public portal download is available only with --transport portal;
API failures never silently switch sources. Incomplete downloads do not replace
the previous snapshot. API coverage describes reported rows, not all facilities.
"""
import argparse
import hashlib
import json
import math
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

from national_api import (API_URL, CollectionError, MAXIMUM_PAGE_SIZE, collect_official_api,
                          load_service_key, page_fingerprint, validate_api_header)


HEADER_URL = "https://www.data.go.kr/download/columList.json?pk=15139207&ext=JSON"
DATA_URL = "https://www.data.go.kr/download/standard.json"
DOWNLOAD_ROW_LIMIT = 50_000
MAXIMUM_BYTES = 60 * 1024 * 1024
SERVICE_TABLE = "tn_pubr_public_outdoor_exercise_eqmt_svc"
SOURCE_ID = "data-go-kr:15139207"
REQUIRED_COLUMNS = {
    "INSTL_PLC_NM", "CTPV_NM", "SGG_NM", "LCTN_ROAD_NM_ADDR", "LCTN_LOTNO_ADDR",
    "LAT", "LOT", "SPRTGD_NM", "SPRTGD_QTY", "DATA_CRTR_YMD", "MNG_INST_NM"
}


def get_json(url, timeout):
    request = Request(url, headers={"Accept": "application/json",
                                  "User-Agent": "OutdoorLog-Catalog/1.0"})
    with urlopen(request, timeout=timeout) as response:
        final_url = urlsplit(response.geturl())
        if final_url.scheme != "https" or final_url.hostname != "www.data.go.kr":
            raise ValueError("Public download redirected outside the expected HTTPS host")
        encoded = response.read(MAXIMUM_BYTES + 1)
        if len(encoded) > MAXIMUM_BYTES:
            raise ValueError("Public download exceeds the catalog resource limit")
    return json.loads(encoded.decode("utf-8-sig"))


def header_fields(header):
    if not isinstance(header, dict):
        raise ValueError("Unexpected public download header")
    count = header.get("totalCount")
    transport = header.get("transport", "portal")
    if transport == "official-api":
        count = validate_api_header(header)
    elif transport == "portal":
        # The portal caps a public download at 50,000. At the cap itself, this
        # header cannot prove whether the source is complete or truncated.
        if isinstance(count, bool) or not isinstance(count, int) or not 0 < count < DOWNLOAD_ROW_LIMIT:
            raise ValueError("Unexpected public download row count")
    else:
        raise ValueError("Unknown national collection transport")
    table = header.get("tableVO") or {}
    if not isinstance(table, dict):
        raise ValueError("Unexpected public download table metadata")
    columns, name = table.get("colNmList"), table.get("svcTableNm")
    if (not isinstance(columns, list) or not 1 <= len(columns) <= 100
            or not all(isinstance(c, str) and c for c in columns)
            or not REQUIRED_COLUMNS.issubset(columns)):
        raise ValueError("Public download columns are missing")
    if name != SERVICE_TABLE:
        raise ValueError("Unexpected public download service table")
    return count, columns, name


def encode_snapshot(payload):
    encoded = (json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")
    if len(encoded) > MAXIMUM_BYTES:
        raise ValueError("Snapshot exceeds the catalog resource limit")
    return encoded


def stage_snapshot(path, encoded):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    return temporary


def publish_snapshot(snapshot_path, header_path, encoded, header):
    # Prepare both files before touching either previous artifact. Publish the
    # proof first and the data last: an interrupted pair fails hash verification.
    staged = []
    try:
        snapshot_temp = stage_snapshot(snapshot_path, encoded)
        staged.append(snapshot_temp)
        header_temp = stage_snapshot(header_path, encode_snapshot(header))
        staged.append(header_temp)
        header_temp.replace(header_path)
        snapshot_temp.replace(snapshot_path)
    finally:
        for temporary in staged:
            temporary.unlink(missing_ok=True)


def collect_portal(timeout, fetch=get_json):
    header = fetch(HEADER_URL, timeout)
    count, columns, table = header_fields(header)
    page_size = 10_000
    rows = []
    page_digests = set()
    received_bytes = 0
    for page in range(1, math.ceil(count / page_size) + 1):
        query = [("publicDataPk", "15139207"), ("svcTableNm", table),
                 ("totalCount", count), ("perPage", page_size), ("page", page)]
        query.extend(("colNmList", column) for column in columns)
        batch = fetch(DATA_URL + "?" + urlencode(query), timeout)
        expected = min(page_size, count - len(rows))
        if not isinstance(batch, list) or len(batch) != expected or not all(isinstance(row, dict) for row in batch):
            raise ValueError(f"Incomplete public download page {page}: expected {expected} rows")
        canonical_page = json.dumps(batch, sort_keys=True, ensure_ascii=False).encode("utf-8")
        received_bytes += len(canonical_page)
        if received_bytes > MAXIMUM_BYTES:
            raise ValueError("Public download exceeds the catalog collection limit")
        digest = page_fingerprint(batch)
        if digest in page_digests:
            raise ValueError("Public download repeated a page")
        page_digests.add(digest)
        rows.extend(batch)
    if header_fields(fetch(HEADER_URL, timeout)) != (count, columns, table):
        raise ValueError("Public source changed during download; retry the snapshot")
    header["transport"] = "portal"
    return rows, header


def prepare_snapshot(rows, header):
    count, _, _ = header_fields(header)
    if len(rows) != count:
        raise ValueError("National row count does not match the collection header")
    encoded = encode_snapshot(rows)
    proof = {"schemaVersion": 1, "sourceID": SOURCE_ID,
             "capturedAt": datetime.now(timezone.utc).isoformat(), "rowCount": len(rows),
             "byteCount": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest(),
             "transport": header["transport"]}
    if header["transport"] == "official-api":
        proof.update({"endpoint": API_URL, "pageCount": header["apiCollection"]["pageCount"],
                      "pageSize": header["apiCollection"]["pageSize"],
                      "duplicateRowCount": header["apiCollection"]["duplicateRowCount"],
                      "crossPageDuplicateRowCount": header["apiCollection"]["crossPageDuplicateRowCount"],
                      "coverage": "reported-api-rows",
                      "snapshotIsolation": "not-provided-by-source"})
    header["collectionProof"] = proof
    return encoded, header


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--header-output", type=Path, required=True)
    parser.add_argument("--transport", choices=("api", "portal"), default="api",
                        help="Official API by default; portal is an explicit public-download fallback")
    parser.add_argument("--service-key-file", type=Path,
                        help="Private ASCII file containing the API key; otherwise DATA_GO_KR_SERVICE_KEY")
    parser.add_argument("--page-size", type=int, default=MAXIMUM_PAGE_SIZE,
                        help="Official API rows per page (1-1000; default: 1000)")
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    if not 1 <= args.page_size <= MAXIMUM_PAGE_SIZE:
        parser.error("--page-size must be between 1 and 1000")
    output_paths = {args.output.resolve(), args.header_output.resolve()}
    if len(output_paths) != 2:
        parser.error("Snapshot and header need distinct output paths")
    if args.service_key_file is not None:
        if args.transport == "portal":
            parser.error("--service-key-file is only used by the official API transport")
        if args.service_key_file.resolve() in output_paths:
            parser.error("Output paths must not overwrite the service-key file")
    try:
        if args.transport == "api":
            key = load_service_key(args.service_key_file)
            rows, header = collect_official_api(key, args.timeout, args.page_size)
        else:
            rows, header = collect_portal(args.timeout)
        encoded, header = prepare_snapshot(rows, header)
        publish_snapshot(args.output, args.header_output, encoded, header)
    except CollectionError as error:
        parser.exit(1, f"Collection failed: {error}\n")
    proof = header["collectionProof"]
    print(json.dumps(proof, ensure_ascii=False))


if __name__ == "__main__":
    main()
