#!/usr/bin/env python3
"""Schedule and run the unattended Git pull + stack update."""

from __future__ import annotations

import fcntl
import getpass
import shutil
import subprocess
import sys
from pathlib import Path

from .common import ROOT, ScriptError, capture, run


DEFAULT_CALENDAR = "*-*-* 03:00:00"
SERVICE_NAME = "kickstarrt-maintenance"
SERVICE_UNIT = f"/etc/systemd/system/{SERVICE_NAME}.service"
TIMER_UNIT = f"/etc/systemd/system/{SERVICE_NAME}.timer"
LOCK_FILE = Path("/tmp") / f"{SERVICE_NAME}.lock"


def require_just() -> str:
    just = shutil.which("just")
    if just is None:
        raise ScriptError("'just' not on PATH - install just before scheduling")
    return just


def require_clean_tree() -> None:
    status = capture(("git", "status", "--porcelain"), "check Git working tree")
    if status:
        raise ScriptError(
            "Git working tree is not clean; commit or remove local changes first"
        )


def commit() -> str:
    return capture(("git", "rev-parse", "HEAD"), "read current Git commit")


def run_maintenance() -> None:
    require_clean_tree()
    just = require_just()
    previous = commit()
    print(f"current commit: {previous}")
    run(("git", "pull", "--ff-only"), "pull latest main branch")
    deployed = commit()
    print(f"deployed commit: {deployed}")
    if deployed == previous:
        print("repository is already up to date; refreshing the stacks anyway")
    run((just, "update-all"), "update all stacks")
    run(
        (sys.executable, "-m", "scripts.health", "--deployment"),
        "post-maintenance health check",
    )
    print("maintenance completed successfully")


def locked_maintenance() -> None:
    LOCK_FILE.touch(mode=0o600, exist_ok=True)
    with LOCK_FILE.open("r+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ScriptError("another maintenance run is already in progress") from exc
        run_maintenance()


def write_unit(path: str, content: str) -> None:
    try:
        result = subprocess.run(
            ["sudo", "tee", path],
            input=content,
            text=True,
            stdout=subprocess.DEVNULL,
            check=False,
        )
    except OSError as exc:
        raise ScriptError(f"could not write {path}: {exc}") from exc
    if result.returncode:
        raise ScriptError(f"could not write {path}")


def schedule(calendar: str) -> None:
    if shutil.which("systemctl") is None:
        raise ScriptError(
            "systemd is unavailable; run 'just maintenance-run' manually instead"
        )
    if shutil.which("sudo") is None:
        raise ScriptError("sudo not found - install sudo before scheduling")
    just = require_just()
    require_clean_tree()
    if "\n" in calendar or "\r" in calendar or "\x00" in calendar:
        raise ScriptError("invalid newline or NUL in calendar")
    if shutil.which("systemd-analyze") is not None:
        run(("systemd-analyze", "calendar", calendar), "validate maintenance calendar")

    user = getpass.getuser()
    home = str(Path.home())
    print(
        f"This installs a systemd timer that runs '{just} maintenance-run' in '{ROOT}'\n"
        f"as user '{user}' on calendar '{calendar}' (local server time).\n"
        "The timer does not catch up missed runs, and two maintenance runs cannot overlap.\n"
        f"Two files are written under /etc/systemd/system with sudo:\n  {TIMER_UNIT}\n  {SERVICE_UNIT}"
    )
    try:
        confirmation = input("Proceed? [y/N] ")
    except EOFError:
        confirmation = ""
    if confirmation.lower() not in {"y", "yes"}:
        raise ScriptError("aborted")

    service = "\n".join(
        [
            "[Unit]",
            "Description=Pull and deploy kickstArrt updates",
            "After=network-online.target docker.service",
            "Wants=network-online.target",
            "",
            "[Service]",
            "Type=oneshot",
            f"User={user}",
            f"WorkingDirectory={ROOT}",
            f"Environment=HOME={home}",
            f"ExecStart={just} maintenance-run",
            "",
        ]
    )
    timer = "\n".join(
        [
            "[Unit]",
            "Description=Run kickstArrt maintenance",
            "",
            "[Timer]",
            f"OnCalendar={calendar}",
            "Persistent=false",
            f"Unit={SERVICE_NAME}.service",
            "",
            "[Install]",
            "WantedBy=timers.target",
            "",
        ]
    )
    write_unit(SERVICE_UNIT, service)
    write_unit(TIMER_UNIT, timer)
    run(("sudo", "systemctl", "daemon-reload"), "reload systemd")
    run(
        ("sudo", "systemctl", "enable", "--now", f"{SERVICE_NAME}.timer"),
        "enable maintenance timer",
    )
    print(f"\ninstalled {SERVICE_NAME}.{{service,timer}} - timer enabled and active")
    status()
    print("remove it later with 'just maintenance-unschedule'.")


def status() -> None:
    if shutil.which("systemctl") is None:
        raise ScriptError("systemd is unavailable")
    run(
        ("systemctl", "list-timers", f"{SERVICE_NAME}.timer", "--no-pager"),
        "list maintenance timer",
    )


def unschedule() -> None:
    if shutil.which("systemctl") is None:
        print("no systemd - nothing to uninstall")
        return
    if shutil.which("sudo") is None:
        raise ScriptError("sudo not found - run these commands as root")
    subprocess.run(
        ["sudo", "systemctl", "disable", "--now", f"{SERVICE_NAME}.timer"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    subprocess.run(
        ["sudo", "systemctl", "reset-failed", f"{SERVICE_NAME}.timer"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    run(("sudo", "rm", "-f", TIMER_UNIT, SERVICE_UNIT), "remove maintenance units")
    run(("sudo", "systemctl", "daemon-reload"), "reload systemd")
    print(f"removed {SERVICE_NAME}.{{timer,service}} and stopped the timer.")


def main(argv: list[str]) -> int:
    operation = argv[0] if argv else "run"
    if operation == "run":
        locked_maintenance()
    elif operation == "schedule":
        schedule(argv[1] if len(argv) > 1 else DEFAULT_CALENDAR)
    elif operation == "status":
        status()
    elif operation == "unschedule":
        unschedule()
    else:
        raise ScriptError(f"unknown maintenance operation: {operation}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ScriptError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
