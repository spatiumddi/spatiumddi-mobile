#!/usr/bin/env python3
"""Rewrite FastAPI's nullable idiom into one swift-openapi-generator understands.

FastAPI emits `Optional[X]` as OpenAPI 3.1 `anyOf: [{...X}, {"type": "null"}]`.
swift-openapi-generator does not support a bare `"null"` schema type and skips
the member — which silently drops the whole property from the generated Swift
type, and the whole parameter from the generated request.

On the SpatiumDDI document that is 386 schema properties and 75 query
parameters: fields like `expires_at`, `last_sync_error` and `start_address`
simply do not exist on the generated models, and pagination parameters cannot
be sent. That is exactly the silent drift a generated client is supposed to
prevent.

This collapses the idiom to the plain schema and marks the property optional, so
the generator emits a Swift optional. `decodeIfPresent` maps both an absent key
and an explicit JSON null to nil, so the round trip is preserved.

Deterministic and idempotent; run it whenever the pinned document changes.
Ideally deleted once the server emits a generator-compatible document —
see spatiumddi/spatiumddi#907.

    ./scripts/normalise-openapi.py <input.json> <output.json>
"""
from __future__ import annotations

import json
import sys

Stats = dict[str, int]


def is_null_schema(node: object) -> bool:
    return isinstance(node, dict) and node.get("type") == "null" and len(node) == 1


def collapse(node: dict, stats: Stats) -> dict:
    """Collapse `anyOf`/`oneOf` containing a bare null into the remaining schema."""
    for keyword in ("anyOf", "oneOf"):
        members = node.get(keyword)
        if not isinstance(members, list):
            continue
        if not any(is_null_schema(m) for m in members):
            continue

        remaining = [m for m in members if not is_null_schema(m)]
        stats["collapsed"] += 1

        if len(remaining) == 1 and isinstance(remaining[0], dict):
            # Inline the sole survivor, keeping annotations already on the parent.
            merged = dict(remaining[0])
            for annotation in ("title", "description", "default", "example", "deprecated"):
                if annotation in node and annotation not in merged:
                    merged[annotation] = node[annotation]
            node = {k: v for k, v in node.items() if k != keyword}
            node.update(merged)
        else:
            node[keyword] = remaining
    return node


def walk(node: object, stats: Stats) -> object:
    if isinstance(node, dict):
        node = collapse(dict(node), stats)

        # A property that was nullable must become optional, or the generator
        # emits a non-optional Swift property that an explicit null cannot fill.
        properties = node.get("properties")
        required = node.get("required")
        if isinstance(properties, dict) and isinstance(required, list):
            nullable = {
                name
                for name, schema in properties.items()
                if isinstance(schema, dict)
                and any(
                    is_null_schema(m)
                    for keyword in ("anyOf", "oneOf")
                    for m in (schema.get(keyword) or [])
                )
            }
            if nullable:
                kept = [r for r in required if r not in nullable]
                stats["unrequired"] += len(required) - len(kept)
                if kept:
                    node["required"] = kept
                else:
                    node.pop("required")

        return {key: walk(value, stats) for key, value in node.items()}

    if isinstance(node, list):
        return [walk(item, stats) for item in node]

    return node


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    with open(argv[1]) as handle:
        document = json.load(handle)

    stats: Stats = {"collapsed": 0, "unrequired": 0}
    # `required` is read from the pre-walk node, so collect it before collapsing.
    normalised = walk(document, stats)

    # Compact but key-sorted: re-running on the same input produces identical
    # bytes, which is what makes drift against the pinned asset detectable.
    with open(argv[2], "w") as handle:
        json.dump(normalised, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")

    print(f"collapsed {stats['collapsed']} nullable unions", file=sys.stderr)
    print(f"made {stats['unrequired']} properties optional", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
