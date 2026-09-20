#!/usr/bin/env python3
"""Compile real Kickoff sources and retain raw samples plus summary statistics."""

import argparse
import hashlib
import json
import math
import pathlib
import platform
import statistics
import subprocess
import time


def capture(command):
    return subprocess.check_output(command, text=True).strip()


def stats(samples):
    ordered = sorted(samples)
    return {
        "n": len(samples),
        "mean_ns": statistics.mean(samples),
        "median_ns": statistics.median(samples),
        "stddev_ns": statistics.stdev(samples),
        "p95_ns": ordered[math.ceil(0.95 * len(ordered)) - 1],
        "min_ns": ordered[0],
        "max_ns": ordered[-1],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--samples", type=int, default=200)
    parser.add_argument("--cold-samples", type=int, default=100)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--existing-binary", type=pathlib.Path)
    args = parser.parse_args()
    if args.samples < 100 or args.cold_samples < 100:
        parser.error("At least 100 warm and cold samples are required")
    args.output.mkdir(parents=True, exist_ok=True)
    harness = pathlib.Path(__file__).resolve().with_name("main.swift")
    sources = [
        args.repo / "Sources/Kickoff/Player/HuluPlayerTypes.swift",
        args.repo / "Sources/Kickoff/Accessibility/AccessibilityTypes.swift",
        harness,
    ]
    binary = args.existing_binary or args.output / "benchmark"
    command = ["swiftc", "-O", "-whole-module-optimization", "-swift-version", "5", "-module-cache-path", str(args.output / "module-cache"), *map(str, sources), "-o", str(binary)]
    metadata_path = args.output / "build.json"
    if not args.existing_binary:
        metadata = {
            "label": args.label,
            "git_baseline": capture(["git", "-C", str(args.repo), "rev-parse", "HEAD"]),
            "source_sha256": {str(path.relative_to(args.repo)) if path.is_relative_to(args.repo) else path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
            "swift": capture(["swift", "--version"]),
            "host": platform.platform(),
            "machine": platform.machine(),
            "compile_command": command,
        }
        subprocess.run(command, check=True)
        metadata["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    else:
        metadata = json.loads(metadata_path.read_text())
        if hashlib.sha256(binary.read_bytes()).hexdigest() != metadata["binary_sha256"]:
            raise ValueError("Existing binary differs from the recorded build")
    if args.build_only:
        print(binary)
        return
    signature = json.loads(capture([str(binary), "--signature"]))
    (args.output / "signature.json").write_text(json.dumps(signature, indent=2) + "\n")
    warm = json.loads(capture([str(binary), "--warm", str(args.samples)]))
    cold = {name: [] for name in ["non_ad", "exact_ad", "countdown"]}
    cold_results = {name: [] for name in cold}
    launch_wall = {name: [] for name in cold}
    for _ in range(args.cold_samples):
        for name in cold:
            start = time.monotonic_ns()
            result = json.loads(capture([str(binary), "--cold", name]))
            launch_wall[name].append(time.monotonic_ns() - start)
            cold[name].append(result["elapsed_ns"])
            cold_results[name].append(result["matched"])
    result = {
        "metadata": metadata,
        "signature_sha256": signature["sha256"],
        "methodology": {
            "scope": "isolated AdMarker microbenchmarks; synthetic visible text; no whole-app inference",
            "warmup_batches": warm["warmup_batches"],
            "warm_samples": args.samples,
            "cold_samples": args.cold_samples,
            "warm_order": "rotating round robin",
            "cold": "first AdMarker.matches call inside each new process; process launch excluded from primary latency",
            "timer": "DispatchTime.uptimeNanoseconds",
            "p95": "nearest-rank",
            "stddev": "sample standard deviation",
        },
        "warm": [{**workload, "statistics": stats(workload["samples"])} for workload in warm["workloads"]],
        "cold": [{"name": name, "unit": "ns/call", "samples": samples, "matched_outputs": cold_results[name], "statistics": stats(samples), "process_wall_ns": launch_wall[name]} for name, samples in cold.items()],
    }
    destination = args.output / "results.json"
    destination.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"results": str(destination), "signature_sha256": signature["sha256"], "warm": {item["name"]: item["statistics"] for item in result["warm"]}, "cold": {item["name"]: item["statistics"] for item in result["cold"]}}, indent=2))


if __name__ == "__main__":
    main()
