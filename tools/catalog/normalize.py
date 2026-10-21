#!/usr/bin/env python3
"""Create schema-1 catalog JSON from public parks and outdoor-equipment data.

This program performs no HTTP requests, geocoding, or publication. Missing or
conflicting coordinates remain missing.
"""
import argparse
import csv
import hashlib
import io
import json
import math
import re
from collections import Counter, defaultdict
from datetime import date, datetime
from pathlib import Path
from urllib.parse import urlsplit


MAXIMUM_BYTES = 60 * 1024 * 1024
MAXIMUM_PLACES = 250_000
NATIONAL_SOURCE_ID = "data-go-kr:15139207"
NATIONAL_SOURCE_URL = "https://www.data.go.kr/data/15139207/standard.do"
NATIONAL_ID_PREFIX = "national-equipment-"


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


NATIONAL_ID_FIELDS = ("CTPV_NM", "SGG_NM", "INSTL_PLC_NM",
                      "LCTN_ROAD_NM_ADDR", "LCTN_LOTNO_ADDR")
NATIONAL_REQUIRED_COLUMNS = set(NATIONAL_ID_FIELDS) | {
    "LAT", "LOT", "SPRTGD_NM", "SPRTGD_QTY", "DATA_CRTR_YMD", "MNG_INST_NM"
}
NATIONAL_ALIASES = {
    "INSTL_PLC_NM": "설치장소명", "CTPV_NM": "시도명", "SGG_NM": "시군구명",
    "LCTN_ROAD_NM_ADDR": "소재지도로명주소", "LCTN_LOTNO_ADDR": "소재지지번주소",
    "LAT": "위도", "LOT": "경도", "SPRTGD_NM": "운동기구명", "SPRTGD_QTY": "운동기구수량",
    "MNG_INST_NM": "관리기관명", "MNG_INST_TELNO": "관리기관전화번호",
    "DATA_CRTR_YMD": "데이터기준일자", "INSTT_CODE": "제공기관코드", "INSTT_NM": "제공기관명"
}


def national_rows(source):
    aliases = {alias: key for key, alias in NATIONAL_ALIASES.items()}
    has_fields = isinstance(source, dict) and "fields" in source
    if isinstance(source, dict):
        if "sourceID" in source and source["sourceID"] != NATIONAL_SOURCE_ID:
            raise ValueError("National source ID does not match")
        rows = source.get("records")
    else:
        rows = source
    if not isinstance(rows, list) or not rows or len(rows) > MAXIMUM_PLACES:
        raise ValueError("National input must contain between 1 and 250000 rows")
    canonical_rows, observed = [], set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("National records must be objects")
        canonical = dict(row)
        for key, alias in NATIONAL_ALIASES.items():
            if key not in canonical and alias in row:
                canonical[key] = row[alias]
        observed.update(canonical)
        canonical_rows.append(canonical)
    if has_fields:
        fields = source["fields"]
        if not isinstance(fields, list) or not 1 <= len(fields) <= 100:
            raise ValueError("National fields must be a nonempty column list")
        columns = set()
        for field in fields:
            name = field.get("id") if isinstance(field, dict) else field
            if not isinstance(name, str) or not name:
                raise ValueError("National field names must be strings")
            columns.add(aliases.get(name, name))
    else:
        columns = observed
    if not NATIONAL_REQUIRED_COLUMNS.issubset(columns):
        raise ValueError("Input columns do not identify the national equipment dataset")
    return canonical_rows


def national_text(row, key):
    value = row.get(key)
    if value is None:
        return ""
    if not isinstance(value, (str, int, float)) or isinstance(value, bool):
        raise ValueError(f"National source field {key} must be a scalar")
    return str(value).strip()


def national_digest(parts, length=24):
    return hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()[:length]


def from_national(rows, config):
    """Group installation-place rows without treating row counts as places.

    The source has no facility ID. Text fields are trimmed, but internal spaces,
    spelling and both addresses are retained in the identity. Coordinates,
    equipment, dates and providers are deliberately excluded from that identity.
    A row quantity belongs to the complete source label, including compound
    labels. Repeated labels and every multi-row place have unknown totals because
    this source cannot distinguish duplicate reporting from multiple machines.
    """
    rows = national_rows(rows)
    groups = defaultdict(list)
    for index, row in enumerate(rows, start=1):
        identity = tuple(national_text(row, key) for key in NATIONAL_ID_FIELDS)
        if not all(identity[:3]):
            raise ValueError(f"National row {index}: region and installation name required")
        if any("\x1f" in part for part in identity):
            raise ValueError(f"National row {index}: identity contains a reserved separator")
        groups[identity].append(row)

    places = []
    for identity, source_rows in groups.items():
        province, municipality, name, road_address, lot_address = identity
        digest = national_digest(identity)
        coordinates = {coordinate_pair(national_text(row, "LAT"), national_text(row, "LOT"))
                       for row in source_rows}
        coordinates.discard((None, None))
        latitude, longitude = next(iter(coordinates)) if len(coordinates) == 1 else (None, None)
        labels = defaultdict(list)
        quantities = []
        for row in source_rows:
            label = national_text(row, "SPRTGD_NM")
            raw_quantity = national_text(row, "SPRTGD_QTY")
            quantity = integer(raw_quantity) if raw_quantity.isascii() else None
            if label and quantity is not None and quantity > 100_000:
                raise ValueError("National equipment quantity exceeds the app's item limit")
            quantities.append(quantity)
            if label:
                labels[label].append(quantity)
        equipment = [{"name": label, "count": counts[0] if len(counts) == 1 else None}
                     for label, counts in sorted(labels.items())]
        total = quantities[0] if len(source_rows) == 1 else None
        dates = sorted({national_text(row, "DATA_CRTR_YMD") for row in source_rows
                        if national_text(row, "DATA_CRTR_YMD")})
        providers = sorted({national_text(row, "INSTT_NM") for row in source_rows
                            if national_text(row, "INSTT_NM")})
        departments = sorted({national_text(row, "MNG_INST_NM") for row in source_rows
                              if national_text(row, "MNG_INST_NM")})
        provenance = base_provenance(config, f"설치장소 합성 ID {digest} · 원본 {len(source_rows)}행")
        provenance["provider"] = " · ".join(providers) or config["provider"]
        provenance["referenceDate"] = dates[0] if len(dates) == 1 else None
        notes = [config.get("note") or "",
                 "원자료에 고유 장소 ID가 없어 시도·시군구·설치장소명·도로명주소·지번주소로 합성 ID를 생성했습니다. 주소나 명칭이 바뀌면 ID도 바뀔 수 있습니다.",
                 "기구명은 복합 목록을 포함한 원문이며 행 수량을 개별 기구별로 나누지 않았습니다."]
        if len(source_rows) > 1:
            notes.append("여러 원본 행을 묶은 장소입니다. 중복 보고와 개별 기구 행을 구별할 수 없어 총수량을 합산하지 않았습니다.")
        if any(len(counts) > 1 for counts in labels.values()):
            notes.append("같은 기구명이 반복된 행은 표시를 합치고 해당 기구 수량을 미확인으로 남겼습니다.")
        if len(coordinates) > 1:
            notes.append("같은 설치장소의 원본 좌표가 서로 달라 대표 좌표를 선택하지 않았습니다.")
        if len(dates) > 1:
            notes.append("원본 행의 자료 기준일이 서로 달라 단일 기준일을 표시하지 않았습니다.")
        provenance["note"] = " ".join(note for note in notes if note)
        places.append({"id": config["idPrefix"] + digest, "name": name,
            "address": road_address or lot_address,
            "regionCode": "national-region-" + national_digest(identity[:2], 16),
            "regionName": f"{province} {municipality}", "locality": None,
            "latitude": latitude, "longitude": longitude,
            "coordinateQuality": "facility" if latitude is not None else "unknown",
            "equipment": equipment, "equipmentCount": total,
            "equipmentInformationKnown": bool(equipment) or any(q is not None for q in quantities),
            "facilityTypes": [], "managingDepartment": " · ".join(departments) or None,
            "provenance": provenance})
    return sorted(places, key=lambda place: place["id"])


def source_summary(config, row_count, places, complete=False):
    summary = {"id": config["sourceID"], "capturedAt": config["capturedAt"],
            "rowCount": row_count, "placeCount": len(places),
            "missingCoordinateCount": sum(place["latitude"] is None for place in places),
            "regions": sorted({place["regionName"] for place in places})}
    if complete:
        summary["completeCapturedAt"] = config["capturedAt"]
    return summary


def valid_capture_date(value):
    if not isinstance(value, str):
        return False
    try:
        if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
            date.fromisoformat(value)
            return True
        if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
                        r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})", value):
            return datetime.fromisoformat(value.replace("Z", "+00:00")).tzinfo is not None
    except ValueError:
        pass
    return False


def collection_proof(header, raw_bytes):
    from fetch_national import header_fields
    count, _, _ = header_fields(header)
    proof = header.get("collectionProof")
    if (not isinstance(proof, dict) or type(proof.get("schemaVersion")) is not int
            or proof["schemaVersion"] != 1 or proof.get("sourceID") != NATIONAL_SOURCE_ID
            or type(proof.get("rowCount")) is not int or proof["rowCount"] != count
            or type(proof.get("byteCount")) is not int or proof["byteCount"] != len(raw_bytes)
            or not isinstance(proof.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", proof["sha256"])
            or proof["sha256"] != hashlib.sha256(raw_bytes).hexdigest()
            or not valid_capture_date(proof.get("capturedAt"))):
        raise ValueError("National collection proof does not match the input bytes and header")
    return proof


def require_text(value, field, maximum=None, nonempty=False):
    # Code-point counts are conservative for Swift's grapheme-count limits.
    if (not isinstance(value, str) or (nonempty and not value)
            or (maximum is not None and len(value) > maximum)):
        raise ValueError(f"Invalid catalog text: {field}")


def require_integer(value, field, maximum, minimum=0, optional=False):
    if optional and value is None:
        return
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"Invalid catalog integer: {field}")


def require_array(value, field, maximum):
    if not isinstance(value, list) or len(value) > maximum:
        raise ValueError(f"Invalid catalog collection: {field}")


def require_https(value):
    require_text(value, "sourceURL", nonempty=True)
    url = urlsplit(value)
    if (url.scheme != "https" or not url.hostname or url.username is not None
            or url.password is not None or "#" in value):
        raise ValueError("Source URL must be public HTTPS without credentials or a fragment")


def validate_pack(pack):
    validated_capture_dates = set()

    def require_capture_date(value):
        if not isinstance(value, str):
            raise ValueError("Invalid source capture timestamp")
        if value not in validated_capture_dates:
            if not valid_capture_date(value):
                raise ValueError("Invalid source capture timestamp")
            validated_capture_dates.add(value)

    if type(pack.get("schemaVersion")) is not int or pack["schemaVersion"] != 1:
        raise ValueError("Unsupported catalog schema")
    require_integer(pack.get("version"), "version", 2**63 - 1, minimum=1)
    require_text(pack.get("generatedAt"), "generatedAt", nonempty=True)
    places = pack.get("places")
    require_array(places, "places", MAXIMUM_PLACES)
    ids, national_places = set(), []
    for place in places:
        if not isinstance(place, dict):
            raise ValueError("Catalog places must be objects")
        for field, limit in [("id", 200), ("name", 500), ("regionCode", 100), ("regionName", 200)]:
            require_text(place.get(field), field, limit, nonempty=True)
        if not place["name"].strip() or place["id"] in ids:
            raise ValueError("Duplicate place ID or blank place name")
        ids.add(place["id"])
        require_text(place.get("address"), "address", 1000)
        for field in ["locality", "managingDepartment"]:
            if place.get(field) is not None:
                require_text(place[field], field)
        equipment = place.get("equipment")
        require_array(equipment, "equipment", 1000)
        for item in equipment:
            if not isinstance(item, dict):
                raise ValueError("Equipment items must be objects")
            require_text(item.get("name"), "equipment.name", 500, nonempty=True)
            require_integer(item.get("count"), "equipment.count", 100_000, optional=True)
        require_integer(place.get("equipmentCount"), "equipmentCount", 1_000_000, optional=True)
        facility_types = place.get("facilityTypes")
        require_array(facility_types, "facilityTypes", 100)
        for name in facility_types:
            require_text(name, "facilityTypes.name", 500)
        if type(place.get("equipmentInformationKnown")) is not bool:
            raise ValueError("equipmentInformationKnown must be a boolean")
        quality = place.get("coordinateQuality")
        if quality not in ["equipment", "facility", "park", "unknown"]:
            raise ValueError("Invalid coordinate quality")
        latitude, longitude = place.get("latitude"), place.get("longitude")
        if latitude is None and longitude is None:
            if quality != "unknown":
                raise ValueError("Missing coordinates require unknown quality")
        elif (type(latitude) not in [int, float] or type(longitude) not in [int, float]
              or coordinate_pair(latitude, longitude) == (None, None) or quality == "unknown"):
            raise ValueError("Invalid coordinate pair")
        provenance = place.get("provenance")
        if not isinstance(provenance, dict):
            raise ValueError("Place provenance must be an object")
        for field in ["provider", "datasetTitle", "sourceRecordID", "capturedAt", "license"]:
            require_text(provenance.get(field), "provenance." + field, nonempty=True)
        require_https(provenance.get("sourceURL"))
        for field in ["referenceDate", "note"]:
            if provenance.get(field) is not None:
                require_text(provenance[field], "provenance." + field)
        if place["id"].startswith(NATIONAL_ID_PREFIX) and provenance["sourceURL"] == NATIONAL_SOURCE_URL:
            require_capture_date(provenance["capturedAt"])
            national_places.append(place)

    sources = pack.get("sources")
    sources = [] if sources is None else sources
    require_array(sources, "sources", 100)
    source_ids = set()
    for source in sources:
        if not isinstance(source, dict):
            raise ValueError("Source summaries must be objects")
        for field in ["id", "capturedAt"]:
            require_text(source.get(field), "source." + field, nonempty=True)
        if source["id"] in source_ids:
            raise ValueError("Duplicate source summary IDs")
        source_ids.add(source["id"])
        require_integer(source.get("rowCount"), "source.rowCount", MAXIMUM_PLACES)
        require_integer(source.get("placeCount"), "source.placeCount", MAXIMUM_PLACES)
        require_integer(source.get("missingCoordinateCount"), "source.missingCoordinateCount", source["placeCount"])
        regions = source.get("regions")
        require_array(regions, "source.regions", 1000)
        for region in regions:
            require_text(region, "source.region", 200, nonempty=True)
        for field in ["completeCapturedAt", "partialCapturedAt"]:
            if source.get(field) is not None:
                require_capture_date(source[field])
        if source["id"] == NATIONAL_SOURCE_ID:
            require_capture_date(source["capturedAt"])
            if (source["rowCount"] <= 0 or source["placeCount"] <= 0
                    or source["placeCount"] != len(national_places)
                    or source["missingCoordinateCount"] != sum(p["latitude"] is None for p in national_places)
                    or set(regions) != {p["regionName"] for p in national_places}):
                raise ValueError("National source summary does not match its places")
    if national_places and NATIONAL_SOURCE_ID not in source_ids:
        raise ValueError("National places require their source summary")


def validate_config(config):
    for key in ["provider", "datasetTitle", "sourceURL", "capturedAt", "license", "idPrefix"]:
        require_text(config.get(key), key, nonempty=True)
    require_https(config["sourceURL"])
    if config.get("coordinateQuality", "facility") not in ["equipment", "facility", "park"]:
        raise ValueError("coordinateQuality must describe the source, not an assumed GPS precision")


def validate_namespace(config, source_format):
    if source_format == "national":
        expected = {"sourceID": NATIONAL_SOURCE_ID, "sourceURL": NATIONAL_SOURCE_URL,
                    "idPrefix": NATIONAL_ID_PREFIX}
        if any(config.get(key) != value for key, value in expected.items()):
            raise ValueError("National config must use the official source ID, URL and place prefix")
    elif (config.get("sourceID") == NATIONAL_SOURCE_ID or config["sourceURL"] == NATIONAL_SOURCE_URL
          or config["idPrefix"].startswith(NATIONAL_ID_PREFIX)):
        raise ValueError("The national source namespace is reserved for --format national")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=["parks", "csv", "national"], required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--captured-at", help="Override the source capture timestamp after a new download")
    parser.add_argument("--national-header", type=Path,
                        help="Header with collection proof; verifies input bytes, row count and capture time before marking it complete")
    parser.add_argument("--encoding", default="utf-8-sig")
    parser.add_argument("--version", type=int, required=True, help="Monotonically increasing positive integer")
    parser.add_argument("--generated-at", required=True, help="ISO-8601 provenance timestamp")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--merge", type=Path, action="append", default=[], help="Other normalized packs to include")
    args = parser.parse_args()
    if args.version <= 0:
        parser.error("--version must be positive")
    if args.national_header and args.format != "national":
        parser.error("--national-header applies only to --format national")
    config = json.loads(args.config.read_text(encoding="utf-8"))
    if args.captured_at is not None:
        config["capturedAt"] = args.captured_at
    with args.input.open("rb") as handle:
        raw_bytes = handle.read(MAXIMUM_BYTES + 1)
    if len(raw_bytes) > MAXIMUM_BYTES:
        raise ValueError("Input exceeds the app's import resource limits")
    proof = None
    if args.national_header:
        header = json.loads(args.national_header.read_text(encoding="utf-8"))
        proof = collection_proof(header, raw_bytes)
        if args.captured_at is not None and args.captured_at != proof["capturedAt"]:
            raise ValueError("Capture timestamp override does not match the collection proof")
        config["capturedAt"] = proof["capturedAt"]
    validate_config(config)
    validate_namespace(config, args.format)
    raw = raw_bytes.decode(args.encoding)
    if args.format == "parks":
        source = json.loads(raw)
        places = from_parks(source, config)
        row_count = len(source["records"])
    elif args.format == "national":
        source = json.loads(raw)
        places = from_national(source, config)
        row_count = len(source["records"]) if isinstance(source, dict) else len(source)
        if proof is not None and row_count != proof["rowCount"]:
            raise ValueError("National source row count does not match its collection proof")
    else:
        places = from_csv(raw, config)
        row_count = len(places)
    summaries = [source_summary(config, row_count, places, complete=args.national_header is not None)] if config.get("sourceID") else []
    for path in args.merge:
        other = json.loads(path.read_text(encoding="utf-8"))
        if other["schemaVersion"] != 1:
            raise ValueError("Unsupported merge schema")
        places.extend(other["places"])
        summaries.extend(other.get("sources", []))
    if len({p["id"] for p in places}) != len(places):
        raise ValueError("Duplicate IDs: use unique idPrefix values for independent datasets")
    pack = {"schemaVersion": 1, "version": args.version, "generatedAt": args.generated_at, "places": places}
    if summaries:
        if len({source["id"] for source in summaries}) != len(summaries):
            raise ValueError("Duplicate source summary IDs")
        pack["sources"] = summaries
    validate_pack(pack)
    encoded = (json.dumps(pack, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")
    if len(encoded) > MAXIMUM_BYTES:
        raise ValueError("Catalog exceeds the app's import resource limits")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temp = args.output.with_suffix(args.output.suffix + ".tmp")
    temp.write_bytes(encoded)
    temp.replace(args.output)
    print(json.dumps({"places": len(places), "missingCoordinates": sum(p["latitude"] is None for p in places),
      "byteCount": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest()}, ensure_ascii=False))


if __name__ == "__main__":
    main()
