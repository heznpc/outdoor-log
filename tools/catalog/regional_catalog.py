#!/usr/bin/env python3
"""Prepare regional supplementary places from pinned official public files.

By default this reads pinned local files. --refresh reads the official public
download endpoints, stages and validates every input, then replaces the source
snapshots, registry and supplementary pack. It does not geocode, import project
code, or write the national catalog. The current snapshot was prepared
separately; this adapter has not been executed during 2026-10-26 source research.
Saved files are individually replaced atomically; this is not a filesystem-wide
transaction across the source snapshots, registry and output pack.
"""

from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import io
import json
import math
import os
import re
import tempfile
import unicodedata
import zipfile
from collections import defaultdict
from datetime import date
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen


REGIONS = {
    "29110": "광주광역시 동구", "29140": "광주광역시 서구",
    "29155": "광주광역시 남구", "29170": "광주광역시 북구",
    "29200": "광주광역시 광산구", "31110": "울산광역시 중구",
    "31140": "울산광역시 남구", "31170": "울산광역시 동구",
    "31200": "울산광역시 북구", "31710": "울산광역시 울주군",
    "36110": "세종특별자치시", "50110": "제주특별자치도 제주시",
    "50130": "제주특별자치도 서귀포시",
}


def identity(parts):
    return hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()[:24]


def normalized_address(value):
    return re.sub(r"\s+", "", value or "")


def coordinate_pair(latitude, longitude):
    """Accept published decimal coordinates only; never reinterpret or infer."""
    try:
        lat, lon = float(latitude), float(longitude)
    except (ValueError, TypeError):
        return None, None
    if not (math.isfinite(lat) and math.isfinite(lon)):
        return None, None
    if not (32 <= lat <= 40 and 124 <= lon <= 132):
        return None, None
    return lat, lon


def zip_member(raw, source, wanted=None):
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        wanted = wanted or source["zipMember"]
        members = []
        for entry in archive.infolist():
            name = entry.filename
            if not entry.flag_bits & 0x800:
                try:
                    name = name.encode("cp437").decode(source.get("zipFilenameEncoding", "cp949"))
                except (UnicodeEncodeError, UnicodeDecodeError):
                    pass
            if name == wanted or entry.filename == wanted:
                members.append(entry)
        if len(members) != 1:
            raise ValueError(f'{source["id"]}: expected one ZIP member {wanted!r}')
        return archive.read(members[0])


def read_rows(source, root, verify_proof=True):
    raw = (root / source["rawPath"]).read_bytes()
    proof = source["proof"]
    if verify_proof and hashlib.sha256(raw).hexdigest() != proof["sha256"]:
        raise ValueError(f'{source["id"]}: source SHA-256 differs from registry')
    if verify_proof and len(raw) != proof["byteCount"]:
        raise ValueError(f'{source["id"]}: source byte count differs from registry')
    fmt = source["format"]
    if fmt == "ZIP":
        raw = zip_member(raw, source)
        if verify_proof and hashlib.sha256(raw).hexdigest() != source["extractedCSVSha256"]:
            raise ValueError(f'{source["id"]}: extracted CSV SHA-256 differs')
        fmt = "CSV"
    if fmt == "CSV":
        reader = csv.DictReader(io.StringIO(raw.decode(source["encoding"])))
        if reader.fieldnames != source["columns"]:
            raise ValueError(f'{source["id"]}: CSV columns changed; review adapter')
        rows = list(reader)
    elif fmt == "JSON":
        rows = json.loads(raw.decode(source["encoding"]))
        if not isinstance(rows, list):
            raise ValueError(f'{source["id"]}: expected a JSON row array')
    else:
        raise ValueError(f'{source["id"]}: unsupported source format {fmt}')
    if verify_proof and len(rows) != proof["rowCount"]:
        raise ValueError(f'{source["id"]}: row count differs from registry')
    required = set(source["columns"])
    if any(not isinstance(row, dict) or not required.issubset(row) for row in rows):
        raise ValueError(f'{source["id"]}: missing registered source columns')
    return rows


def provenance(source, record, reference_date, note):
    return {
        "provider": source["provider"], "datasetTitle": source["datasetTitle"],
        "sourceURL": source["sourceURL"], "sourceRecordID": record,
        "referenceDate": reference_date, "capturedAt": source["capturedAt"],
        "license": source["license"], "note": note,
    }


def place(place_id, name, address, region, origin, lat=None, lon=None,
          quality="unknown", equipment=None, facility_types=None, department=None):
    equipment = equipment or []
    return {
        "id": place_id, "name": name.strip(), "address": address.strip(),
        "regionCode": region, "regionName": REGIONS[region], "locality": None,
        "latitude": lat, "longitude": lon, "coordinateQuality": quality,
        "equipment": equipment, "equipmentCount": None,
        "equipmentInformationKnown": bool(equipment),
        "facilityTypes": facility_types or [], "managingDepartment": department,
        "provenance": origin,
    }


def park_references(source, rows):
    pattern = re.compile(source["selection"]["equipmentEvidenceRegex"])
    prefixes = source["normalization"]["regions"]
    result = []
    for row in rows:
        if row["MANAGE_NO"][:2] not in prefixes or not pattern.search(row["MVM_FCLTY"]):
            continue
        equipment = [{"name": value.strip(), "count": None}
                     for value in re.split(r"[,+\n]", row["MVM_FCLTY"])
                     if re.search(source["selection"]["specificEquipmentRegex"], value)]
        note = (
            "공원 운동시설란에 기구 또는 체력단련시설이 명시된 공개자료입니다. "
            "기구명 원문을 보존하며 설치 대수와 현재 상태는 확정하지 않습니다. "
            "지도 좌표는 개별 기구 위치가 아닌 공원 대표 좌표입니다. "
            if equipment else
            "공원 운동시설란에 기구 또는 체력단련시설이 명시된 공개자료입니다. "
            "개별 기구 위치·종류·수량은 현장 확인되지 않았고 지도 좌표는 공원 대표 좌표입니다. "
        )
        origin = provenance(
            source, row["MANAGE_NO"], row["REFERENCE_DATE"],
            note + "원문 운동시설: " + row["MVM_FCLTY"],
        )
        origin["provider"] = row.get("INSTT_NM") or row["INSTITUTION_NM"]
        lat, lon = coordinate_pair(row["LATITUDE"], row["LONGITUDE"])
        item = place(
            "regional-park-" + row["MANAGE_NO"], row["PARK_NM"],
            row["RDNMADR"] or row["LNMADR"], row["MANAGE_NO"][:5], origin,
            lat, lon, "park" if lat is not None else "unknown",
            equipment=equipment, facility_types=[row["MVM_FCLTY"]],
        )
        item["supplementalEvidence"] = {
            "sourceRow": row,
            "classification": "park-equipment-listed" if equipment else "park-fitness-facility-reference",
        }
        result.append(item)
    return result


def jeju_survey(source, rows):
    groups = defaultdict(list)
    fields = source["uniqueIdentityFields"]
    for number, row in enumerate(rows, 2):
        groups[tuple(row[field] for field in fields)].append((number, row))
    result = []
    for key, group in groups.items():
        points = [coordinate_pair(row["위도"], row["경도"]) for _, row in group]
        all_valid = all(lat is not None for lat, _ in points)
        spread = None
        bounds = None
        if all_valid:
            lats, lons = [point[0] for point in points], [point[1] for point in points]
            dy = (max(lats) - min(lats)) * 111320
            dx = (max(lons) - min(lons)) * 111320 * math.cos(math.radians(lats[0]))
            spread = math.hypot(dx, dy)
            bounds = {"south": min(lats), "north": max(lats),
                      "west": min(lons), "east": max(lons)}
        valid = all_valid and spread <= source["normalization"]["maxCoordinateSpreadMeters"]
        labels = sorted({row["운동기구 종류"].strip() for _, row in group
                         if row["운동기구 종류"].strip()})
        note = (
            f'{source["referenceDate"][:4]}년 현장 조사 공개자료이며 현재 운영·고장·철거 여부는 미확인입니다. '
            "같은 관리번호·시설명·주소의 기구 행을 묶었습니다. 여러 실제 기구 좌표 중 "
            "원본 CSV의 첫 기구 좌표를 지도 대표 위치로 선택했으며 중심점이나 추정 좌표를 만들지 않았습니다. "
        )
        if spread is not None:
            note += f"원본 기구군 좌표범위 대각선 약 {round(spread)}m. "
        note += "복합 기구명과 반복 기록을 고려해 총수량은 확정하지 않았습니다."
        if not valid:
            note += " 좌표 누락·범위 오류 또는 분포가 1,000m를 초과하여 대표 좌표를 보류했습니다."
        origin = provenance(
            source, key[0] + " · CSV rows " + ",".join(str(n) for n, _ in group),
            source["referenceDate"], note,
        )
        item = place(
            "regional-jeju-" + source["id"].split(":")[-1] + "-" + identity(key),
            key[1], key[2], source["normalization"]["regionCode"], origin,
            points[0][0] if valid else None, points[0][1] if valid else None,
            "facility" if valid else "unknown",
            [{"name": label, "count": None} for label in labels],
            department=group[0][1]["관리부서"],
        )
        item["supplementalEvidence"] = {
            "classification": "equipment-survey", "identityFields": dict(zip(fields, key)),
            "sourceCSVRows": [number for number, _ in group],
            "coordinateSelection": "first-published-equipment-point",
            "representativeCSVRow": group[0][0], "coordinateBounds": bounds,
            "coordinateBoundsDiagonalMeters": round(spread, 3) if spread is not None else None,
        }
        result.append(item)
    groups_by_location = defaultdict(list)
    for item in result:
        key = tuple(re.sub(r"\s+", "", unicodedata.normalize("NFC", item[field]))
                    for field in ("name", "address"))
        groups_by_location[key].append(item)
    for group in groups_by_location.values():
        if len(group) > 1:
            for item in group:
                management_id = item["supplementalEvidence"]["identityFields"]["관리번호"]
                item["provenance"]["note"] += (
                    f" 같은 명칭·주소의 다른 관리번호 기록이 있으며 이 기록은 {management_id}입니다. "
                    "원본의 관리 단위를 보존해 별도로 표시하며 서로 독립된 공원임을 뜻하지 않습니다."
                )
                item["supplementalEvidence"]["coLocatedManagementRecords"] = [
                    other["supplementalEvidence"]["identityFields"]["관리번호"] for other in group
                ]
    return result


def gwangju_list(source, rows):
    spec = source["normalization"]
    pattern = re.compile(source["selection"]["equipmentEvidenceRegex"])
    result = []
    for number, row in enumerate(rows, 2):
        equipment_text = row[source["selection"]["equipmentColumn"]]
        if not pattern.search(equipment_text):
            continue
        name, address = row[spec["nameColumn"]], row[spec["addressColumn"]]
        origin = provenance(
            source, f"CSV row {number}", row[spec["referenceDateColumn"]],
            "공식 공공체육시설 자료의 기구·체력단련시설 명시 행입니다. 주소를 보존했으며 "
            "원본에 좌표가 없어 지도 좌표를 임의 생성하지 않았습니다. "
            "실제 개별 기구 수량과 현재 출입·운영 여부는 미확인입니다.",
        )
        item = place(
            "regional-gwangju-" + source["id"].split(":")[-1] + "-" + identity([name, address]),
            name, address, spec["regionCode"], origin,
            equipment=[{"name": equipment_text, "count": None}],
            department=row.get(spec.get("departmentColumn")),
        )
        item["supplementalEvidence"] = {
            "classification": "equipment-listed-facility", "sourceCSVRow": number,
            "equipmentText": equipment_text,
        }
        result.append(item)
    return result


def ulsan_list(source, rows, sources, all_rows):
    spec = source["normalization"]
    park_source = sources[spec["parentParkSourceID"]]
    parks = all_rows[park_source["id"]]
    quarantined = spec["coordinateConflictPlaceNames"]
    result = []
    for number, row in enumerate(rows, 2):
        name, address = row["시설명"], row["대상지주소"]
        lat, lon = coordinate_pair(row["위도"], row["경도"])
        quality = "facility" if lat is not None else "unknown"
        note = (
            "공식 야외운동기구 자료의 기구명 원문을 보존했습니다. 운동기구수(종)는 종류 수이므로 "
            "설치 대수로 사용하지 않습니다. 현재 고장·철거·교체 여부는 현장 확인되지 않았습니다."
        )
        evidence = None
        if name in quarantined:
            candidates = [park for park in parks
                          if park["PARK_NM"] == spec["parentParkName"]
                          and normalized_address(park["RDNMADR"]) == normalized_address(address)]
            lat = lon = None
            quality = "unknown"
            if len(candidates) == 1:
                park = candidates[0]
                lat, lon = coordinate_pair(park["LATITUDE"], park["LONGITUDE"])
                if lat is not None:
                    quality = "park"
                    evidence = {
                        "sourceURL": park_source["sourceURL"],
                        "method": "parent-park-address-match",
                        "capturedAt": park_source["capturedAt"],
                        "matchedAddress": address, "matchedName": name,
                        "sourceRecordID": park["MANAGE_NO"],
                        "parentParkName": spec["parentParkName"],
                    }
                    note += (
                        f' 원본 좌표 {row["위도"]}, {row["경도"]}는 동일한 부모 공원명·주소의 '
                        "공식 공원 대표좌표와 크게 충돌하여 사용하지 않았습니다. 하위 운동시설의 이름에서 "
                        "명시된 부모 공원명 울산체육공원과 동일 주소를 교차 확인했고 공원 대표좌표로 표시합니다."
                    )
            if quality == "unknown":
                note += " 공식 동일 장소 좌표와 충돌하여 원본 좌표 표시를 보류했습니다."
        region = next((code for token, code in spec["addressRegionCodes"].items()
                       if token in address), None)
        if region is None:
            raise ValueError(f'{source["id"]}: unknown administrative area in {address!r}')
        item = place(
            "regional-ulsan-15085196-" + identity([name, address]), name, address, region,
            provenance(source, f"CSV row {number}", row["기준일자"], note),
            lat, lon, quality,
            [{"name": part.strip(), "count": None} for part in row["운동기구명"].split(",")
             if part.strip()], department=row["관리기관"],
        )
        item["supplementalEvidence"] = {
            "classification": "equipment-listed-facility", "sourceCSVRow": number,
            "originalCoordinates": {"latitude": row["위도"], "longitude": row["경도"]},
            "originalEquipmentKindsCount": row["운동기구수(종)"],
        }
        if evidence:
            item["coordinateEvidence"] = evidence
        result.append(item)
    return result


def ulsan_sports_parks(source, rows):
    pattern = re.compile(source["selection"]["equipmentEvidenceRegex"])
    result = []
    for number, row in enumerate(rows, 2):
        if not pattern.search(row["주요시설"]):
            continue
        region = next((code for token, code in source["normalization"]["addressRegionCodes"].items()
                       if token in row["소재지"]), None)
        if region is None:
            raise ValueError(f'{source["id"]}: unknown administrative area')
        lat, lon = coordinate_pair(row["위도"], row["경도"])
        item = place(
            "regional-ulsan-15055528-" + identity([row["공원명"], row["소재지"]]),
            row["공원명"], row["소재지"], region,
            provenance(source, f"CSV row {number}", source["referenceDate"],
                       "생활체육공원 주요시설에 기구·체력단련시설이 명시된 자료입니다. "
                       "지도는 공원 대표좌표이며 개별 기구의 위치·종류·수량을 확정하지 않습니다. "
                       "원문 주요시설: " + row["주요시설"]),
            lat, lon, "park" if lat is not None else "unknown", facility_types=[row["주요시설"]],
        )
        item["supplementalEvidence"] = {
            "classification": "park-fitness-facility-reference", "sourceCSVRow": number,
        }
        result.append(item)
    return result


def attach_ulsan_inventory(source, rows, places):
    """Retain dated equipment counts as evidence for the same four named areas."""
    groups = defaultdict(list)
    for number, row in enumerate(rows, 2):
        location = row["보유장소"].removesuffix("(야외)")
        target_name = f'{row["시설명"]}({location})'
        groups[(target_name, normalized_address(row["도로명 주소"]))].append((number, row))
    for (name, address), group in groups.items():
        matches = [item for item in places
                   if item["sourceID"] == source["normalization"]["targetSourceID"]
                   and item["name"] == name and normalized_address(item["address"]) == address]
        if len(matches) != 1:
            raise ValueError(f'{source["id"]}: equipment inventory location cannot be joined: {name}')
        item = matches[0]
        item["supplementalEvidence"]["equipmentInventory"] = {
            "sourceID": source["id"], "sourceURL": source["sourceURL"],
            "capturedAt": source["capturedAt"], "method": "same-facility-subarea-and-address",
            "sourceCSVRows": [number for number, _ in group],
            "sourceRows": [row for _, row in group],
        }
        item["provenance"]["note"] += (
            " 같은 시설·설치구역·주소의 별도 보유현황 자료도 근거로 연결했습니다. "
            "보유현황의 기준일과 수량은 원문에 보존하며 기구명 자료와 기준일이 다를 수 있어 현재 수량으로 합산하지 않습니다."
        )


def build_pack(registry, root):
    sources = {source["id"]: source for source in registry["sources"]}
    if len(sources) != len(registry["sources"]):
        raise ValueError("duplicate source IDs")
    all_rows = {source_id: read_rows(source, root) for source_id, source in sources.items()}
    places, summaries = [], []
    adapters = {
        "park-equipment-reference": park_references,
        "jeju-equipment-survey": jeju_survey,
        "gwangju-equipment-list": gwangju_list,
        "ulsan-sports-park-reference": ulsan_sports_parks,
    }
    for source_id, source in sources.items():
        adapter = source["normalization"]["adapter"]
        if adapter in {"raw-reference-only", "ulsan-equipment-inventory-evidence"}:
            continue
        if adapter == "ulsan-equipment-list":
            group = ulsan_list(source, all_rows[source_id], sources, all_rows)
        elif adapter in adapters:
            group = adapters[adapter](source, all_rows[source_id])
        else:
            raise ValueError(f"unsupported adapter {adapter!r}")
        for item in group:
            item["sourceID"] = source_id
        places.extend(group)
        if group:
            summaries.append({
                "id": source_id, "capturedAt": source["capturedAt"],
                "requiresPlaceSourceID": True,
                "rowCount": len(all_rows[source_id]), "placeCount": len(group),
                "missingCoordinateCount": sum(item["latitude"] is None for item in group),
                "regions": sorted({item["regionName"] for item in group}),
            })
    if len({item["id"] for item in places}) != len(places):
        raise ValueError("duplicate place IDs; review source identity before updating")
    for source_id, source in sources.items():
        if source["normalization"]["adapter"] == "ulsan-equipment-inventory-evidence":
            attach_ulsan_inventory(source, all_rows[source_id], places)
    return {"schemaVersion": 1, "catalogRole": "regional-supplement", "version": registry["packVersion"],
            "generatedAt": registry["capturedAt"], "places": places, "sources": summaries}


class PortalFields(HTMLParser):
    def __init__(self):
        super().__init__()
        self.values = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "input" and attrs.get("id") in {"publicDataPk", "publicDataDetailPk"}:
            self.values[attrs["id"]] = attrs.get("value", "")


def public_bytes(url, timeout):
    if urlparse(url).scheme != "https" or urlparse(url).hostname != "www.data.go.kr":
        raise ValueError("Only the registered official data.go.kr public endpoints are supported")
    request = Request(url, headers={"User-Agent": "OutdoorLogPublicSourceRefresh/1.0",
                                    "Referer": "https://www.data.go.kr/"})
    with urlopen(request, timeout=timeout) as response:
        final_url = urlparse(response.geturl())
        if final_url.scheme != "https" or final_url.hostname != "www.data.go.kr":
            raise ValueError("Unexpected public download redirect; review the source")
        raw = response.read(40_000_001)
    if len(raw) > 40_000_000:
        raise ValueError("Public source exceeds the registered snapshot size limit")
    return raw


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix="." + path.name + ".",
                                         suffix=".tmp", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
        temporary_path.replace(path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def refresh(registry, registry_path, root, output, timeout):
    """Stage all downloads and a complete pack before replacing any saved file."""
    updated = copy.deepcopy(registry)
    captured = date.today().isoformat()
    changes = []
    with tempfile.TemporaryDirectory(prefix=".regional-", dir=registry_path.parent) as temporary:
        staging = Path(temporary)
        staged_paths = []

        def stage(relative_path, raw):
            relative = Path(relative_path)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Registry source paths must stay inside the repository")
            target = staging / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
            if relative not in staged_paths:
                staged_paths.append(relative)

        for source in updated["sources"]:
            old = {key: source.get(key) for key in
                   ("fileAttachmentID", "publicDataDetailID", "downloadURL", "sha256")}
            if source["format"] == "JSON":
                header_raw = public_bytes(source["headerURL"], timeout)
                header = json.loads(header_raw)
                columns = header["tableVO"]["colNmList"]
                if columns != source["columns"]:
                    raise ValueError(f'{source["id"]}: standard columns changed; review mapping')
                total = int(header["totalCount"])
                if not 0 < total < 50_000:
                    raise ValueError("City park snapshot count is outside the registered download bound")
                parameters = dict(source["downloadParameters"], totalCount=total,
                                  svcTableNm=header["tableVO"]["svcTableNm"],
                                  perPage=50_000, page=1, colNmList=columns)
                request_url = source["downloadURL"] + "?" + urlencode(parameters, doseq=True)
                raw = public_bytes(request_url, timeout)
                data = json.loads(raw)
                if not isinstance(data, list) or len(data) != total:
                    raise ValueError("City park public download is incomplete")
                after = json.loads(public_bytes(source["headerURL"], timeout))
                if (int(after["totalCount"]) != total
                        or after["tableVO"]["colNmList"] != columns
                        or after["tableVO"]["svcTableNm"] != header["tableVO"]["svcTableNm"]):
                    raise ValueError("City park source changed during download; saved snapshots were not replaced")
                source["downloadParameters"] = parameters
                stage(source["headerPath"], header_raw)
            else:
                # Read the current landing page, not an old attachment ID, on every refresh.
                fields = PortalFields()
                fields.feed(public_bytes(source["sourceURL"], timeout).decode("utf-8"))
                dataset_id = source["datasetID"]
                if fields.values.get("publicDataPk") != dataset_id:
                    raise ValueError(f'{source["id"]}: current dataset ID could not be verified')
                detail_id = fields.values.get("publicDataDetailPk")
                if not detail_id:
                    raise ValueError(f'{source["id"]}: current detail ID was not found')
                metadata_url = source["metadataURL"] + "?" + urlencode({
                    "publicDataPk": dataset_id, "publicDataDetailPk": detail_id,
                })
                metadata_raw = public_bytes(metadata_url, timeout)
                metadata = json.loads(metadata_raw)
                detail = metadata["dataSetFileDetailInfo"]
                if detail.get("useScopeCode") != source["licenseCode"]:
                    raise ValueError(f'{source["id"]}: public reuse terms changed; review source')
                attachment, sequence = metadata.get("atchFileId"), metadata.get("fileDetailSn")
                if not attachment or not sequence:
                    raise ValueError(f'{source["id"]}: no public attachment was returned')
                request_url = "https://www.data.go.kr/cmm/cmm/fileDownload.do?" + urlencode({
                    "atchFileId": attachment, "fileDetailSn": sequence,
                })
                raw = public_bytes(request_url, timeout)
                source.update(fileAttachmentID=attachment, publicDataDetailID=detail_id,
                              downloadURL=request_url, datasetTitle=detail["dataNm"])
                if "referenceDate" in source:
                    match = re.search(r"_(\d{4})(\d{2})(\d{2})$", detail["dataNm"])
                    if not match:
                        raise ValueError(f'{source["id"]}: dataset reference date is no longer explicit')
                    source["referenceDate"] = date(*(int(value) for value in match.groups())).isoformat()
                stage(source["metadataPath"], json_bytes({
                    "capturedAt": captured, "metadataURL": metadata_url,
                    "publicDataPk": dataset_id, "publicDataDetailPk": detail_id,
                    "dataNm": detail["dataNm"], "useScopeCode": detail["useScopeCode"],
                    "atchFileId": attachment, "fileDetailSn": sequence,
                }))
            stage(source["rawPath"], raw)
            rows = read_rows(source, staging, verify_proof=False)
            if not rows:
                raise ValueError(f'{source["id"]}: empty refresh requires manual source review')
            if source["format"] == "ZIP":
                csv_raw = zip_member(raw, source)
                source["extractedCSVSha256"] = hashlib.sha256(csv_raw).hexdigest()
                stage(source["extractedCSVPath"], csv_raw)
                projection_path = source["coordinateSystem"]["projectionFile"]
                projection = zip_member(raw, source, source["zipMember"][:-4] + ".prj")
                if projection != (root / projection_path).read_bytes():
                    raise ValueError(f'{source["id"]}: source CRS changed; review coordinate policy')
                stage(projection_path, projection)
            source["sha256"] = hashlib.sha256(raw).hexdigest()
            source["rowCount"] = len(rows)
            source["proof"] = {"sha256": source["sha256"], "byteCount": len(raw), "rowCount": len(rows)}
            source["capturedAt"] = captured
            source["capture"] = {"capturedAt": captured, "sourceURL": source["sourceURL"],
                                 "downloadURL": source["downloadURL"], "requestURL": request_url}
            if any(old[key] != source.get(key) for key in old):
                changes.append({"sourceID": source["id"], "previous": old,
                                "current": {key: source.get(key) for key in old}})
            if source.get("includedRowsPath"):
                pattern = re.compile(source["selection"]["equipmentEvidenceRegex"])
                selected = [row for row in rows
                            if row["MANAGE_NO"][:2] in source["normalization"]["regions"]
                            and pattern.search(row["MVM_FCLTY"])]
                stage(source["includedRowsPath"], json_bytes(selected))
                source["includedRowCount"] = len(selected)
        updated["capturedAt"] = captured
        updated["packVersion"] = max(registry["packVersion"] + 1, int(captured.replace("-", "") + "01"))
        pack = build_pack(updated, staging)
        for source in updated["sources"]:
            group = [item for item in pack["places"] if item["sourceID"] == source["id"]]
            source["placeCount"] = len(group)
            source["missingCoordinateCount"] = sum(item["latitude"] is None for item in group)
            source["regions"] = sorted({item["regionName"] for item in group})
            if source["normalization"]["adapter"] == "ulsan-equipment-inventory-evidence":
                linked = [item for item in pack["places"]
                          if item["supplementalEvidence"].get("equipmentInventory", {}).get("sourceID") == source["id"]]
                source["linkedPlaceCount"] = len(linked)
                source["includedRowCount"] = sum(len(item["supplementalEvidence"]["equipmentInventory"]["sourceCSVRows"])
                                                  for item in linked)
        for coverage in updated["coverage"]:
            group = [item for item in pack["places"] if item["regionName"].startswith(coverage["province"])]
            coverage.update(placeCount=len(group),
                            mappedPlaceCount=sum(item["latitude"] is not None for item in group),
                            equipmentSurveyOrListPlaceCount=sum(item["equipmentInformationKnown"] for item in group),
                            parkReferencePlaceCount=sum(not item["equipmentInformationKnown"] for item in group))
        updated["lastRefreshChanges"] = changes
        updated["preparation"] = "Official public files refreshed and validated by regional_catalog.py; no geocoding."
        updated["adapterValidation"] = "All registered inputs were decoded, schema checked and normalized during the recorded refresh; app tests were not run."
        # All decoding, schemas, joins and the entire pack must succeed before replacement.
        for relative in staged_paths:
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            (staging / relative).replace(destination)
        atomic_write(output, json_bytes(pack))
        atomic_write(registry_path, json_bytes(updated))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=Path("tools/catalog/regional-sources.json"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--refresh", action="store_true", help="Read current official public files before generating")
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    registry_path = args.registry.resolve()
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    root = registry_path.parents[2]
    output = args.output or root / registry["supplementalPack"]
    if args.refresh:
        refresh(registry, registry_path, root, output, args.timeout)
        return
    pack = build_pack(registry, root)
    atomic_write(output, json_bytes(pack))


if __name__ == "__main__":
    main()
