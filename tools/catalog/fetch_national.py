#!/usr/bin/env python3
"""Download public dataset 15139207 through data.go.kr's JSON download endpoint.

No server or API key is required for this public file-download route. The portal
may change this route; incomplete downloads fail without replacing the snapshot.
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
    # The portal caps a public download at 50,000. At the cap itself, this header
    # cannot prove whether the source is complete or truncated.
    if isinstance(count, bool) or not isinstance(count, int) or not 0 < count < DOWNLOAD_ROW_LIMIT:
        raise ValueError("Unexpected public download row count")
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


def page_fingerprint(rows):
    # Preserve duplicate multiplicity while ignoring the server's row order.
    row_hashes = sorted(hashlib.sha256(json.dumps(row, sort_keys=True, ensure_ascii=False,
        separators=(",", ":"), allow_nan=False).encode("utf-8")).hexdigest() for row in rows)
    return hashlib.sha256("\n".join(row_hashes).encode("ascii")).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--header-output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    if args.output.resolve() == args.header_output.resolve():
        parser.error("Snapshot and header need distinct output paths")

    header = get_json(HEADER_URL, args.timeout)
    count, columns, table = header_fields(header)
    page_size = 10_000
    rows = []
    page_digests = set()
    received_bytes = 0
    for page in range(1, math.ceil(count / page_size) + 1):
        query = [("publicDataPk", "15139207"), ("svcTableNm", table),
                 ("totalCount", count), ("perPage", page_size), ("page", page)]
        query.extend(("colNmList", column) for column in columns)
        batch = get_json(DATA_URL + "?" + urlencode(query), args.timeout)
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
    if header_fields(get_json(HEADER_URL, args.timeout)) != (count, columns, table):
        raise ValueError("Public source changed during download; retry the snapshot")
    encoded = encode_snapshot(rows)
    proof = {"schemaVersion": 1, "sourceID": SOURCE_ID,
             "capturedAt": datetime.now(timezone.utc).isoformat(), "rowCount": len(rows),
             "byteCount": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest()}
    header["collectionProof"] = proof
    publish_snapshot(args.output, args.header_output, encoded, header)
    print(json.dumps(proof, ensure_ascii=False))


if __name__ == "__main__":
    main()
