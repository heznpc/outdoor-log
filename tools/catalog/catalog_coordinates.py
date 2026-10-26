"""Evidence-preserving coordinate supplements; no network or invented locations."""
from collections import defaultdict
from copy import deepcopy
from datetime import date, datetime, timezone
import math
import unicodedata
from urllib.parse import urlsplit


QUALITIES = {"equipment", "facility", "park", "address"}
PARK_SOURCE = "https://www.data.go.kr/data/15012890/standard.do"


def canonical(value):
    # Only Unicode composition and whitespace; no fuzzy names, omitted lot numbers,
    # district guesses, or merging different road/parcel addresses.
    return "".join(unicodedata.normalize("NFC", value or "").split())


def capture_date(value):
    if not isinstance(value, str):
        raise ValueError("Missing capture timestamp")
    try:
        if len(value) == 10:
            return datetime.combine(date.fromisoformat(value), datetime.min.time(), timezone.utc)
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is not None:
            return result
    except ValueError:
        pass
    raise ValueError("Invalid capture timestamp")


def point(latitude, longitude):
    if isinstance(latitude, bool) or isinstance(longitude, bool):
        return None
    try:
        latitude, longitude = float(latitude), float(longitude)
        if (math.isfinite(latitude) and math.isfinite(longitude)
                and -90 <= latitude <= 90 and -180 <= longitude <= 180):
            return latitude, longitude
    except (ValueError, TypeError):
        pass
    return None


def has_conflict(place):
    return (place.get("coordinateConflict") is True
            or "원본 좌표가 서로 달라" in (place.get("provenance", {}).get("note") or ""))


def validate_evidence(evidence):
    if not isinstance(evidence, dict):
        raise ValueError("Coordinate evidence must be an object")
    for key, limit in [("sourceURL", 2000), ("method", 200), ("capturedAt", 100),
                       ("matchedAddress", 1000)]:
        value = evidence.get(key)
        if not isinstance(value, str) or not value.strip() or len(value) > limit:
            raise ValueError("Invalid coordinate evidence field: " + key)
    for key, limit in [("sourceRecordID", 200), ("matchedName", 500)]:
        value = evidence.get(key)
        if value is not None and (not isinstance(value, str) or not value.strip() or len(value) > limit):
            raise ValueError("Invalid coordinate evidence field: " + key)
    url = urlsplit(evidence["sourceURL"])
    if (url.scheme != "https" or not url.hostname or url.username is not None
            or url.password is not None or "#" in evidence["sourceURL"]):
        raise ValueError("Evidence requires public HTTPS without credentials")
    capture_date(evidence["capturedAt"])


def validate_supplements(document):
    if (not isinstance(document, dict) or type(document.get("schemaVersion")) is not int
            or document["schemaVersion"] != 1 or not isinstance(document.get("entries"), list)
            or len(document["entries"]) > 250_000):
        raise ValueError("Invalid coordinate supplement document")
    for entry in document["entries"]:
        if not isinstance(entry, dict):
            raise ValueError("Coordinate entries must be objects")
        identifier = entry.get("placeID")
        if not isinstance(identifier, str) or not identifier or len(identifier) > 200:
            raise ValueError("Invalid supplement place ID")
        if (entry.get("quality") not in QUALITIES
                or type(entry.get("latitude")) not in [int, float]
                or type(entry.get("longitude")) not in [int, float]
                or point(entry.get("latitude"), entry.get("longitude")) is None):
            raise ValueError("Invalid supplement coordinates or quality")
        validate_evidence(entry)


def entry_evidence(entry):
    return {key: entry[key] for key in ["sourceURL", "method", "capturedAt", "matchedAddress",
        "sourceRecordID", "matchedName"] if key in entry}


def rejection_reason(place, entry):
    if (entry["matchedAddress"] != place["address"]
            or entry.get("matchedName", place["name"]) != place["name"]):
        return "identityMismatch"
    if has_conflict(place):
        return "sourceConflict"
    captured = capture_date(entry["capturedAt"])
    for prior in [place.get("provenance", {}).get("referenceDate"),
                  (place.get("coordinateEvidence") or {}).get("capturedAt")]:
        if prior:
            try:
                prior_date = capture_date(prior)
            except ValueError:
                # Non-date source labels are not an ordering claim (same as iOS).
                continue
            if captured < prior_date:
                return "olderEvidence"
    return None


def retain_previous_entries(pack, document):
    """Keep portable evidence even when the input already includes its coordinate."""
    validate_supplements(document)
    indexed = defaultdict(list)
    for entry in document["entries"]:
        indexed[entry["placeID"]].append(entry)
    retained = []
    for place in pack["places"]:
        candidates = indexed.get(place["id"], [])
        if len(candidates) != 1 or rejection_reason(place, candidates[0]):
            continue
        entry = candidates[0]
        missing = place.get("latitude") is None and place.get("longitude") is None
        same = (point(place.get("latitude"), place.get("longitude")) == point(entry["latitude"], entry["longitude"])
                and place.get("coordinateQuality") == entry["quality"]
                and place.get("coordinateEvidence") == entry_evidence(entry))
        if missing or same:
            retained.append(entry)
    return retained


def apply_supplements(pack, document):
    validate_supplements(document)
    result = deepcopy(pack)
    entries = defaultdict(list)
    for entry in document["entries"]:
        entries[entry["placeID"]].append(entry)
    counts = defaultdict(int)
    for place in result["places"]:
        candidates = entries.pop(place["id"], [])
        if not candidates:
            continue
        if len(candidates) != 1:
            counts["duplicateEntries"] += 1
            continue
        entry = candidates[0]
        reason = rejection_reason(place, entry)
        if reason:
            counts[reason] += 1
            continue
        # Never replace an existing source or previously confirmed coordinate.
        if place.get("latitude") is not None or place.get("longitude") is not None:
            counts["alreadyLocated"] += 1
            continue
        place["latitude"], place["longitude"] = point(entry["latitude"], entry["longitude"])
        place["coordinateQuality"] = entry["quality"]
        place["coordinateEvidence"] = entry_evidence(entry)
        counts["applied"] += 1
    counts["unmatchedPlaceIDs"] = len(entries)
    # Source summaries describe the resulting catalog, including enrichment.
    for summary in result.get("sources") or []:
        subset = [p for p in result["places"] if p.get("sourceID") == summary["id"]]
        if summary["id"] == "data-go-kr:15139207":
            subset = [p for p in result["places"] if p["id"].startswith("national-equipment-")
                      and p["provenance"]["sourceURL"] == "https://www.data.go.kr/data/15139207/standard.do"]
        if subset:
            summary["missingCoordinateCount"] = sum(p.get("latitude") is None for p in subset)
    return result, dict(counts)


def match_park_coordinates(places, rows, captured_at):
    capture_date(captured_at)
    index = defaultdict(list)
    for row in rows:
        location = point(row.get("LATITUDE"), row.get("LONGITUDE"))
        if location is None or not row.get("MANAGE_NO") or not row.get("PARK_NM"):
            continue
        for address in {row.get("RDNMADR"), row.get("LNMADR")} - {None, ""}:
            index[canonical(row["PARK_NM"]), canonical(address)].append((row, location))
    entries = []
    for place in places:
        if (place.get("latitude") is not None or place.get("longitude") is not None
                or not place.get("address") or has_conflict(place)):
            continue
        candidates = index[canonical(place["name"]), canonical(place["address"])]
        # Different IDs or coordinates at the same address are unresolved ambiguity.
        identities = {(r["MANAGE_NO"], coordinates) for r, coordinates in candidates}
        if len(identities) != 1:
            continue
        row, (latitude, longitude) = candidates[0]
        entries.append({"placeID": place["id"], "latitude": latitude, "longitude": longitude,
            "quality": "park", "sourceURL": PARK_SOURCE, "sourceRecordID": row["MANAGE_NO"],
            "method": "official-park-exact-name-and-address", "capturedAt": captured_at,
            "matchedAddress": place["address"], "matchedName": place["name"]})
    return entries
