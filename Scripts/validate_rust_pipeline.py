#!/usr/bin/env -S uv run --script
"""Compare isolated Swift/Rust builds through real scanning, SQLite and pricing."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import shutil
import sqlite3
import statistics
import subprocess
import tarfile
import time
from typing import Any

BASELINE = "f8df98b129c9138ccb9e6290d6c801e805fed1be"
SOURCE_ROOTS = ["Package.swift", "rust-toolchain.toml", "Scripts/swift.sh", "Scripts/build_rust.sh", "Sources", "Rust/QuotaBarCore"]
SOURCE_SUFFIXES = {".swift", ".rs", ".h", ".c", ".modulemap", ".json", ".html", ".js", ".css", ".png", ".svg", ".toml", ".lock", ".sh"}


def save(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def allowed_source(name: str) -> bool:
    path = Path(name)
    if path.is_absolute() or ".." in path.parts or any(part in {"target", ".build", ".git"} or part.startswith(".env") for part in path.parts):
        return False
    return path.suffix in SOURCE_SUFFIXES and any(name == root or name.startswith(root + "/") for root in SOURCE_ROOTS)


def copy_source(repository: Path, destination: Path, revision: str | None) -> dict[str, str]:
    """Copy only build-source whitelist entries, never Git metadata or ignored local files."""
    destination.mkdir(parents=True)
    hashes: dict[str, str] = {}
    if revision is not None:
        listed = subprocess.check_output(["git", "ls-tree", "-r", "-z", "--name-only", revision, "--", *SOURCE_ROOTS], cwd=repository)
        paths = [name for name in listed.decode().split("\0") if name and allowed_source(name)]
        archive = subprocess.check_output(["git", "archive", revision, "--", *paths], cwd=repository)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            for member in source:
                if not member.isfile() or not allowed_source(member.name):
                    continue
                stream = source.extractfile(member)
                assert stream is not None
                data = stream.read()
                target = destination / member.name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(member.mode)
                hashes[member.name] = hashlib.sha256(data).hexdigest()
    else:
        paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *SOURCE_ROOTS], cwd=repository)
        for name in sorted(set(paths.decode().split("\0"))):
            if not name or not allowed_source(name):
                continue
            original = repository / name
            if not original.is_file() or original.is_symlink():
                continue
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target)
            hashes[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    return hashes


def build_probe(source: Path, hook: str, log: Path, source_hashes: dict[str, str] | None = None) -> Path:
    main = source / "Sources/QuotaBarProbe/main.swift"
    content = main.read_text()
    marker = "let arguments = Array(CommandLine.arguments.dropFirst())"
    if content.count(marker) != 1:
        raise RuntimeError("Cannot find the unique probe dispatch insertion point")
    main.write_text(content.replace(marker, hook + "\n" + marker))
    command = [str(source / "Scripts/swift.sh"), "build", "-c", "release", "--product", "QuotaBarProbe"]
    save(log.with_suffix(".command.json"), {"command": command, "cwd": str(source)})
    with log.open("w") as output:
        subprocess.run(command, cwd=source, stdout=output, stderr=subprocess.STDOUT, check=True)
    binary = source / ".build/release/QuotaBarProbe"
    save(binary.with_name(binary.name + ".validation.json"), {
        "hook_sha256": hashlib.sha256(hook.encode()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "source_sha256": source_hashes,
    })
    return binary


def database_state(database: Path) -> dict[str, Any]:
    def cell(value: Any) -> Any:
        return {"blob_hex": value.hex()} if isinstance(value, bytes) else value
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        schema = connection.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").fetchall()
        tables = connection.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").fetchall()
        rows = {}
        raw_rows = {}
        for (name,) in tables:
            quoted = name.replace('"', '""')
            values = [[cell(value) for value in row] for row in connection.execute(f'SELECT * FROM "{quoted}"')]
            raw_rows[name] = sorted(values, key=repr)
            columns = [column[1] for column in connection.execute(f'PRAGMA table_info("{quoted}")')]
            normalized = [list(row) for row in values]
            if name == "file_cursor" and "resume_state" in columns:
                index = columns.index("resume_state")
                for row in normalized:
                    if row[index] is not None:
                        # Swift's JSONEncoder does not promise dictionary key order. Preserve
                        # every value while comparing this known JSON column semantically.
                        row[index] = json.dumps(json.loads(row[index]), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            rows[name] = sorted(normalized, key=repr)
        return {"schema": schema, "tables": rows, "raw_tables": raw_rows}


def equivalent_states(states: dict[str, Any]) -> bool:
    def comparable(state: dict[str, Any]) -> dict[str, Any]:
        return {"phases": state["phases"], "schema": state["database"]["schema"], "tables": state["database"]["tables"]}
    return comparable(states["before"]) == comparable(states["after"])


def probe(binary: Path, database: Path, fixture: Path, tab: str, mode: str, raw: Path) -> dict[str, Any]:
    database.parent.mkdir(parents=True, exist_ok=True)
    runtime = raw.parent / "runtime-tmp"
    runtime.mkdir(exist_ok=True)
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(runtime) + "/", "LANG": "en_US.UTF-8", "TZ": "Asia/Shanghai"}
    protected = [Path.home() / path for path in [".codex", ".claude", ".config/claude", ".local/share/opencode", ".pi", "Library/Keychains", "Library/Application Support/QuotaBar"]]
    profile = "(version 1) (allow default) (deny network*) " + " ".join(
        f"(deny file-read* file-write* (subpath {json.dumps(str(path))}))" for path in protected
    ) + ' (deny process-exec (literal "/usr/bin/security"))'
    sandbox = raw.parent / "probe.sb"
    sandbox.write_text(profile + "\n")
    command = ["/usr/bin/sandbox-exec", "-f", str(sandbox), str(binary), "--rust-validation", str(database), str(fixture), tab, mode]
    started = time.perf_counter()
    completed = subprocess.run(command, env=environment, capture_output=True, text=True)
    wall_ms = (time.perf_counter() - started) * 1000
    save(raw, {"command": command, "environment": environment, "returncode": completed.returncode,
               "stdout": completed.stdout, "stderr": completed.stderr, "process_wall_ms": wall_ms})
    completed.check_returncode()
    result = json.loads(completed.stdout)
    result["process_wall_ms"] = wall_ms
    return result


def row(identifier: str, timestamp: str, output: int = 2) -> dict[str, Any]:
    return {"type": "assistant", "timestamp": timestamp, "requestId": identifier,
            "message": {"id": identifier, "model": "claude-opus-5", "usage": {"input_tokens": 10, "output_tokens": output}}}


def encoded(value: dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False)


def differential(output: Path, binaries: dict[str, Path], timestamp: str) -> None:
    root = output / "differential"
    fixture = root / "fixture"
    project = fixture / "claude/projects/app"
    project.mkdir(parents=True)
    transcript = project / "session.jsonl"

    def checkpoint(phase: str) -> None:
        states = {}
        for label, binary in binaries.items():
            database = root / label / "usage.sqlite"
            result = probe(binary, database, fixture, "claude", "once", root / f"{phase}-{label}.raw.json")
            states[label] = {"phases": result["phases"], "database": database_state(database)}
        save(root / f"{phase}.json", states)
        equal = equivalent_states(states)
        print(json.dumps({"phase": phase, "equivalent": equal}), flush=True)
        if not equal:
            raise RuntimeError(f"Snapshot/schema/rows/cursor mismatch at {phase}; inspect {root / (phase + '.json')}")

    initial = [row("one", timestamp), row("one", timestamp, 7), row("other", timestamp)]
    idless = row("", timestamp)
    del idless["requestId"]
    del idless["message"]["id"]
    idless["message"]["content"] = [{"type": "text", "text": 'Synthetic escaped \\"text\\" and Unicode 世界'}]
    initial.append(idless)
    loose = row("loose", timestamp)
    loose["message"]["usage"] = {"input_tokens": "10", "output_tokens": 2.9, "cache_read_input_tokens": True,
                                  "cache_creation_input_tokens": 9, "cache_creation": {"ephemeral_1h_input_tokens": 3}, "speed": "FAST"}
    initial.append(loose)
    invalid = row("invalid", timestamp)
    invalid["message"]["usage"] = {"input_tokens": -1, "output_tokens": 2}
    initial.extend([invalid, {"type": "user", "message": {"usage": {"input_tokens": 999999}}}])
    transcript.write_text("\n".join(map(encoded, initial)) + '\n{"type":"assistant"')
    checkpoint("initial-incomplete")
    checkpoint("unchanged")
    with transcript.open("a") as file:
        file.write('}\n' + encoded(row("one", timestamp, 11)) + "\n" + encoded(row("append", timestamp)) + "\n")
    checkpoint("append-and-replay")
    copied = project / "copied-session.jsonl"
    copied.write_bytes(transcript.read_bytes())
    checkpoint("copied-dedup")
    transcript.write_text(encoded(row("replacement", timestamp)) + "\n")
    checkpoint("rewrite-preserves-history")
    unknown = row("unknown-price", timestamp)
    unknown["message"]["model"] = "synthetic-unpriced-model"
    with transcript.open("a") as file:
        file.write(encoded(unknown) + "\n" + encoded(invalid) + "\n{malformed JSON\n")
    checkpoint("unknown-and-invalid")
    transcript.unlink()
    copied.unlink()
    checkpoint("deleted-retains-history")


def benchmark_fixture(root: Path, workload: str, timestamp: str) -> tuple[str, Path, int]:
    """Match benchmark_classifier.py's 16 x 128 shape and add real append work."""
    tab = "codex" if workload == "codex" else "claude"
    project = root / ("codex/sessions" if tab == "codex" else "claude/projects/app")
    project.mkdir(parents=True)
    padding = "" if workload in {"short", "codex"} else ('\\"' * 32768 if workload == "dense" else "x" * 65536)

    def event(index: int) -> dict[str, Any]:
        return {"type": "event_msg", "timestamp": timestamp, "payload": {"type": "token_count", "info": {
            "last_token_usage": {"input_tokens": 10, "cached_input_tokens": 2, "output_tokens": 2},
            "total_token_usage": {"input_tokens": index * 10, "output_tokens": index * 2}}}}

    for file_index in range(16):
        with (project / f"session-{file_index}.jsonl").open("w") as file:
            if tab == "codex":
                file.write(encoded({"type": "turn_context", "timestamp": timestamp, "payload": {"model": "gpt-5.6-sol"}}) + "\n")
            for line_index in range(128):
                if tab == "claude":
                    value = {"padding": padding, **row(f"{file_index}-{line_index}", timestamp)}
                    value["type"] = "user" if line_index % 2 else "assistant"
                else:
                    value = event(line_index + 1) if line_index % 2 == 0 else {"type": "event_msg", "payload": {"type": "agent_message", "message": "Synthetic text"}}
                file.write(encoded(value) + "\n")
    appended = [row(f"active-append-{index}", timestamp) if tab == "claude" else event(200 + index) for index in range(64)]
    (root / "append.jsonl").write_text("\n".join(map(encoded, appended)) + "\n")
    target = project / "session-0.jsonl"
    return tab, target, sum(path.stat().st_size for path in project.glob("*.jsonl"))


def benchmarks(output: Path, binaries: dict[str, Path], timestamp: str, iterations: int, workloads: list[str]) -> None:
    results: dict[str, Any] = {}
    for workload in workloads:
        root = output / "benchmarks" / workload
        fixture = root / "fixture"
        tab, target, byte_count = benchmark_fixture(fixture, workload, timestamp)
        original_size = target.stat().st_size
        samples: dict[str, list[dict[str, Any]]] = {label: [] for label in binaries}
        for iteration in range(iterations):
            states = {}
            order = list(binaries.items())
            if iteration % 2:
                order.reverse()
            for label, binary in order:
                with target.open("r+b") as file:
                    file.truncate(original_size)
                database = root / f"{label}-{iteration}" / "usage.sqlite"
                result = probe(binary, database, fixture, tab, "benchmark", root / f"{label}-{iteration}.raw.json")
                phases = result["phases"]
                if phases["initial"] != phases["unchanged"] or phases["append"] != phases["append-unchanged"]:
                    raise RuntimeError(f"Unchanged scan changed its snapshot: {workload}/{label}/{iteration}")
                if phases["append"]["snapshot"]["windowTokens"] <= phases["initial"]["snapshot"]["windowTokens"]:
                    raise RuntimeError(f"Append fixture added no usage: {workload}/{label}/{iteration}")
                states[label] = {"phases": phases, "database": database_state(database)}
                samples[label].append({"times_ms": result["times_ms"], "process_wall_ms": result["process_wall_ms"]})
            save(root / f"comparison-{iteration}.json", states)
            if not equivalent_states(states):
                raise RuntimeError(f"Benchmark snapshot/database mismatch: {workload}/{iteration}")
        summaries = {}
        for label, runs in samples.items():
            metrics = {key: [sample["times_ms"][key] for sample in runs] for key in ["initial", "unchanged", "append", "append-unchanged"]}
            metrics["process_wall"] = [sample["process_wall_ms"] for sample in runs]
            summaries[label] = {key: {"median_ms": statistics.median(values), "min_ms": min(values), "max_ms": max(values), "runs_ms": values} for key, values in metrics.items()}
        results[workload] = {"bytes": byte_count, "files": 16, "records_per_file": 128, "append_records": 64, "summary": summaries}
        save(output / "benchmark-summary.json", results)
        print(json.dumps({"workload": workload, "summary": summaries}), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--revision", default=BASELINE)
    parser.add_argument("--output", type=Path, default=Path("build/rust-validation/pipeline"))
    parser.add_argument("--iterations", type=int, default=7)
    parser.add_argument("--skip-benchmarks", action="store_true")
    parser.add_argument("--workloads", choices=["short", "plain", "dense", "codex"], nargs="+", default=["short", "plain", "dense", "codex"])
    parser.add_argument("--ablate-aggregator-source", type=Path, help="Compare a validated candidate copy with only its old Swift aggregator restored")
    parser.add_argument("--ablate-scanner-source", type=Path, help="Compare a validated candidate source copy with only its old Swift scanner restored")
    parser.add_argument("--reuse-sources", type=Path, help="Reuse a previous build after matching every input source hash")
    parser.add_argument("--before-probe", type=Path, help="Reuse a probe built with this exact hook; requires --after-probe")
    parser.add_argument("--after-probe", type=Path, help="Reuse a probe built with this exact hook; requires --before-probe")
    args = parser.parse_args()
    if args.iterations < 1 or bool(args.before_probe) != bool(args.after_probe):
        parser.error("iterations must be positive; reusable probes must be supplied together")
    ablation_source = args.ablate_scanner_source or args.ablate_aggregator_source
    if args.ablate_scanner_source and args.ablate_aggregator_source:
        parser.error("choose one kernel for ablation")
    if ablation_source and (args.before_probe or args.reuse_sources):
        parser.error("kernel ablation cannot be combined with probe/source reuse")
    if args.before_probe and args.reuse_sources:
        parser.error("choose reusable probes or reusable source builds")
    repository = args.repository.resolve()
    output = args.output.resolve()
    if output.exists():
        parser.error("output must be a new directory; existing validation evidence is never overwritten")
    output.mkdir(parents=True)
    shutil.copy2(Path(__file__), output / "script-used.py")
    shutil.copy2(repository / "Scripts/fixtures/rust_pipeline_hook.swift", output / "hook-used.swift")
    revision = subprocess.check_output(["git", "rev-parse", args.revision], cwd=repository, text=True).strip()
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT02:00:00Z")
    metadata: dict[str, Any] = {"baseline_revision": revision, "fixture_timestamp": timestamp, "iterations": args.iterations,
                               "repository": str(repository), "workloads": args.workloads, "timezone": "Asia/Shanghai", "source_whitelist": SOURCE_ROOTS}
    metadata["machine"] = {
        "cpu": subprocess.check_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "memory_bytes": int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True)),
        "macos": subprocess.check_output(["/usr/bin/sw_vers", "-productVersion"], text=True).strip(),
        "swift": subprocess.check_output([str(repository / "Scripts/swift.sh"), "--version"], text=True).strip(),
        "rust": subprocess.check_output(["rustc", "--version"], text=True).strip() if shutil.which("rustc") else None,
    }
    hook = (repository / "Scripts/fixtures/rust_pipeline_hook.swift").read_text()
    metadata["hook_sha256"] = hashlib.sha256(hook.encode()).hexdigest()
    metadata["validation_script_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if ablation_source:
        kernel = "scanner" if args.ablate_scanner_source else "aggregator"
        filename = "LogFileScanner.swift" if kernel == "scanner" else "CostAggregator.swift"
        symbol = b"qb_read_lines" if kernel == "scanner" else b"qb_aggregate_usage"
        source = ablation_source.resolve()
        original = source / ".build/release/QuotaBarProbe"
        manifest = json.loads(original.with_name(original.name + ".validation.json").read_text())
        if manifest.get("hook_sha256") != metadata["hook_sha256"] or manifest.get("binary_sha256") != hashlib.sha256(original.read_bytes()).hexdigest():
            raise RuntimeError("Kernel ablation requires a validated probe with the current hook")
        scanner = source / "Sources/QuotaBarCore/Cost" / filename
        current = scanner.read_bytes()
        if symbol not in current:
            raise RuntimeError(f"Ablation source does not contain the Rust {kernel}")
        preserved = original.with_name("QuotaBarProbeRust" + kernel.capitalize() + "-" + output.name)
        if preserved.exists():
            raise RuntimeError("A preserved kernel probe already exists; do not overwrite validation evidence")
        shutil.copy2(original, preserved)
        save(preserved.with_name(preserved.name + ".validation.json"), manifest)
        baseline = subprocess.check_output(["git", "show", f"{revision}:Sources/QuotaBarCore/Cost/{filename}"], cwd=repository)
        scanner.write_bytes(baseline)
        metadata["comparison"] = f"{kernel}-ablation: before=Rust {kernel}, after=Swift {kernel}; all other candidate code unchanged"
        metadata["candidate_source"] = str(source)
        metadata["kernel_sha256"] = {"before": hashlib.sha256(current).hexdigest(), "after": hashlib.sha256(baseline).hexdigest()}
        save(output / "metadata.json", metadata)
        command = [str(source / "Scripts/swift.sh"), "build", "-c", "release", "--product", "QuotaBarProbe"]
        with (output / "ablation-build.log").open("w") as log:
            subprocess.run(command, cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True)
        inputs = manifest.get("source_sha256")
        if inputs is not None:
            inputs = dict(inputs)
            inputs[f"Sources/QuotaBarCore/Cost/{filename}"] = hashlib.sha256(baseline).hexdigest()
        save(original.with_name(original.name + ".validation.json"), {"hook_sha256": metadata["hook_sha256"], "binary_sha256": hashlib.sha256(original.read_bytes()).hexdigest(), "source_sha256": inputs})
        metadata["before_source_sha256"] = manifest.get("source_sha256")
        metadata["after_source_sha256"] = inputs
        binaries = {"before": preserved, "after": original}
    elif args.before_probe:
        binaries = {"before": args.before_probe.resolve(), "after": args.after_probe.resolve()}
        for label, binary in binaries.items():
            manifest = json.loads(binary.with_name(binary.name + ".validation.json").read_text())
            if manifest.get("hook_sha256") != metadata["hook_sha256"] or manifest.get("binary_sha256") != hashlib.sha256(binary.read_bytes()).hexdigest():
                raise RuntimeError(f"Reusable probe has mismatched validation hook or binary hash: {binary}")
            metadata[f"{label}_source_sha256"] = manifest.get("source_sha256")
    else:
        previous = None
        if args.reuse_sources:
            previous = json.loads((args.reuse_sources / "metadata.json").read_text())
            if previous["baseline_revision"] != revision:
                raise RuntimeError("Reusable source baseline revision does not match")
        binaries = {}
        for label, source_revision in [("before", revision), ("after", None)]:
            source = output / "source" / label
            metadata[f"{label}_source_sha256"] = copy_source(repository, source, source_revision)
            if previous is not None:
                if metadata[f"{label}_source_sha256"] != previous[f"{label}_source_sha256"]:
                    raise RuntimeError(f"Reusable {label} source hashes do not match the current source snapshot")
                reused = args.reuse_sources.resolve() / "source" / label
                # Replace only the injected entry point; every other source must still match.
                for name, digest in metadata[f"{label}_source_sha256"].items():
                    if name != "Sources/QuotaBarProbe/main.swift" and hashlib.sha256((reused / name).read_bytes()).hexdigest() != digest:
                        raise RuntimeError(f"Reusable source was modified: {reused / name}")
                shutil.copy2(source / "Sources/QuotaBarProbe/main.swift", reused / "Sources/QuotaBarProbe/main.swift")
                source = reused
                metadata[f"{label}_reused_source"] = str(source)
            save(output / "metadata.json", metadata)
            print(f"Building {label} release probe in isolated source copy", flush=True)
            binaries[label] = build_probe(source, hook, output / f"{label}-build.log", metadata[f"{label}_source_sha256"])
    metadata["binaries"] = {label: {"path": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "bytes": binary.stat().st_size} for label, binary in binaries.items()}
    save(output / "metadata.json", metadata)
    differential(output, binaries, timestamp)
    if not args.skip_benchmarks:
        benchmarks(output, binaries, timestamp, args.iterations, args.workloads)
    metadata["completed"] = True
    save(output / "metadata.json", metadata)
    print(f"Validation completed: {output}", flush=True)


if __name__ == "__main__":
    main()
