#!/usr/bin/env python3
"""Build a static, credential-free catalog release from verified public inputs.

The restore-previous subcommand verifies the live public deployment first. The
default build command is offline. Only its output directory goes to Pages;
raw downloads, environment variables and service credentials are never copied.
"""
import argparse
from collections import Counter, defaultdict
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from catalog_coordinates import apply_supplements
from enrich_coordinates import load_bytes, load_json
from normalize import (MAXIMUM_BYTES, NATIONAL_ID_FIELDS, NATIONAL_ID_PREFIX,
    NATIONAL_SOURCE_ID, NATIONAL_SOURCE_URL, collection_proof, from_national,
    national_digest, national_rows, national_text, require_https, validate_config,
    validate_namespace, validate_pack,
    valid_capture_date)


MAXIMUM_PACK_BYTES = 20 * 1024 * 1024
PROVINCES = ("서울특별시", "부산광역시", "대구광역시", "인천광역시", "광주광역시",
    "대전광역시", "울산광역시", "세종특별자치시", "경기도", "강원특별자치도",
    "충청북도", "충청남도", "전북특별자치도", "전라남도", "경상북도", "경상남도", "제주특별자치도")
PROVINCE_ALIASES = {"강원도": "강원특별자치도", "전라북도": "전북특별자치도", "무안군": "전라남도"}
LEGACY_SOURCES = {"gimhae-equipment-": "data-go-kr:15104705",
                  "public-park-46840-": "data-go-kr:15012890:muan"}


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def public_base_url(value):
    require_https(value)
    parsed = urlsplit(value)
    if (parsed.query or parsed.port not in (None, 443)
            or not re.fullmatch(r"https://[A-Za-z0-9.-]+(?::443)?(?:/[A-Za-z0-9._~%/-]*)?", value)
            or any(segment in (".", "..") for segment in parsed.path.split("/"))):
        raise ValueError("Pages base URL must be a public HTTPS site path without a query")
    return value.rstrip("/")


def verified_national(pack, raw_bytes, header, config):
    proof = collection_proof(header, raw_bytes)
    if header.get("transport") != "official-api" or proof.get("transport") != "official-api":
        raise ValueError("Publication requires a complete official API collection; portal fallback is not automatic")
    config = dict(config, capturedAt=proof["capturedAt"])
    validate_config(config)
    validate_namespace(config, "national")
    rows = national_rows(json.loads(raw_bytes))
    if len(rows) != proof["rowCount"]:
        raise ValueError("National API proof row count does not match the snapshot")
    expected = from_national(rows, config)
    actual = sorted((p for p in pack["places"] if p["id"].startswith(NATIONAL_ID_PREFIX)
        and p["provenance"]["sourceURL"] == NATIONAL_SOURCE_URL), key=lambda p: p["id"])
    if actual != expected:
        raise ValueError("Published national places must match normalization of the verified API bytes")
    summary = next((s for s in pack.get("sources", []) if s["id"] == NATIONAL_SOURCE_ID), None)
    if (summary is None or summary["rowCount"] != len(rows)
            or summary["capturedAt"] != proof["capturedAt"]
            or summary.get("completeCapturedAt") != proof["capturedAt"]):
        raise ValueError("National source summary does not match its complete API capture")
    weights = Counter(NATIONAL_ID_PREFIX + national_digest(tuple(national_text(row, field)
        for field in NATIONAL_ID_FIELDS)) for row in rows)
    return proof, weights


def attribute_sources(pack):
    """Make legacy attribution explicit before coordinate counts and sharding."""
    result = deepcopy(pack)
    summaries = {s["id"]: s for s in result.get("sources", [])}
    for place in result["places"]:
        if place["id"].startswith(NATIONAL_ID_PREFIX) and place["provenance"]["sourceURL"] == NATIONAL_SOURCE_URL:
            place["sourceID"] = NATIONAL_SOURCE_ID
        elif place.get("sourceID") is None:
            matches = [source for prefix, source in LEGACY_SOURCES.items() if place["id"].startswith(prefix)]
            if len(matches) != 1 or matches[0] not in summaries:
                raise ValueError("A published place needs unambiguous registered source attribution")
            place["sourceID"] = matches[0]
    for summary in summaries.values():
        summary["requiresPlaceSourceID"] = True
    validate_pack(result)
    return result


def source_fragment(pack, summary, places, row_count):
    source = dict(summary, rowCount=row_count, placeCount=len(places),
        missingCoordinateCount=sum(p["latitude"] is None for p in places),
        regions=sorted({p["regionName"] for p in places}))
    return {"schemaVersion": 1, "version": pack["version"], "generatedAt": pack["generatedAt"],
            "places": places, "sources": [source]}


def split_packs(pack, national_weights, maximum_bytes=MAXIMUM_PACK_BYTES):
    """Keep raw row counts additive under CatalogMerge.manifest's contract.

    National rows have exact per-place grouping weights. Regional raw rows may
    include excluded facilities or parent evidence; count that full input once
    in its first fragment, never invent per-place row counts for later shards.
    """
    groups = defaultdict(list)
    for place in pack["places"]:
        groups[place["sourceID"]].append(place)
    outputs = []
    for summary in sorted(pack["sources"], key=lambda s: s["id"]):
        places = sorted(groups.pop(summary["id"], []), key=lambda p: p["id"])

        def split(subset, first):
            rows = (sum(national_weights[p["id"]] for p in subset)
                if summary["id"] == NATIONAL_SOURCE_ID else summary["rowCount"] if first else 0)
            fragment = source_fragment(pack, summary, subset, rows)
            payload = encoded(fragment)
            if len(payload) > maximum_bytes:
                if len(subset) <= 1:
                    raise ValueError("One place and its metadata exceed the app's pack size limit")
                midpoint = len(subset) // 2
                split(subset[:midpoint], first)
                split(subset[midpoint:], False)
            else:
                validate_pack(fragment)
                outputs.append((fragment, payload))

        split(places, True)
    if groups or not outputs or len(outputs) > 100 or sum(len(data) for _, data in outputs) > MAXIMUM_BYTES:
        raise ValueError("Release exceeds the app's collection limits or has an unregistered source")
    return outputs


def coverage_report(pack, proof, coordinate_counts):
    regions = defaultdict(list)
    for place in pack["places"]:
        province = place["regionName"].split()[0]
        regions[PROVINCE_ALIASES.get(province, province)].append(place)
    report = []
    for province in sorted(set(PROVINCES) | set(regions)):
        places = regions[province]
        report.append({"province": province, "placeCount": len(places),
            "mappedPlaceCount": sum(p["latitude"] is not None for p in places),
            "missingCoordinateCount": sum(p["latitude"] is None for p in places),
            "sourceIDs": sorted({p["sourceID"] for p in places}),
            "coordinateQualityCounts": dict(sorted(Counter(p["coordinateQuality"] for p in places).items())),
            "completeInventory": False})
    return {"schemaVersion": 1, "version": pack["version"], "generatedAt": pack["generatedAt"],
        "placeCount": len(pack["places"]), "missingCoordinateCount": sum(p["latitude"] is None for p in pack["places"]),
        "completeInventory": False, "coverageMeaning": "reported public-source places, not a complete current facility inventory",
        "nationalCollection": proof, "coordinateApplication": coordinate_counts,
        "sources": pack["sources"], "provinces": report}


def release_files(pack, proof, national_weights, base_url, coordinate_counts):
    base_url = public_base_url(base_url)
    outputs = split_packs(pack, national_weights)
    manifest = {"schemaVersion": 1, "version": pack["version"], "generatedAt": pack["generatedAt"], "packs": []}
    files = {}
    for index, (fragment, payload) in enumerate(outputs, 1):
        digest = hashlib.sha256(payload).hexdigest()
        relative = f'releases/{pack["version"]}/pack-{index:03d}-{digest[:16]}.json'
        files[relative] = payload
        manifest["packs"].append({"url": base_url + "/" + relative, "byteCount": len(payload),
                                  "sha256": digest, "placeCount": len(fragment["places"])})
    coverage = encoded(coverage_report(pack, proof, coordinate_counts))
    files[f'releases/{pack["version"]}/manifest.json'] = encoded(manifest)
    files[f'releases/{pack["version"]}/coverage.json'] = coverage
    files["coverage.json"] = coverage
    files["manifest.json"] = encoded(manifest)
    files[".nojekyll"] = b""
    return files, manifest


def xcconfig(base_url):
    # Literal // starts an xcconfig comment, including within quotes.
    endpoint = (public_base_url(base_url) + "/manifest.json").replace("https://", "https:/$()/", 1)
    return f"OUTDOOR_LOG_CATALOG_MANIFEST_URL = {endpoint}\n"


def verified_previous_files(manifest, read_pack, base_url, version):
    """Verify the same URL, byte, identity and source contract used by the app."""
    if not isinstance(manifest, dict):
        raise ValueError("Previous manifest must be a schema-1 object")
    previous_version = manifest.get("version")
    if (manifest.get("schemaVersion") != 1 or type(previous_version) is not int
            or not 0 < previous_version < version or not isinstance(manifest.get("packs"), list)
            or not 1 <= len(manifest["packs"]) <= 100
            or not valid_capture_date(manifest.get("generatedAt"))):
        raise ValueError("Previous release is invalid or publication would not advance its version")
    prefix = public_base_url(base_url) + "/"
    files = {}
    total_places = 0
    combined_places, combined_sources = [], {}
    for entry in manifest["packs"]:
        url = entry["url"]
        if not isinstance(url, str) or not url.startswith(prefix):
            raise ValueError("Previous manifest belongs to a different deployment URL")
        relative = url[len(prefix):]
        if (not re.fullmatch(rf"releases/{previous_version}/pack-[0-9]{{3}}-[0-9a-f]{{16}}\.json", relative)
                or relative in files):
            raise ValueError("Previous release contains an unexpected or repeated file path")
        if (type(entry.get("byteCount")) is not int or not 0 < entry["byteCount"] <= MAXIMUM_PACK_BYTES
                or type(entry.get("placeCount")) is not int or not 0 <= entry["placeCount"] <= 250_000
                or not isinstance(entry.get("sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])):
            raise ValueError("Previous pack metadata exceeds the app contract")
        payload = read_pack(relative)
        pack = json.loads(payload)
        validate_pack(pack)
        if (not 0 < len(payload) <= MAXIMUM_PACK_BYTES or entry["byteCount"] != len(payload)
                or entry["sha256"] != hashlib.sha256(payload).hexdigest()
                or pack["version"] != previous_version or entry["placeCount"] != len(pack["places"])):
            raise ValueError("Previous release pack differs from its manifest")
        source_ids = {source["id"] for source in pack.get("sources", [])}
        if any(place.get("sourceID") not in source_ids for place in pack["places"]):
            raise ValueError("Previous public places require registered source attribution")
        for source in pack.get("sources", []):
            existing = combined_sources.get(source["id"])
            if existing is None:
                combined_sources[source["id"]] = deepcopy(source)
            else:
                for field in ("capturedAt", "completeCapturedAt", "partialCapturedAt"):
                    if existing.get(field) != source.get(field):
                        raise ValueError("Previous source fragments disagree on their capture evidence")
                for field in ("rowCount", "placeCount", "missingCoordinateCount"):
                    existing[field] += source[field]
                existing["regions"] = sorted(set(existing["regions"]) | set(source["regions"]))
        combined_places.extend(pack["places"])
        total_places += len(pack["places"])
        files[relative] = payload
        if sum(map(len, files.values())) > MAXIMUM_BYTES or total_places > 250_000:
            raise ValueError("Previous release exceeds collection resource limits")
    validate_pack({"schemaVersion": 1, "version": previous_version,
        "generatedAt": manifest["generatedAt"], "places": combined_places,
        "sources": list(combined_sources.values())})
    files[f"releases/{previous_version}/manifest.json"] = encoded(manifest)
    return files


def first_deployment_marker(base_url):
    return {"schemaVersion": 1, "baseURL": public_base_url(base_url),
            "firstDeploymentConfirmed": True, "githubDeploymentExists": False}


def previous_release(site, base_url, version):
    if site is None or not site.is_dir():
        raise ValueError("Verified deployment evidence is required; absence is not proof of a first deployment")
    manifest_path = site / "manifest.json"
    if not manifest_path.exists():
        if load_json(site / "first-deployment.json") != first_deployment_marker(base_url):
            raise ValueError("First deployment needs explicit confirmation and verified empty deployment history")
        return {}
    return verified_previous_files(load_json(manifest_path), lambda path: load_bytes(site / path), base_url, version)


class PublicFileMissing(ValueError):
    pass


class NoPublicRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Published catalog redirects are not accepted; configure the final Pages base URL")


def fetch_public_file(url, limit):
    require_https(url)
    request = Request(url, headers={"Accept": "application/json", "Cache-Control": "no-cache",
        "User-Agent": "OutdoorLog-Catalog-Publication/1.0"})
    try:
        with build_opener(NoPublicRedirect()).open(request, timeout=30) as response:
            if response.geturl() != url or response.status != 200:
                raise ValueError("Unexpected public catalog response")
            payload = response.read(limit + 1)
    except HTTPError as error:
        if error.code == 404:
            raise PublicFileMissing("Published catalog file returned HTTP 404") from None
        raise ValueError(f"Published catalog request failed with HTTP {error.code}") from None
    except (URLError, TimeoutError, OSError):
        raise ValueError("Published catalog is unreachable; previous deployment cannot be verified") from None
    if len(payload) > limit:
        raise ValueError("Published catalog file exceeds the app's resource limit")
    return payload


def restore_published_release(base_url, output, deployment_exists, first_deployment=False, fetch=fetch_public_file):
    base_url = public_base_url(base_url)
    manifest_url = base_url + "/manifest.json"
    try:
        manifest_bytes = fetch(manifest_url, 1024 * 1024)
    except PublicFileMissing:
        # Neither an unavailable endpoint nor an empty local cache establishes
        # first publication. Require both an explicit operator choice and the
        # separately authenticated GitHub deployment-history check.
        if deployment_exists or not first_deployment:
            raise ValueError("Existing publication could not be restored; refusing to remove its pack URLs") from None
        write_release(output, {"first-deployment.json": encoded(first_deployment_marker(base_url))})
        return
    manifest = json.loads(manifest_bytes)
    files = verified_previous_files(manifest,
        lambda relative: fetch(base_url + "/" + relative, MAXIMUM_PACK_BYTES), base_url, 2**63 - 1)
    if fetch(manifest_url, 1024 * 1024) != manifest_bytes:
        raise ValueError("Published manifest changed during restoration; retry before collecting a new release")
    files["manifest.json"] = manifest_bytes
    write_release(output, files)


def restore_main():
    parser = argparse.ArgumentParser(description="Restore the actual published release before preparing a replacement")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--deployment-exists", choices=("true", "false"), required=True,
        help="Authenticated GitHub deployment-history result; lookup failure must abort the workflow")
    parser.add_argument("--first-deployment", action="store_true",
        help="Operator explicitly confirms first publication; only allowed with no previous deployment and HTTP 404")
    args = parser.parse_args(sys.argv[2:])
    restore_published_release(args.base_url, args.output, args.deployment_exists == "true", args.first_deployment)


def write_release(output, files):
    if output.exists():
        raise ValueError("Release output must be a new directory; do not overwrite a live site in place")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".catalog-release-", dir=output.parent) as temporary:
        staging = Path(temporary) / "site"
        staging.mkdir()
        for relative, payload in files.items():
            path = staging / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
        staging.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Normalized national + regional + legacy pack, before coordinate enrichment")
    parser.add_argument("--national-input", type=Path, required=True)
    parser.add_argument("--national-header", type=Path, required=True)
    parser.add_argument("--national-config", type=Path, default=Path("tools/catalog/national.mapping.json"))
    parser.add_argument("--legacy-input", type=Path, default=Path("tools/catalog/sources/legacy-regional-catalog.json"))
    parser.add_argument("--source-provenance", type=Path, default=Path("tools/catalog/sources/provenance.json"))
    parser.add_argument("--coordinate-supplements", type=Path, required=True)
    parser.add_argument("--base-url", required=True, help="Actual configure-pages base_url; never a guessed placeholder")
    parser.add_argument("--previous-site", type=Path, required=True,
        help="Output of restore-previous, containing verified live files or explicit first-deployment evidence")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--xcconfig-output", type=Path, required=True)
    args = parser.parse_args()
    pack = load_json(args.input)
    validate_pack(pack)
    if not valid_capture_date(pack["generatedAt"]):
        raise ValueError("Release generation time must be ISO-8601")
    proof, weights = verified_national(pack, load_bytes(args.national_input),
        load_json(args.national_header), load_json(args.national_config))
    legacy_bytes = load_bytes(args.legacy_input)
    legacy_proof = load_json(args.source_provenance)["legacyRegional"]
    if (len(legacy_bytes) != legacy_proof["byteCount"]
            or hashlib.sha256(legacy_bytes).hexdigest() != legacy_proof["sha256"]):
        raise ValueError("Preserved legacy catalog does not match its recorded bytes")
    legacy = json.loads(legacy_bytes)
    indexed = {p["id"]: p for p in pack["places"]}
    if any(indexed.get(p["id"]) != p for p in legacy["places"]):
        raise ValueError("The release must retain the verified legacy places")
    pack = attribute_sources(pack)
    pack, counts = apply_supplements(pack, load_json(args.coordinate_supplements))
    validate_pack(pack)
    files, manifest = release_files(pack, proof, weights, args.base_url, counts)
    files.update(previous_release(args.previous_site, args.base_url, pack["version"]))
    config = xcconfig(args.base_url)
    if args.xcconfig_output.resolve().is_relative_to(args.output.resolve()):
        raise ValueError("App build configuration belongs outside the public site directory")
    write_release(args.output, files)
    args.xcconfig_output.parent.mkdir(parents=True, exist_ok=True)
    args.xcconfig_output.write_text(config, encoding="utf-8")
    print(json.dumps({"version": manifest["version"], "packs": len(manifest["packs"]),
        "places": len(pack["places"]), "missingCoordinates": sum(p["latitude"] is None for p in pack["places"]),
        "manifestURL": public_base_url(args.base_url) + "/manifest.json"}))


if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "restore-previous":
            restore_main()
        else:
            main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f"Catalog publication failed: {error}") from None
