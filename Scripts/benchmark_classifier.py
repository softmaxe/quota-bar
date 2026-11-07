#!/usr/bin/env -S uv run --script
"""Compare two release probes on a deterministic long-string transcript workload."""

import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--iterations", type=int, default=7)
    parser.add_argument("--padding-bytes", type=int, default=65_536)
    parser.add_argument("--dense-escapes", action="store_true")
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("--iterations must be positive")
    if args.padding_bytes < 0:
        parser.error("--padding-bytes must be nonnegative")
    padding = (
        ("\\\"" * ((args.padding_bytes + 1) // 2))[:args.padding_bytes]
        if args.dense_escapes else "x" * args.padding_bytes
    )
    binaries = {"before": args.before.resolve(), "after": args.after.resolve()}
    results: dict[str, list[float]] = {label: [] for label in binaries}
    with tempfile.TemporaryDirectory(prefix="quotabar-classifier-") as directory:
        root = Path(directory)
        projects = root / "claude/projects/app"
        projects.mkdir(parents=True)
        for file_index in range(16):
            with (projects / f"session-{file_index}.jsonl").open("w") as output:
                for line_index in range(128):
                    identifier = f"{file_index}-{line_index}"
                    row = {
                        "padding": padding,
                        "type": "user" if line_index % 2 else "assistant",
                        "timestamp": "2026-11-07T02:00:00.000Z",
                        "requestId": identifier,
                        "message": {
                            "id": identifier,
                            "model": "claude-opus-5",
                            "usage": {"input_tokens": 10, "output_tokens": 2},
                        },
                    }
                    output.write(json.dumps(row) + "\n")
        environment = dict(os.environ)
        for key, child in {
            "CLAUDE_CONFIG_DIR": "claude", "CODEX_HOME": "codex",
            "PI_CODING_AGENT_DIR": "pi", "OPENCODE_DATA_HOME": "opencode",
        }.items():
            environment[key] = str(root / child)
        for iteration in range(args.iterations):
            order = list(binaries.items())
            if iteration % 2:
                order.reverse()
            for label, binary in order:
                completed = subprocess.run(
                    [str(binary), "--benchmark-cost", "--provider", "claude", "--iterations", "1"],
                    env=environment, capture_output=True, text=True, check=True,
                )
                if "same_snapshot=yes" not in completed.stdout:
                    raise RuntimeError("Cold and incremental snapshots differ")
                match = re.search(r"empty_db_ms median=([\d.]+)", completed.stdout)
                if match is None:
                    raise RuntimeError("Missing benchmark timing")
                results[label].append(float(match[1]))
    print(json.dumps({
        label: {"median_ms": statistics.median(values), "runs_ms": values}
        for label, values in results.items()
    }, indent=2))


if __name__ == "__main__":
    main()
