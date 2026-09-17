#!/usr/bin/env python3
"""Compare pinned Compose image tags with Docker Hub and GHCR."""

from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path

from .common import ROOT


COMPOSE_FILES = (ROOT / "stacks" / "traefik" / "compose.yaml", ROOT / "stacks" / "media-server" / "compose.yaml")
VERSION_RE = re.compile(r"^v?[0-9]+(\.[0-9]+){1,4}$")


def http_json(url: str, headers: dict[str, str] | None = None) -> dict:
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def compose_images(path: Path) -> list[tuple[str, str]]:
    service = None
    images = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^  (\w[\w-]+):$", line)
        if match:
            service = match.group(1)
        match = re.match(r"^    image: (\S+)$", line)
        if match and service:
            images.append((service, match.group(1)))
    return images


def split_image(image: str) -> tuple[str, str, str]:
    node = image.partition("@")[0]
    name, separator, tag = node.partition(":")
    if not separator:
        tag = "latest"
    parts = name.split("/")
    if len(parts) == 1:
        return "docker.io", f"library/{name}", tag
    host = parts[0]
    if "." in host or ":" in host or host == "localhost":
        if host == "lscr.io":
            return "docker.io", name.split("/", 1)[1], tag
        return host, "/".join(parts[1:]), tag
    return "docker.io", name, tag


def latest_docker_hub(repository: str) -> str | None:
    try:
        data = http_json(f"https://hub.docker.com/v2/repositories/{repository}/tags?page_size=100&ordering=last_updated")
    except Exception:
        return None
    return next((item["name"] for item in data.get("results", []) if VERSION_RE.match(item["name"])), None)


def latest_ghcr(repository: str) -> str | None:
    try:
        token = http_json(f"https://ghcr.io/token?scope=repository:{repository}:pull")["token"]
        tags = []
        url = f"https://ghcr.io/v2/{repository}/tags/list?n=10000"
        while url:
            request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
            with urllib.request.urlopen(request, timeout=20) as response:
                tags.extend(json.load(response).get("tags", []))
                url = ""
                for link in response.headers.get("Link", "").split(","):
                    if 'rel="next"' in link:
                        url = link[link.index("<") + 1 : link.index(">")]
    except Exception:
        return None
    candidates = sorted((tag for tag in tags if VERSION_RE.match(tag)), key=lambda tag: [int(part) for part in re.sub(r"^v", "", tag).split(".")])
    return candidates[-1] if candidates else None


def main() -> int:
    rows = []
    seen = set()
    for path in COMPOSE_FILES:
        for service, image in compose_images(path):
            key = (path, image)
            if key in seen:
                continue
            seen.add(key)
            registry, repository, pinned = split_image(image)
            if registry == "docker.io":
                latest = latest_docker_hub(repository)
            elif registry == "ghcr.io":
                latest = latest_ghcr(repository)
            else:
                latest = "(unsupported registry)"
            latest_version = latest.lstrip("v") if isinstance(latest, str) else None
            status = "?" if latest_version is None else ("up-to-date" if latest_version == pinned.lstrip("v") else "UPDATE")
            rows.append((str(path.relative_to(ROOT)), service, image, latest or "-", status))

    headers = ("compose", "service", "image", "latest", "status")
    display = [list(row) for row in rows]
    widths = [max(len(str(row[index])) for row in display + [list(headers)]) + 2 for index in range(len(headers))]
    formatter = "  ".join("{%d:<%d}" % (index, widths[index]) for index in range(len(headers)))
    print(formatter.format(*headers))
    print("  ".join("-" * (width - 2) for width in widths))
    for row in display:
        print(formatter.format(*[str(item) for item in row]))
    updates = sum(1 for row in display if row[-1] == "UPDATE")
    print(f"\n{updates} image(s) with newer tags available.")
    return 1 if updates else 0


if __name__ == "__main__":
    raise SystemExit(main())
