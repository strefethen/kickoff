#!/usr/bin/env python3
"""Compare benchmark artifacts, retaining every output delta and raw-run link."""

import argparse
import json
import math
import pathlib


def comparison(before, after):
    a = before["statistics"]
    b = after["statistics"]
    difference = abs(b["mean_ns"] - a["mean_ns"])
    dispersion = math.sqrt(a["stddev_ns"] ** 2 + b["stddev_ns"] ** 2)
    relative_dispersion = max(a["stddev_ns"] / a["mean_ns"], b["stddev_ns"] / b["mean_ns"])
    count = min(a["n"], b["n"])
    if count >= 100 and relative_dispersion < 0.10 and difference > 3 * dispersion:
        confidence = "high"
    elif count >= 50 and relative_dispersion < 0.20 and difference > 2 * dispersion:
        confidence = "medium"
    elif difference <= max(a["stddev_ns"], b["stddev_ns"]):
        confidence = "noise"
    else:
        confidence = "variable: does not satisfy the high/medium dispersion gates"
    return {
        "name": before["name"],
        "before": a,
        "after": b,
        "mean_latency_reduction_percent": 100 * (1 - b["mean_ns"] / a["mean_ns"]),
        "median_latency_reduction_percent": 100 * (1 - b["median_ns"] / a["median_ns"]),
        "confidence": confidence,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=pathlib.Path)
    parser.add_argument("after", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    before = json.loads((args.before / "results.json").read_text())
    after = json.loads((args.after / "results.json").read_text())
    before_signature = json.loads((args.before / "signature.json").read_text())
    after_signature = json.loads((args.after / "signature.json").read_text())
    before_corpus = before_signature["outputs"]["corpus"]
    after_corpus = after_signature["outputs"]["corpus"]
    if len(before_corpus) != len(after_corpus):
        raise ValueError("Corpus sizes differ")
    changed = []
    for a, b in zip(before_corpus, after_corpus):
        if a["utf8_base64"] != b["utf8_base64"]:
            raise ValueError("Corpus inputs differ")
        if a["matches"] != b["matches"]:
            changed.append({"utf8_base64": a["utf8_base64"], "before": a["matches"], "after": b["matches"]})
    result = {
        "before": str(args.before / "results.json"),
        "after": str(args.after / "results.json"),
        "signature_equal": before["signature_sha256"] == after["signature_sha256"],
        "before_signature": before["signature_sha256"],
        "after_signature": after["signature_sha256"],
        "changed_corpus_outputs": changed,
        "output_note": "Differences must be reconciled with the authorized contract; timing improvement does not establish behavioral equivalence.",
        "confidence_method": "Conservative skill dispersion gates using quadrature of before/after sample standard deviations, without removing outliers.",
    }
    for mode in ["warm", "cold"]:
        if [row["name"] for row in before[mode]] != [row["name"] for row in after[mode]]:
            raise ValueError("Workload names differ")
        result[mode] = [comparison(a, b) for a, b in zip(before[mode], after[mode])]
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "changed_corpus_outputs"}, indent=2))
    print("Changed corpus outputs:", len(changed))


if __name__ == "__main__":
    main()
