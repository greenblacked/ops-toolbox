#!/usr/bin/env python3
"""Check the shape of a winget configuration file.

yamllint proves one of these parses. It says nothing about whether the result
is the document the author meant, and that gap is not theoretical: an unquoted
description containing a comma ends its value inside an inline map, so

    directives: { description: Temurin JDK 21 - one JVM, not three, ... }

parses cleanly into a directives map carrying a stray 'not three' key. Valid
YAML, wrong document, silently handed to winget.

Exits 0 and prints a one-line summary on success; exits 1 and prints the
objection on failure.
"""
import sys

import yaml

KNOWN_DIRECTIVES = {"description", "allowPrerelease", "securityContext", "module"}


def fail(message):
    print(message)
    raise SystemExit(1)


def main():
    if len(sys.argv) != 2:
        fail("usage: winget_config_shape.py FILE")
    path = sys.argv[1]

    try:
        with open(path, encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as exc:
        fail(f"could not parse: {exc}")

    if not isinstance(doc, dict):
        fail("top level is not a mapping")

    properties = doc.get("properties")
    if not isinstance(properties, dict):
        fail("no 'properties' mapping")

    if "configurationVersion" not in properties:
        fail("no 'configurationVersion'")

    resources = properties.get("resources")
    if not isinstance(resources, list) or not resources:
        fail("declares no resources; winget would apply nothing")

    entries = list(resources) + list(properties.get("assertions") or [])

    resource_ids = []
    package_ids = []
    for index, entry in enumerate(entries):
        where = f"entry {index + 1}"
        if not isinstance(entry, dict):
            fail(f"{where} is not a mapping")
        if not entry.get("resource"):
            fail(f"{where} has no 'resource'")

        directives = entry.get("directives") or {}
        if not isinstance(directives, dict):
            fail(f"{where} ({entry['resource']}) has non-mapping directives")
        # The check this file exists for.
        unknown = sorted(set(directives) - KNOWN_DIRECTIVES)
        if unknown:
            fail(
                f"{where} ({entry['resource']}) has unknown directive(s) {unknown}; "
                "an unquoted value containing a comma splits into extra keys"
            )
        if not directives.get("description"):
            fail(f"{where} ({entry['resource']}) has no description")

        if entry.get("id"):
            resource_ids.append(entry["id"])
        settings = entry.get("settings") or {}
        if not isinstance(settings, dict):
            fail(f"{where} ({entry['resource']}) has non-mapping settings")
        if entry in resources:
            if not settings.get("id"):
                fail(f"{where} ({entry['resource']}) has no settings.id")
            package_ids.append(settings["id"])

    for label, values in (("resource id", resource_ids), ("package id", package_ids)):
        duplicates = sorted({v for v in values if values.count(v) > 1})
        if duplicates:
            fail(f"duplicate {label}(s): {duplicates}")

    print(
        f"schema {properties['configurationVersion']}, "
        f"{len(resources)} resources, "
        f"{len(properties.get('assertions') or [])} assertions"
    )


if __name__ == "__main__":
    main()
