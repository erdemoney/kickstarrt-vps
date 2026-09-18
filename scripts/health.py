#!/usr/bin/env python3
"""Read-only health checks for the host, firewall, and running stacks."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

from .common import EnvFile, ROOT, ScriptError, capture


STACKS = ("traefik", "media-server")
MEDIA_ENV = ROOT / "stacks" / "media-server" / ".env"
TRAEFIK_ENV = ROOT / "stacks" / "traefik" / ".env"


def command_output(command: tuple[str, ...]) -> tuple[bool, str]:
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError as exc:
        return False, str(exc)
    detail = (result.stdout.strip() or result.stderr.strip()).strip()
    return result.returncode == 0, detail


def check_command(
    label: str,
    command: tuple[str, ...],
    results: list[tuple[str, bool, str]],
    *,
    success_detail: str | None = "ok",
) -> None:
    if not shutil.which(command[0]):
        results.append((label, False, f"{command[0]} is not installed"))
        return
    ok, detail = command_output(command)
    if ok:
        detail = detail.splitlines()[0] if success_detail is None and detail else success_detail or "ok"
    else:
        detail = detail[-240:] if detail else "command failed"
    results.append((label, ok, detail))


def compose_services(stack: str, results: list[tuple[str, bool, str]]) -> None:
    compose = ROOT / "stacks" / stack / "compose.yaml"
    try:
        expected = capture(("docker", "compose", "-f", str(compose), "config", "--services"), f"load {stack} services").splitlines()
        raw = capture(("docker", "compose", "-f", str(compose), "ps", "--format", "json"), f"inspect {stack} services")
        if not raw:
            containers = []
        else:
            try:
                containers = json.loads(raw)
            except json.JSONDecodeError:
                containers = [json.loads(line) for line in raw.splitlines() if line.strip()]
        if isinstance(containers, dict):
            containers = [containers]
        by_service = {item.get("Service", item.get("Name", "")): item for item in containers}
        for service in expected:
            item = by_service.get(service)
            if item is None:
                results.append((f"{stack}/{service}", False, "not running"))
                continue
            state = str(item.get("State", "")).lower()
            health = str(item.get("Health", "")).lower()
            ok = state == "running" and health not in {"unhealthy", "dead"}
            detail = state or "unknown"
            if health:
                detail += f", {health}"
            results.append((f"{stack}/{service}", ok, detail))
    except (ScriptError, json.JSONDecodeError) as exc:
        results.append((f"{stack} services", False, str(exc)))


def main() -> int:
    results: list[tuple[str, bool, str]] = []
    media = EnvFile(MEDIA_ENV)
    traefik = EnvFile(TRAEFIK_ENV)
    config_dir = Path(media.get("CONFIG_DIR", str(ROOT / "data"))).expanduser()

    check_command("Docker", ("docker", "info"), results, success_detail="available")
    check_command("Tailscale", ("tailscale", "ip", "-4"), results, success_detail=None)
    check_command("UFW active", ("sudo", "ufw", "status"), results, success_detail="active")
    check_command("Docker firewall gate", ("sudo", "ufw-docker", "check"), results, success_detail="configured")
    check_command("internal network", ("docker", "network", "inspect", "internal"), results, success_detail="available")
    if shutil.which("docker"):
        ok, bouncers = command_output(("docker", "exec", "crowdsec", "cscli", "bouncers", "list"))
        registered = "traefik" in bouncers.lower()
        detail = "registered" if ok and registered else bouncers[-240:] if bouncers else "traefik bouncer unavailable"
        results.append(("CrowdSec bouncer", ok and registered, detail))
    else:
        results.append(("CrowdSec bouncer", False, "docker is not installed"))

    configured_tailnet = traefik.get("TAILNET_IP")
    if configured_tailnet:
        ok, detected = command_output(("tailscale", "ip", "-4"))
        results.append(("TAILNET_IP", ok and detected.splitlines()[:1] == [configured_tailnet], f"configured {configured_tailnet}; detected {detected or 'unavailable'}"))
    else:
        results.append(("TAILNET_IP", False, "not configured"))

    corefile = ROOT / "data" / "traefik" / "coredns.Corefile"
    readable = corefile.is_file() and bool(corefile.stat().st_mode & 0o004)
    results.append(("CoreDNS Corefile", readable, "readable" if readable else f"missing or not world-readable: {corefile}"))

    for stack in STACKS:
        compose_services(stack, results)

    print("kickstArrt health\n")
    check_width = max(len("CHECK"), *(len(label) for label, _, _ in results))
    print(f"{'STATUS':<6}  {'CHECK':<{check_width}}  DETAILS")
    for label, ok, detail in results:
        status = "OK" if ok else "FAIL"
        detail = " ".join(detail.split()) or "-"
        print(f"{status:<6}  {label:<{check_width}}  {detail}")
    failures = sum(not ok for _, ok, _ in results)
    print(f"\n{len(results) - failures}/{len(results)} checks passed.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
