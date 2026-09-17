#!/usr/bin/env python3
"""Interactively reconcile the stable, cross-service media wiring.

The script deliberately uses the applications' APIs instead of editing their
configuration files. HTTP is executed inside an existing container so Docker
service names (sonarr, radarr, etc.) remain private to the internal network.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parent.parent
MEDIA_ENV = ROOT / "stacks" / "media-server" / ".env"


class WireError(RuntimeError):
    pass


def env_value(name: str, default: str = "") -> str:
    """Read a simple KEY=value from the stack env, then honor the environment."""
    if name in os.environ:
        return os.environ[name]
    if MEDIA_ENV.exists():
        for line in MEDIA_ENV.read_text(encoding="utf-8").splitlines():
            if line.startswith(f"{name}="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return default


def api_key(app: str, config_dir: Path) -> str:
    path = config_dir / app / "config.xml"
    try:
        root = ET.parse(path).getroot()
    except FileNotFoundError as exc:
        raise WireError(f"{path} does not exist; start {app} once first") from exc
    except ET.ParseError as exc:
        raise WireError(f"cannot parse {path}: {exc}") from exc
    key = root.findtext("ApiKey", "").strip()
    if not key:
        raise WireError(f"{path} does not contain an API key")
    return key


def decypharr_token(config_dir: Path) -> str:
    config_path = config_dir / "decypharr" / "configs" / "config.json"
    auth_path = config_dir / "decypharr" / "configs" / "auth.json"
    documents: list[tuple[Path, dict[str, Any]]] = []
    for path in (auth_path, config_path):
        try:
            documents.append((path, json.loads(path.read_text(encoding="utf-8"))))
        except FileNotFoundError:
            continue
        except json.JSONDecodeError as exc:
            raise WireError(f"cannot parse {path}: {exc}") from exc

    # Current Decypharr stores authentication separately in auth.json. The
    # config.json fallback supports older releases that embedded the token.
    for path, document in documents:
        token = document.get("api_token", "")
        if not token and isinstance(document.get("auth"), dict):
            token = document["auth"].get("api_token", "")
        if token:
            return token

    if not documents:
        raise WireError(f"{auth_path} and {config_path} do not exist; complete Decypharr setup first")
    raise WireError(f"{auth_path} and {config_path} do not contain a Decypharr API token")


class DockerHTTP:
    """Run curl in a running container and return decoded JSON responses."""

    def request(
        self,
        source: str,
        method: str,
        url: str,
        key: str | None = None,
        body: Any = None,
        auth_header: str = "X-Api-Key",
    ) -> Any:
        # Decypharr's image is intentionally small and does not include curl.
        # Sonarr is on the same Docker network and is already used as the
        # stack's internal HTTP diagnostic container.
        transport = "sonarr" if source == "decypharr" else source
        command = [
            "docker",
            "exec",
            transport,
            "curl",
            "-sS",
            "-X",
            method,
            "-w",
            "\n__WIRE_HTTP_STATUS__%{http_code}",
            url,
        ]
        if key:
            command.extend(["-H", f"{auth_header}: {key}"])
        if body is not None:
            command.extend(["-H", "Content-Type: application/json", "--data", json.dumps(body)])
        try:
            result = subprocess.run(command, capture_output=True, text=True, check=False)
        except OSError as exc:
            raise WireError(f"could not run Docker: {exc}") from exc
        if result.returncode:
            detail = result.stderr.strip() or "curl failed"
            raise WireError(f"{source} request via {transport} failed: {detail}")
        marker = "\n__WIRE_HTTP_STATUS__"
        if marker not in result.stdout:
            raise WireError(f"{source} returned an invalid HTTP response")
        text, status = result.stdout.rsplit(marker, 1)
        if int(status) >= 400:
            raise WireError(f"{method} {url} returned HTTP {status}: {text.strip()[:300]}")
        if not text.strip():
            return None
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise WireError(f"{method} {url} returned non-JSON data") from exc


@dataclass
class Change:
    service: str
    description: str
    details: list[str]
    apply: Callable[[], None]


def field_value(resource: dict[str, Any], name: str) -> Any:
    for field in resource.get("fields", []):
        if field.get("name") == name:
            return field.get("value")
    return None


def set_field(resource: dict[str, Any], name: str, value: Any) -> None:
    for field in resource.setdefault("fields", []):
        if field.get("name") == name:
            field["value"] = value
            return
    resource["fields"].append({"name": name, "value": value})


def redacted(value: Any, name: str = "") -> str:
    if any(word in name.lower() for word in ("key", "token", "password", "secret")):
        return "<unchanged secret>" if value else "<empty>"
    return str(value)


def arr_download_client(
    http: DockerHTTP,
    app: str,
    key: str,
    implementation: str,
    contract: str,
    name: str,
    fields: dict[str, Any],
) -> Change | None:
    current = http.request(app, "GET", f"http://{app}:{8989 if app == 'sonarr' else 7878}/api/v3/downloadclient", key)
    existing = next((x for x in current if x.get("name") == name), None)
    desired_fields = {"enable": True, **fields}
    if existing:
        payload = json.loads(json.dumps(existing))
        changed = []
        for field, value in desired_fields.items():
            old = field_value(existing, field)
            if old != value:
                changed.append(f"{field}: {redacted(old, field)} -> {redacted(value, field)}")
                set_field(payload, field, value)
        if existing.get("implementation") != implementation:
            changed.append(f"implementation: {existing.get('implementation')} -> {implementation}")
            payload["implementation"] = implementation
        if not changed:
            return None
        endpoint = f"http://{app}:{8989 if app == 'sonarr' else 7878}/api/v3/downloadclient/{existing['id']}"
        return Change(
            app,
            f"update {name}",
            changed,
            lambda: http.request(app, "PUT", endpoint, key, payload),
        )

    payload = {
        "name": name,
        "enable": True,
        "protocol": "torrent" if implementation == "QBittorrent" else "usenet",
        "implementation": implementation,
        "implementationName": implementation,
        "configContract": contract,
        "fields": [{"name": field, "value": value} for field, value in desired_fields.items()],
        "priority": 0,
    }
    endpoint = f"http://{app}:{8989 if app == 'sonarr' else 7878}/api/v3/downloadclient"
    return Change(
        app,
        f"create {name}",
        [f"{field}: {redacted(value, field)}" for field, value in desired_fields.items()],
        lambda: http.request(app, "POST", endpoint, key, payload),
    )


def root_folder_change(http: DockerHTTP, app: str, key: str, path: str) -> Change | None:
    port = 8989 if app == "sonarr" else 7878
    endpoint = f"http://{app}:{port}/api/v3/rootfolder"
    current = http.request(app, "GET", endpoint, key)
    if any(folder.get("path") == path for folder in current):
        return None
    return Change(
        app,
        f"create root folder {path}",
        [f"path: {path}"],
        lambda: http.request(app, "POST", endpoint, key, {"path": path}),
    )


def decypharr_change(http: DockerHTTP, token: str, keys: dict[str, str]) -> Change | None:
    endpoint = "http://decypharr:8282/api/config"
    auth = f"Bearer {token}"
    current = http.request("decypharr", "GET", endpoint, auth, auth_header="Authorization")
    arrs = list(current.get("arrs", []))
    desired = {
        "Sonarr": {"name": "Sonarr", "host": "http://sonarr:8989", "token": keys["sonarr"]},
        "Radarr": {"name": "Radarr", "host": "http://radarr:7878", "token": keys["radarr"]},
    }
    changed = []
    for name, item in desired.items():
        existing = next((arr for arr in arrs if arr.get("name", "").lower() == name.lower()), None)
        if existing is None:
            arrs.append({**item, "skip_repair": False})
            changed.append(f"add {name}: {item['host']}")
            continue
        for field in ("host", "token"):
            if existing.get(field) != item[field]:
                changed.append(f"{name} {field}: {redacted(existing.get(field), field)} -> {redacted(item[field], field)}")
                existing[field] = item[field]
    if not changed:
        return None
    return Change(
        "decypharr",
        "update Arr integrations",
        changed,
        lambda: http.request(
            "decypharr", "POST", endpoint, auth, {"arrs": arrs}, "Authorization"
        ),
    )


def prowlarr_change(http: DockerHTTP, token: str, keys: dict[str, str]) -> Change | None:
    endpoint = "http://prowlarr:9696/api/v1/applications"
    current = http.request("prowlarr", "GET", endpoint, token)
    desired = {
        "Sonarr": ("http://sonarr:8989", keys["sonarr"]),
        "Radarr": ("http://radarr:7878", keys["radarr"]),
    }
    changes: list[str] = []
    updates: list[tuple[str, dict[str, Any]]] = []
    for name, (base_url, key) in desired.items():
        existing = next((app for app in current if app.get("name", "").lower() == name.lower()), None)
        if existing:
            payload = json.loads(json.dumps(existing))
            local_changes = []
            for field, value in (
                ("baseUrl", base_url),
                ("apiKey", key),
                ("prowlarrUrl", "http://prowlarr:9696"),
                ("syncLevel", "full"),
            ):
                old = field_value(existing, field)
                if old != value:
                    local_changes.append(f"{field}: {redacted(old, field)} -> {redacted(value, field)}")
                    set_field(payload, field, value)
            if local_changes:
                changes.extend([f"{name} {item}" for item in local_changes])
                updates.append((f"http://prowlarr:9696/api/v1/applications/{existing['id']}", payload))
            continue
        payload = {
            "name": name,
            "implementation": name,
            "implementationName": name,
            "configContract": f"{name}Settings",
            "enable": True,
            "syncLevel": "full",
            "fields": [
                {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                {"name": "baseUrl", "value": base_url},
                {"name": "apiKey", "value": key},
                {"name": "syncLevel", "value": "full"},
            ],
            "tags": [],
        }
        changes.append(f"add {name}: {base_url}")
        updates.append((endpoint, payload))
    if not changes:
        return None

    def apply() -> None:
        for url, payload in updates:
            http.request("prowlarr", "PUT" if payload.get("id") else "POST", url, token, payload)

    return Change("prowlarr", "update Arr applications", changes, apply)


def confirm(change: Change) -> bool:
    print(f"\n{change.service}: {change.description}")
    for detail in change.details:
        print(f"  - {detail}")
    answer = input("Apply this change? [y/N] ").strip().lower()
    return answer in {"y", "yes"}


def main() -> int:
    parser = argparse.ArgumentParser(description="Interactively wire the media services")
    parser.add_argument("--dry-run", action="store_true", help="discover and display changes without applying them")
    parser.add_argument("--yes", action="store_true", help="apply all planned changes without prompting")
    args = parser.parse_args()
    if not args.dry_run and not args.yes and not sys.stdin.isatty():
        print("refusing to mutate services without a terminal; use --yes explicitly", file=sys.stderr)
        return 2

    config_dir = Path(env_value("CONFIG_DIR", str(ROOT / "data"))).expanduser()
    try:
        keys = {app: api_key(app, config_dir) for app in ("sonarr", "radarr", "prowlarr")}
        token = decypharr_token(config_dir)
        http = DockerHTTP()
        changes: list[Change] = []
        for app, path in (("sonarr", "/mnt/shows"), ("radarr", "/mnt/movies")):
            change = root_folder_change(http, app, keys[app], path)
            if change:
                changes.append(change)
            port = 8989 if app == "sonarr" else 7878
            for implementation, contract, name, fields in (
                (
                    "QBittorrent",
                    "QBittorrentSettings",
                    "Decypharr (debrid)",
                    {"host": "decypharr", "port": 8282, "username": f"http://{app}:{port}", "password": keys[app], "category": app},
                ),
                (
                    "Sabnzbd",
                    "SabnzbdSettings",
                    "Decypharr (usenet)",
                    {"host": "decypharr", "port": 8282, "urlBase": "/sabnzbd", "username": f"http://{app}:{port}", "password": keys[app], "category": app},
                ),
            ):
                change = arr_download_client(http, app, keys[app], implementation, contract, name, fields)
                if change:
                    changes.append(change)
        for change in (decypharr_change(http, token, keys), prowlarr_change(http, keys["prowlarr"], keys)):
            if change:
                changes.append(change)
    except WireError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not changes:
        print("No wiring changes are needed.")
        return 0
    print(f"\nPlanned changes: {len(changes)} checkpoint(s)")
    if args.dry_run:
        for change in changes:
            print(f"\n{change.service}: {change.description}")
            for detail in change.details:
                print(f"  - {detail}")
        return 0

    applied = 0
    for change in changes:
        if not args.yes and not confirm(change):
            print("Skipped; stopping before the next checkpoint.")
            break
        try:
            change.apply()
        except WireError as exc:
            print(f"error applying {change.service}/{change.description}: {exc}", file=sys.stderr)
            print(f"Applied {applied} checkpoint(s); stopping to avoid cascading changes.", file=sys.stderr)
            return 1
        print(f"Applied: {change.service} - {change.description}")
        applied += 1
    print(f"Completed {applied}/{len(changes)} checkpoint(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
