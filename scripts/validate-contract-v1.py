#!/usr/bin/env python3
"""Validate the v1 schema, fixtures, and required merge-policy vectors."""
from __future__ import annotations

import json
from pathlib import Path
import sys

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "Contracts" / "v1"
SCHEMA_PATH = CONTRACT / "schema.json"
MERGE_VECTORS_PATH = CONTRACT / "merge-vectors.json"

REQUIRED_MERGE_VECTOR_IDS = {
    "delete-before-edit",
    "delete-equal-edit",
    "delete-after-edit",
    "newer-edit-keeps-older-tombstone",
    "book-equal-time-portable-tie-and-recovery",
    "conversation-equal-time-portable-tie",
    "message-union-and-order",
    "same-message-id-different-payload",
    "opaque-unknown-disjoint-and-equal-values",
    "opaque-unknown-same-key-conflict",
    "provider-permutations-duplicate-and-retry",
    "wall-clock-skew-limitation",
}


def load(path: Path):
    # Python's JSON decoder accepts exponent overflow as infinity. The schema's
    # finite-binary64 bounds then reject it as intended.
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def validate_merge_vectors() -> list[str]:
    if not MERGE_VECTORS_PATH.is_file():
        return [f"missing {MERGE_VECTORS_PATH.relative_to(ROOT)}"]
    document = load(MERGE_VECTORS_PATH)
    if not isinstance(document, dict):
        return ["merge-vectors.json: expected a JSON object"]
    vectors = document.get("vectors")
    if not isinstance(vectors, list):
        return ["merge-vectors.json: expected a vectors array"]

    failures: list[str] = []
    found_ids: list[str] = []
    for index, vector in enumerate(vectors):
        label = f"merge-vectors.json: vector {index}"
        if not isinstance(vector, dict):
            failures.append(f"{label} must be an object")
            continue
        vector_id = vector.get("id")
        if not isinstance(vector_id, str) or not vector_id:
            failures.append(f"{label} needs a nonempty id")
            continue
        found_ids.append(vector_id)
        for key in ("classification", "inputs", "expected"):
            if key not in vector:
                failures.append(f"{vector_id}: missing {key}")

    duplicate_ids = sorted({item for item in found_ids if found_ids.count(item) > 1})
    for vector_id in duplicate_ids:
        failures.append(f"merge-vectors.json: duplicate vector id {vector_id}")
    missing_ids = sorted(REQUIRED_MERGE_VECTOR_IDS - set(found_ids))
    for vector_id in missing_ids:
        failures.append(f"merge-vectors.json: missing required case {vector_id}")
    if not document.get("policy") or not document.get("canonicalization") or not document.get("recoveryScope"):
        failures.append("merge-vectors.json: missing policy, canonicalization, or recoveryScope")
    return failures


def main() -> int:
    schema = load(SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    fixtures = sorted((CONTRACT / "fixtures").glob("*.json"))
    inputs = [path for path in fixtures if not path.name.endswith(".expected.json")]
    failures: list[str] = []
    expected_stems = {
        path.name.removesuffix(".expected.json")
        for path in fixtures if path.name.endswith(".expected.json")
    }
    input_stems = {path.stem for path in inputs}
    for missing in sorted(input_stems - expected_stems):
        failures.append(f"{missing}.json: missing expected outcome")
    for orphan in sorted(expected_stems - input_stems):
        failures.append(f"{orphan}.expected.json: no matching input fixture")

    for path in inputs:
        expected_path = path.with_name(path.stem + ".expected.json")
        if not expected_path.is_file():
            continue
        expected = load(expected_path)
        document = load(path)
        errors = sorted(validator.iter_errors(document), key=lambda e: list(map(str, e.absolute_path)))
        # These fixtures describe policy or platform characterization beyond
        # structural schema validity; they are expected to remain schema-valid.
        schema_valid = expected["classification"] in {
            "accept", "characterization", "characterization only",
            "compatibility characterization", "preservation expectation",
            "safety rejection expectation",
        }
        if schema_valid and errors:
            failures.append(f"{path.name}: expected schema-valid, got {errors[0].message}")
        elif not schema_valid and not errors:
            failures.append(f"{path.name}: expected schema-invalid, but passed")
        else:
            result = "valid" if not errors else "invalid"
            print(f"PASS {path.name}: {result}")
    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1
    print(f"Validated schema and {len(inputs)} fixture inputs; all outcomes matched.")
    merge_failures = validate_merge_vectors()
    if merge_failures:
        for failure in merge_failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1
    merge_count = len(load(MERGE_VECTORS_PATH)["vectors"])
    print(f"Validated merge policy structure and {merge_count} required semantic cases.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
