"""Load the explicitly enabled Compose stacks."""

from __future__ import annotations

import re
import sys

from .common import ROOT, ScriptError


MANIFEST = ROOT / "stacks" / "manifest.txt"
STACK_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def stack_names() -> tuple[str, ...]:
    if not MANIFEST.is_file():
        raise ScriptError(f"missing stack manifest: {MANIFEST}")

    names: list[str] = []
    for line_number, raw_line in enumerate(
        MANIFEST.read_text(encoding="utf-8").splitlines(), 1
    ):
        name = raw_line.split("#", 1)[0].strip()
        if not name:
            continue
        if not STACK_NAME.fullmatch(name):
            raise ScriptError(
                f"invalid stack name {name!r} on {MANIFEST}:{line_number}"
            )
        if name in names:
            raise ScriptError(f"duplicate stack {name!r} on {MANIFEST}:{line_number}")
        compose = ROOT / "stacks" / name / "compose.yaml"
        if not compose.is_file():
            raise ScriptError(f"missing Compose file for stack {name!r}: {compose}")
        names.append(name)

    if not names:
        raise ScriptError(f"stack manifest is empty: {MANIFEST}")
    return tuple(names)


def main() -> int:
    try:
        print(" ".join(stack_names()))
    except ScriptError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
