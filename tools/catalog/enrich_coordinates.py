#!/usr/bin/env python3
"""Create an attributed coordinate supplement from public park data or VWorld.

Default operation is offline exact-name/address matching. Explicit --geocode
uses the VWorld key in VWORLD_API_KEY; health data and user GPS are never inputs.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from catalog_coordinates import (PARK_SOURCE, apply_supplements, canonical, capture_date, has_conflict,
    match_park_coordinates, point, retain_previous_entries)
from normalize import validate_pack


ENDPOINT = "https://api.vworld.kr/req/address"
SOURCE_URL = "https://www.vworld.kr/dev/v4dv_geocoderguide2_s001.do"
MAX_BYTES = 60 * 1024 * 1024


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # API keys must not follow redirects, including error/login redirects.
        return None


def load_bytes(path):
    with path.open("rb") as handle:
        data = handle.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("Input exceeds resource limit")
    return data


def load_json(path):
    return json.loads(load_bytes(path))


def park_source_metadata(raw, registry):
    """Use the verified source capture, never the date a saved file is converted."""
    digest = hashlib.sha256(raw).hexdigest()
    sources = registry.get("sources") if isinstance(registry, dict) else None
    if not isinstance(sources, list):
        raise ValueError("Parks require a source registry with capture and SHA-256 evidence")
    matching = [source for source in sources if isinstance(source, dict)
                and source.get("sourceURL") == PARK_SOURCE and source.get("sha256") == digest]
    if len(matching) != 1:
        raise ValueError("Parks input does not uniquely match the official source registry SHA-256")
    source = matching[0]
    capture_date(source.get("capturedAt"))
    rows = json.loads(raw)
    rows = rows.get("records") if isinstance(rows, dict) else rows
    if (not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows)
            or type(source.get("rowCount")) is not int or source["rowCount"] != len(rows)):
        raise ValueError("Parks rows do not match their source collection evidence")
    return rows, source["capturedAt"], digest


def address_type(address):
    # Require a full province + numeric building/lot address. Facility-only names
    # and partial district matches must never produce automatic coordinates.
    if len(address.split()) < 3 or not re.search(r"\d", address):
        return None
    if re.search(r"(?:로|길)\s+\d", address):
        return "ROAD"
    if re.search(r"(?:읍|면|동|리|가)\s+(?:산\s*)?\d", address):
        return "PARCEL"
    return None


def parse_vworld(payload, address, requested_type):
    if not isinstance(payload, dict) or not isinstance(payload.get("response"), dict):
        raise ValueError("Unexpected VWorld response")
    response = payload["response"]
    if response.get("status") == "NOT_FOUND":
        return None
    if response.get("status") != "OK":
        raise ValueError("VWorld rejected request; check key, approved domain and quota")
    given = response.get("input") or {}
    refined = response.get("refined") or {}
    result = response.get("result") or {}
    if not all(isinstance(x, dict) for x in [given, refined, result]):
        raise ValueError("Unexpected VWorld address schema")
    if not isinstance(given.get("address"), str) or not isinstance(refined.get("text"), str):
        raise ValueError("VWorld did not provide address confirmation")
    if (str(given.get("type", "")).upper() != requested_type
            or canonical(given.get("address")) != canonical(address)
            or canonical(refined.get("text")) != canonical(address)):
        return None
    if str(result.get("crs", "")).upper() != "EPSG:4326":
        raise ValueError("VWorld returned an unexpected coordinate reference system")
    coordinates = result.get("point") or {}
    if not isinstance(coordinates, dict):
        raise ValueError("VWorld coordinates are missing")
    location = point(coordinates.get("y"), coordinates.get("x"))
    # This adapter is for South Korean public facility addresses only.
    if location is None or not (32 <= location[0] <= 39.5 and 124 <= location[1] <= 132):
        raise ValueError("VWorld returned invalid Korean address coordinates")
    return location


def geocode(address, kind, key, domain, timeout):
    query = {"service": "address", "request": "getcoord", "version": "2.0",
        "format": "json", "errorFormat": "json", "crs": "EPSG:4326", "type": kind,
        "address": address, "refine": "true", "simple": "false", "key": key}
    if domain:
        query["domain"] = domain
    try:
        request = Request(ENDPOINT + "?" + urlencode(query), headers={"Accept": "application/json"})
        with build_opener(NoRedirect()).open(request, timeout=timeout) as response:
            data = response.read(1024 * 1024 + 1)
            if len(data) > 1024 * 1024:
                raise ValueError("Geocoder response exceeds resource limit")
        payload = json.loads(data)
    except Exception:
        # Never format urllib exceptions: they can contain the key-bearing URL.
        raise ValueError("VWorld request failed; existing supplement has not been replaced") from None
    return parse_vworld(payload, address, kind)


def atomic_json(path, value):
    data = (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode()
    if len(data) > MAX_BYTES:
        raise ValueError("Output exceeds resource limit")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Normalized schema-1 catalog")
    parser.add_argument("--parks", type=Path, help="Official 15012890 raw JSON records")
    parser.add_argument("--parks-registry", type=Path,
                        default=Path(__file__).with_name("regional-sources.json"),
                        help="Registry proving the park file's original capture date, row count and SHA-256")
    parser.add_argument("--previous", type=Path, help="Retain still-applicable evidence; no repeat geocoding")
    parser.add_argument("--geocode", action="store_true")
    parser.add_argument("--key-env", default="VWORLD_API_KEY")
    parser.add_argument("--domain", default="", help="The domain registered for this VWorld key, when required")
    parser.add_argument("--max-requests", type=int, default=100)
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if (not 1 <= args.max_requests <= 250_000 or not math.isfinite(args.interval) or args.interval < 0.1
            or not math.isfinite(args.timeout) or args.timeout <= 0):
        parser.error("Request limit, interval or timeout is invalid")
    inputs = {p.resolve() for p in [args.input, args.parks, args.previous,
                                  args.parks_registry if args.parks else None] if p}
    if args.output.resolve() == args.report.resolve() or args.output.resolve() in inputs or args.report.resolve() in inputs:
        parser.error("Outputs must be distinct from inputs and each other")
    key = os.environ.get(args.key_env, "").strip() if args.geocode else ""
    if args.geocode and not key:
        parser.error("Geocoding requires the configured key environment variable")
    pack = load_json(args.input)
    validate_pack(pack)
    captured_at = datetime.now(timezone.utc).isoformat()
    entries = []
    if args.previous:
        previous = load_json(args.previous)
        entries = retain_previous_entries(pack, previous)
    supplemented, _ = apply_supplements(pack, {"schemaVersion": 1, "entries": entries})
    park_capture = park_digest = None
    rejected_park_entries = 0
    if args.parks:
        rows, park_capture, park_digest = park_source_metadata(load_bytes(args.parks), load_json(args.parks_registry))
        candidates = match_park_coordinates(supplemented["places"], rows, park_capture)
        accepted = retain_previous_entries(supplemented, {"schemaVersion": 1, "entries": candidates})
        rejected_park_entries = len(candidates) - len(accepted)
        entries.extend(accepted)
    supplemented, _ = apply_supplements(pack, {"schemaVersion": 1, "entries": entries})
    requests = 0
    outcomes = Counter()
    if rejected_park_entries:
        outcomes["staleOrMismatchedParkEvidence"] = rejected_park_entries
    cached = {}
    if args.geocode:
        for place in supplemented["places"]:
            if place.get("latitude") is not None or has_conflict(place):
                continue
            address = place["address"]
            kind = address_type(address)
            if kind is None:
                outcomes["incompleteAddress"] += 1
                continue
            cache_key = (kind, canonical(address))
            if cache_key not in cached:
                if requests >= args.max_requests:
                    outcomes["requestLimit"] += 1
                    continue
                if requests:
                    time.sleep(args.interval)
                cached[cache_key] = geocode(address, kind, key, args.domain, args.timeout)
                requests += 1
            location = cached[cache_key]
            if location is None:
                outcomes["notFoundOrAddressMismatch"] += 1
                continue
            entries.append({"placeID": place["id"], "latitude": location[0], "longitude": location[1],
                "quality": "address", "sourceURL": SOURCE_URL, "method": "vworld-exact-address",
                "capturedAt": captured_at, "matchedAddress": address, "matchedName": place["name"]})
    document = {"schemaVersion": 1, "entries": entries}
    updated, counts = apply_supplements(pack, document)
    validate_pack(updated)
    missing = Counter(p["regionName"] for p in updated["places"] if p.get("latitude") is None)
    report = {"generatedAt": captured_at, "parkSourceCapturedAt": park_capture,
        "parkSourceSHA256": park_digest, "applied": counts.get("applied", 0), "requests": requests,
        "missingCoordinateCount": sum(missing.values()), "missingByRegion": dict(sorted(missing.items())),
        "outcomes": dict(outcomes), "application": counts,
        "addressCoordinatesAreEquipmentLocations": False}
    atomic_json(args.output, document)
    atomic_json(args.report, report)
    print(json.dumps({"entries": len(entries), "remaining": sum(missing.values()), "requests": requests}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        # Data validation messages and local file failures contain no requested URLs.
        raise SystemExit(str(error)) from None
