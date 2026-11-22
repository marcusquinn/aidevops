"""Bounded, versioned admission envelopes for exact producer retries.

This is ingestion, not a delivery/outbox guarantee or a trust boundary against
same-user callers. No producer-supplied observation can end a run through here.
"""

import json

from .process import ProcessIdentity
from .storage import MAX_EVENT_BYTES, LifecycleRegistry, identifier


def unique_fields(pairs: list) -> dict:
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate-json-field")
        value[key] = item
    return value


def parse_event(raw: str) -> dict:
    if len(raw.encode("utf-8")) > MAX_EVENT_BYTES:
        raise ValueError("event-envelope-too-large")
    try:
        event = json.loads(raw, object_pairs_hook=unique_fields)
    except RecursionError as error:
        raise ValueError("event-nesting-too-deep") from error
    if not isinstance(event, dict) or type(event.get("schema")) is not int or event["schema"] != 1:  # pylint: disable=unidiomatic-typecheck  # Reject bool
        raise ValueError("unsupported-event-schema")
    common = {"schema", "type", "event_id", "run_id"}
    if event.get("type") == "register":
        fields = common | {"identity"}
    elif event.get("type") == "bind":
        fields = common | {"generation_id", "path"}
    else:
        raise ValueError("unsupported-event-type")
    if set(event) != fields:
        raise ValueError("invalid-event-fields")
    identifier(event["event_id"])
    identifier(event["run_id"])
    return event


def ingest(store: LifecycleRegistry, raw: str) -> None:
    event = parse_event(raw)
    if event["type"] == "register":
        store.register(event["event_id"], event["run_id"], ProcessIdentity.from_dict(event["identity"]))
    else:
        store.bind(event["event_id"], event["run_id"], event["generation_id"], event["path"])
