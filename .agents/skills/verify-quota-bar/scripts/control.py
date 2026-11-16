#!/usr/bin/env python3
"""Check a QuotaBar build and capture its existing native menu verifier's proof."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import time
from typing import Any

ROOT = Path(__file__).resolve().parents[4]
LOCK = Path(f"/tmp/quotabar-menu-verification-{os.getuid()}.lock")
SUITE = "QuotaBarMenuLifecycleVerifier"
PASS = "Menu lifecycle, status-button toggling, dismissal, and foreground preservation checks passed"


def query(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, check=False)


def save(path: Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def competitors() -> list[str]:
    rows = query("ps", "-axo", "pid=,comm=,args=").stdout.splitlines()
    # Only app processes: shell command text can also contain these flags.
    return [row.strip() for row in rows if any(
        marker in row for marker in ("/QuotaBar --verify-menu-interaction", "/QuotaBar --preview-interface")
    ) and " /bin/" not in row and "control.py" not in row]


def doctor() -> dict[str, Any]:
    if platform.system() != "Darwin":
        raise RuntimeError("Native verification requires a logged-in macOS desktop.")
    binary = (ROOT / ".build/debug/QuotaBar").resolve(strict=True)
    if not os.access(binary, os.X_OK):
        raise RuntimeError("Build with make build first.")
    if competitors():
        raise RuntimeError("Another preview/verifier is running; do not share desktop input or suites.")
    console = query("stat", "-f", "%Su", "/dev/console").stdout.strip()
    if console in ("", "root", "loginwindow"):
        raise RuntimeError("No logged-in desktop user; native menu verification is unavailable.")
    return {
        "binary": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "revision": query("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.strip(),
        "working_tree": query("git", "-C", str(ROOT), "status", "--short").stdout.strip(),
        "macos": platform.mac_ver()[0], "console_user": console,
        "scope": "Fallback AppKit menu verifier; not native expanded-session pointer proof",
    }


def interrupted(signum: int, frame: Any) -> None:
    raise KeyboardInterrupt(f"Received signal {signum}")


def run_menu(evidence: Path) -> int:
    evidence = evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    if any(evidence.iterdir()):
        raise RuntimeError("Use an empty evidence directory so earlier proof cannot be overwritten.")
    process: subprocess.Popen[str] | None = None
    lock_owned = False
    result: dict[str, Any] = {"passed": False, "feature": "quota-fallback-lifecycle", "entry": "--verify-menu-interaction"}
    try:
        # Defer handled signals until ownership is recorded, including the mkdir boundary.
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            LOCK.mkdir(mode=0o700)
            lock_owned = True
            save(LOCK / "owner.json", {
                "evidence": str(evidence), "helper_pid": os.getpid(),
                "started": query("ps", "-p", str(os.getpid()), "-o", "lstart=").stdout.strip(),
            })
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        build = doctor()
        save(evidence / "doctor.json", build)
        command = [build["binary"], "--verify-menu-interaction"]
        with (evidence / "stdout.txt").open("w") as stdout, (evidence / "stderr.txt").open("w") as stderr:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr, text=True)
            save(evidence / "launch.json", {
                "command": command, "pid": process.pid,
                "started": query("ps", "-p", str(process.pid), "-o", "lstart=").stdout.strip(),
            })
            # This is an observation sample, not proof that no transient socket ever existed.
            (evidence / "open-files.txt").write_text(query("lsof", "-nP", "-p", str(process.pid)).stdout)
            (evidence / "sockets.txt").write_text(query("lsof", "-nP", "-a", "-p", str(process.pid), "-i").stdout)
            result["exit_code"] = process.wait(timeout=30)
        result["assertion_summary_present"] = PASS in (evidence / "stdout.txt").read_text()
        preferences = query("defaults", "export", SUITE, "-")
        (evidence / "preferences-after.txt").write_text(preferences.stdout + preferences.stderr)
        # removePersistentDomain may leave an empty domain registered with cfprefsd.
        result["suite_empty_after_app"] = preferences.returncode != 0 or plistlib.loads(
            preferences.stdout.encode()
        ) == {}
        result["binary_unchanged"] = doctor()["sha256"] == build["sha256"]
        result["passed"] = result["exit_code"] == 0 and all(result[key] for key in (
            "assertion_summary_present", "suite_empty_after_app", "binary_unchanged"
        ))
    except (Exception, KeyboardInterrupt) as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        # Only this run's child and ephemeral verifier suite are cleaned up.
        if process is not None and not competitors():
            query("defaults", "delete", SUITE)
        result["child_exited"] = process is None or process.poll() is not None
        result["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        save(evidence / "result.json", result)
        if lock_owned:
            (LOCK / "owner.json").unlink(missing_ok=True)
            LOCK.rmdir()
        save(evidence / "cleanup.json", {
            "child_exited": result["child_exited"], "lock_removed": not LOCK.exists(),
            "evidence_retained": (evidence / "result.json").is_file(),
        })
    print(json.dumps(result, indent=2))
    print(f"Evidence retained at {evidence}")
    return 0 if result["passed"] else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["doctor", "menu"])
    parser.add_argument("evidence", nargs="?", type=Path)
    args = parser.parse_args()
    if args.command == "doctor":
        print(json.dumps(doctor(), indent=2))
        return 0
    if args.evidence is None:
        parser.error("menu requires an evidence directory")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    return run_menu(args.evidence)


if __name__ == "__main__":
    raise SystemExit(main())
