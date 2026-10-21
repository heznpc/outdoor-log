#!/usr/bin/env python3
"""Create schema-1 catalog JSON from public parks or mapped outdoor-equipment CSV.

This program performs no HTTP requests, geocoding, or publication. Missing
coordinates remain missing. The companion README describes fields and manifests.
"""
import argparse
import csv
import hashlib
import io
import json
import math
import re
from collections import Counter
from pathlib import Path


def coordinate_pair(latitude, longitude):
    try:
        lat, lon = float(latitude), float(longitude)
        if math.isfinite(lat) and math.isfinite(lon) and -90 <= lat <= 90 and -180 <= lon <= 180:
            return lat, lon
    except (TypeError, ValueError):
        pass
    return None, None


def integer(value):
    text = str(value or "").strip()
    return int(text) if text.isdigit() and 0 <= int(text) <= 1_000_000 else None


def equipment_items(value):
    """Parse only complete counted items; retain ambiguous compound text verbatim.

    >>> equipment_items("달리기(1) 윗몸일으키기(5)")
    [{'name': '달리기', 'count': 1}, {'name': '윗몸일으키기', 'count': 5}]
    >>> equipment_items("역기당기기+평행봉(2)")
    [{'name': '역기당기기+평행봉', 'count': 2}]
    >>> equipment_items("달리기(1)+가로타기(1)")
    [{'name': '달리기(1)+가로타기(1)', 'count': None}]
    >>> equipment_items("달리기(1) / 가로타기(1)")
    [{'name': '달리기(1) / 가로타기(1)', 'count': None}]
    >>> equipment_items("달리기(1) 윗몸일으키기")
    [{'name': '달리기(1) 윗몸일으키기', 'count': None}]
    >>> equipment_items("철봉(2개), 평행봉; 하늘걷기(3대)")
    [{'name': '철봉', 'count': 2}, {'name': '평행봉', 'count': None}, {'name': '하늘걷기', 'count': 3}]
    """
    items = []
    for raw in re.split(r"[,;\n]", value or ""):
        raw = raw.strip()
        if not raw:
            continue
        # A whitespace-separated list is safe only when every item has its own
        # count. '+' and '/' may describe combined machines or alternatives.
        parts = re.split(r"(?<=\))\s+", raw)
        matches = [re.fullmatch(r"([^()]+?)\s*\((\d+)\s*(?:개|대)?\)", part)
                   for part in parts]
        if all(matches) and (len(parts) == 1 or not any(mark in raw for mark in "+/")):
            items.extend({"name": match.group(1).strip(), "count": int(match.group(2))}
                         for match in matches)
        else:
            items.append({"name": raw, "count": None})
    return items


def base_provenance(config, row_id):
    return {"provider": config["provider"], "datasetTitle": config["datasetTitle"],
            "sourceURL": config["sourceURL"], "sourceRecordID": row_id,
            "referenceDate": config.get("referenceDate"), "capturedAt": config["capturedAt"],
            "license": config["license"], "note": config.get("note")}


def from_parks(source, config):
    rows = source["records"]
    region_code = config.get("regionCode") or source.get("regionCode")
    if not region_code or not config.get("regionName"):
        raise ValueError("Park input requires a region code and display name")
    places = []
    for row in rows:
        latitude, longitude = coordinate_pair(row.get("LATITUDE"), row.get("LONGITUDE"))
        record_id = row["MANAGE_NO"]
        provenance = base_provenance(config, record_id)
        provenance["referenceDate"] = row.get("REFERENCE_DATE") or config.get("referenceDate")
        places.append({"id": config["idPrefix"] + record_id, "name": row["PARK_NM"].strip(),
          "address": (row.get("RDNMADR") or row.get("LNMADR") or "").strip(),
          "regionCode": region_code, "regionName": config["regionName"],
          "locality": None, "latitude": latitude, "longitude": longitude,
          "coordinateQuality": "park" if latitude is not None else "unknown", "equipment": [],
          "equipmentCount": None, "equipmentInformationKnown": False,
          "facilityTypes": [x.strip() for x in (row.get("MVM_FCLTY") or "").split("+") if x.strip()],
          "managingDepartment": None, "provenance": provenance})
    return places


def from_csv(text, config):
    columns = config["columns"]
    rows = csv.DictReader(io.StringIO(text))
    required = [columns["name"], columns["address"]]
    if not set(required).issubset(rows.fieldnames or []):
        raise ValueError("CSV is missing the configured name/address columns")
    seen = Counter()
    places = []
    for index, row in enumerate(rows, start=2):
        def field(name):
            return (row.get(columns.get(name, "")) or "").strip()
        name, address = field("name"), field("address")
        if not name:
            raise ValueError(f"CSV row {index}: missing facility name")
        region_code = field("regionCode") or config.get("regionCode", "")
        region_name = field("regionName") or config.get("regionName", "")
        if not region_code or not region_name:
            raise ValueError(f"CSV row {index}: a region code and display name are required")
        latitude, longitude = coordinate_pair(field("latitude"), field("longitude"))
        identity = field("id") or hashlib.sha256("\x1f".join([name, address, region_code, field("locality")]).encode()).hexdigest()[:24]
        seen[identity] += 1
        suffix = "" if seen[identity] == 1 else f"-{seen[identity]}"
        equipment_raw = field("equipment")
        provenance = base_provenance(config, field("id") or f"CSV row {index}")
        provenance["referenceDate"] = field("referenceDate") or provenance["referenceDate"]
        places.append({"id": config["idPrefix"] + identity + suffix, "name": name,
          "address": address, "regionCode": region_code, "regionName": region_name,
          "locality": field("locality") or None, "latitude": latitude, "longitude": longitude,
          "coordinateQuality": config.get("coordinateQuality", "facility") if latitude is not None else "unknown",
          "equipment": equipment_items(equipment_raw), "equipmentCount": integer(field("equipmentCount")),
          "equipmentInformationKnown": bool(equipment_raw), "facilityTypes": [],
          "managingDepartment": field("managingDepartment") or None, "provenance": provenance})
    return places


def validate_config(config):
    for key in ["provider", "datasetTitle", "sourceURL", "capturedAt", "license", "idPrefix"]:
        if not config.get(key):
            raise ValueError(f"Missing provenance configuration: {key}")
    from urllib.parse import urlsplit
    url = urlsplit(config["sourceURL"])
    if url.scheme != "https" or not url.hostname or url.username or url.password:
        raise ValueError("Source URL must be public HTTPS")
    if config.get("coordinateQuality", "facility") not in ["equipment", "facility", "park"]:
        raise ValueError("coordinateQuality must describe the source, not an assumed GPS precision")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=["parks", "csv"], required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--encoding", default="utf-8-sig")
    parser.add_argument("--version", type=int, required=True, help="Monotonically increasing positive integer")
    parser.add_argument("--generated-at", required=True, help="ISO-8601 provenance timestamp")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--merge", type=Path, action="append", default=[], help="Other normalized packs to include")
    args = parser.parse_args()
    if args.version <= 0:
        parser.error("--version must be positive")
    config = json.loads(args.config.read_text(encoding="utf-8"))
    validate_config(config)
    raw = args.input.read_text(encoding=args.encoding)
    places = from_parks(json.loads(raw), config) if args.format == "parks" else from_csv(raw, config)
    for path in args.merge:
        other = json.loads(path.read_text(encoding="utf-8"))
        if other["schemaVersion"] != 1:
            raise ValueError("Unsupported merge schema")
        places.extend(other["places"])
    if len({p["id"] for p in places}) != len(places):
        raise ValueError("Duplicate IDs: use unique idPrefix values for independent datasets")
    pack = {"schemaVersion": 1, "version": args.version, "generatedAt": args.generated_at, "places": places}
    encoded = (json.dumps(pack, ensure_ascii=False, indent=2) + "\n").encode()
    if len(encoded) > 60 * 1024 * 1024 or len(places) > 250_000:
        raise ValueError("Catalog exceeds the app's import resource limits")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temp = args.output.with_suffix(args.output.suffix + ".tmp")
    temp.write_bytes(encoded)
    temp.replace(args.output)
    print(json.dumps({"places": len(places), "missingCoordinates": sum(p["latitude"] is None for p in places),
      "byteCount": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest()}, ensure_ascii=False))


if __name__ == "__main__":
    main()
