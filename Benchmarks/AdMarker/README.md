# AdMarker microbenchmark

This harness compiles the actual `HuluPlayerTypes.swift` and
`AccessibilityTypes.swift` sources with Swift release optimization. It does not
copy or replace the production matcher. Inputs are synthetic, and results cannot
be interpreted as whole-app or live Hulu performance.

Run from the repository root on macOS with the installed Swift and Python tools:

```sh
python3 Benchmarks/AdMarker/run.py --output /private/tmp/kickoff-ad-marker-baseline --label baseline
```

After changing the implementation, use a different output directory and label.
The default repository path assumes this directory is `Benchmarks/AdMarker`;
otherwise pass `--repo /absolute/path/to/kickoff`.

Compare two result directories with:

```sh
python3 Benchmarks/AdMarker/compare.py /private/tmp/kickoff-ad-marker-baseline /private/tmp/kickoff-ad-marker-candidate --output /private/tmp/kickoff-ad-marker-comparison.json
```

The comparison retains every changed corpus output; reconcile those differences
with the authorized behavioral contract. It reports conservative confidence
using the optimization skill's sample-count and dispersion gates without
discarding outliers. A result marked as noise is not an improvement claim.

The runner retains the compiled binary, compiler command and version, source and
binary SHA-256 digests, deterministic output signature, individual measurements,
and summary statistics. Benchmark artifacts belong outside the source tree.
`--build-only` records the baseline binary before source edits; run that recorded
binary later with `--existing-binary /path/to/output/benchmark` and the same
`--output` directory.

Warm measurements use ten warmup batches and 200 measurement batches for each
workload, rotating the workload order each round. Each batch contains a fixed
number of calls large enough to exceed timer resolution. Results report ns per
`matches` call for string workloads or ns per `isPresent` call for node scans.
The JSON records both batch repetitions and calls per repetition. The checksum
makes matcher results observable. Do not interpret node-scan latency as the cost
of one text node.

Cold measurements start 100 fresh processes for each of three inputs, timing the
first `AdMarker.matches` call inside the process. They include lazy regex
initialization when needed and exclude process launch from the primary latency.
Launch wall time is retained separately. No marker call precedes a cold timer.

The corpus signature covers fixed boundary cases, Unicode scalars, line endings,
long text, generated mixed-script text, and node-filter outputs. It complements
characterization tests; digest equality is empirical evidence, not a formal
proof of equivalence over every Swift String.

For a native CPU sample, the executable supports a timed hot loop:

```sh
/private/tmp/kickoff-ad-marker-baseline/benchmark --profile synthetic_visible_text 15
```

Sample that process with the macOS `sample` tool. Do not collect a profile or run
the app's tests concurrently with latency measurements.
