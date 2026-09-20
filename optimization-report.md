# Kickoff optimization pass — 2026-09-20

Baseline: `8195f621d6c6a8fca8c74dc129b4baa905e6b5af`.

This pass began as isomorphic-only. The user then explicitly replaced the matcher contract: “we don't need to be looking at the time portion. we can simply look for "ad" from the beginning of the text in a case insensitive way”. The resulting recognition change is intentional and **not isomorphic to the original matcher**. No other production behavior was targeted.

## Changes

### change-1 — Case-insensitive ad prefix

- Replace the compiled regular expression and full-range check in `Sources/Kickoff/Player/HuluPlayerTypes.swift` with an anchored, case-insensitive Foundation string search.
- Update `Tests/KickoffTests/AdMarkerTests.swift` for case variants, arbitrary ordinary trailing text, anchoring, and static-text scope.
- Add reproducible tooling in `Benchmarks/AdMarker/` and this report with `optimization-evidence.json`. The product README is unchanged.
- Why faster: no regular-expression matching, match-result object or lazy regex compilation. The new contract no longer requires validating a timer or end of string.
- Tradeoff: the approved recognition expansion includes “Ads”, “Advertisement”, “Ad choices” and malformed countdowns. Leading whitespace still prevents a match. Foundation keeps diacritics significant.
- Complexity: no asymptotic improvement claimed; conservative O(n) worst-case string handling/bridging remains, with no distinct amortized bound. No cache or dependency was added.

## Measured Results (Criterion Benchmarks)

Native `sample` profiling of the baseline synthetic matcher loop placed 2,911 of 4,203 main-thread samples in its dominant regular-expression stack (about 69%). The live app sample was idle and read-only player inspection found zero players, so active-playback performance was unavailable. The following are isolated synthetic workloads, **not whole-app speedups**.

Swift 6.2.4, arm64 macOS; `-O -whole-module-optimization -swift-version 5`. Each warm workload used ten warmup batches and 200 measurement batches, rotating workload order. Each cold workload used 100 fresh processes. One quiet confirmation followed an initial noisier run; both runs and all outliers were retained.

Warm statistics describe batch-average ns/call, **not individual-call tail latency**. A node-scan call is a whole helper scan, not one text node. Cold timings measure the first matcher call inside a fresh process and exclude launch time. Negative delta means less time.

| Workload | Before mean ± σ | After mean ± σ | Median before / after (ns) | p95 before / after (ns) | Mean Δ | Confidence |
|---|---|---|---|---|---|---|
| warm: Synthetic visible text | 289.90 ns +/- 19.80 ns | 178.88 ns +/- 4.00 ns | 286.76 / 179.10 | 299.51 / 182.81 | -38.29% | High |
| warm: Exact Ad | 293.03 ns +/- 17.16 ns | 161.46 ns +/- 9.32 ns | 290.72 / 160.70 | 300.73 / 166.28 | -44.90% | High |
| warm: Countdown text | 380.96 ns +/- 32.40 ns | 161.30 ns +/- 15.08 ns | 375.91 / 160.67 | 394.50 / 164.76 | -57.66% | High |
| warm: Ad-prefixed text | 351.89 ns +/- 13.95 ns | 209.85 ns +/- 6.16 ns | 348.70 / 209.77 | 367.84 / 214.81 | -40.37% | High |
| warm: Synthetic static-node scan | 9257.39 ns +/- 1219.40 ns | 5918.48 ns +/- 337.48 ns | 9146.25 / 5904.67 | 9520.06 / 6028.85 | -36.07% | Medium |
| warm: Non-target: nonstatic-node filter | 94.33 ns +/- 2.20 ns | 93.71 ns +/- 2.29 ns | 94.63 / 93.90 | 97.45 / 97.00 | -0.66% | Noise |
| cold: First call: non-ad | 867142.10 ns +/- 30376.87 ns | 29245.89 ns +/- 4069.50 ns | 862708.50 / 28666.00 | 921042.00 / 35959.00 | -96.63% | Medium |
| cold: Exact Ad | 871398.72 ns +/- 29288.72 ns | 29884.56 ns +/- 4062.24 ns | 869916.50 / 29125.00 | 908125.00 / 36000.00 | -96.57% | Medium |
| cold: First call: countdown | 875167.49 ns +/- 25374.28 ns | 29480.38 ns +/- 4439.75 ns | 873541.50 / 29208.00 | 909583.00 / 37209.00 | -96.63% | Medium |

Confidence follows the skill's sample-size/dispersion gates; the nonstatic-node filter is noise and is not claimed as an improvement. No non-target regression was detected. No memory, binary-size or end-to-end improvement is claimed.

## Isomorphic Proof

**change-1 has no equivalence proof to the old matcher because the user intentionally changed its accepted language.** This is not presented as a proven optimization.

The limited unchanged-behavior evidence is:

- Twenty other production files are byte-identical to baseline.
- In the changed file, only `AdMarker.matches` and its private regex declaration differ; the static-text helper is untouched.
- Existing visible-player scoping, AX read ordering, tab identity, prepress verification, cancellation, ownership and timing constants remain unchanged.
- The predicate still returns a deterministic Boolean without adding errors, AX actions, I/O, shared mutable state or floating-point computation.

The baseline suite passed 76 tests. Temporary original-grammar characterization passed 77 tests before production changes. After the user's revised contract, the final suite passed 77 tests with updated recognition expectations; release compilation also passed. Tests for the old negative labels were intentionally updated, not claimed as unchanged parity.

The 2,167-input benchmark corpus has 929 intentional false-to-true changes and zero true-to-false changes. An independent bounded oracle checked every row. Sixty-five generated inputs with an acute accent attached to the letter d remain negative; case-insensitivity is not diacritic-insensitivity. These samples do not constitute an all-Unicode equivalence proof.

Independent source/test and benchmark-method review: **PASS**, against source SHA-256 `a0ca712fdfdc5214cece36193c6d67b1235943efcb836184d6db3ef99c8a2f9d` and test SHA-256 `a08d1fa245c619424cd673b137c52e1d683e49b6a5fba2c5541372d00c572bf0`.

## Evidence Ledger

Machine-readable results, approval, contracts, signatures and verification commands: [optimization-evidence.json](optimization-evidence.json).

Raw local measurements, profiles, signatures, compilation provenance and test/build logs are retained under `captures/optimization-2026-09-20/` (ignored by Git). This includes the initial and confirmation runs, every sample and every changed corpus output. Portable benchmark source and replay instructions are in [Benchmarks/AdMarker/README.md](Benchmarks/AdMarker/README.md).

Validation:

```sh
python3 <extreme-optimization-skill>/scripts/validate_evidence.py optimization-evidence.json --report optimization-report.md
```

## ⚠ Unproven Changes

**change-1 — explicitly approved behavior change.** Exact baseline equivalence is known not to hold. The user requested a case-insensitive beginning-of-text check without timer parsing after the conflict with isomorphism was explained. That approval is recorded in the ledger as `prefix-requirement`. No other unproven change was included.

## ⚠ Approximate Changes

None. No sampling, probabilistic recognition or lossy matching was introduced.

## ⏭ Rejected Optimizations

- Caching, combining or skipping AX reads: freshness, error behavior and ordering are part of the current contract.
- An exact-grammar UTF8 parser or regex prefilter: superseded by the approved prefix requirement before implementation.
- Audio-token parsing and child-array/counting changes: left untouched because this pass established no meaningful end-to-end gain for them.
