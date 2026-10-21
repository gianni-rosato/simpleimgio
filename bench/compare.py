#!/usr/bin/env python3
"""Compare prebuilt benchmark binaries with alternating, paired measurements."""

import argparse
import json
import math
import random
import statistics
import subprocess
from pathlib import Path


def measure(binary):
    result = subprocess.run([binary], capture_output=True, text=True, check=True)
    cases = {}
    for line in result.stderr.splitlines():
        name, elapsed, checksum = line.split()
        if name in cases or not math.isfinite(float(elapsed)) or float(elapsed) <= 0:
            raise ValueError(f"Invalid measurement: {line}")
        cases[name] = (float(elapsed), int(checksum))
    if not cases:
        raise ValueError(f"No measurements from {binary}")
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--samples", type=int, default=16)
    parser.add_argument("--threshold", type=float, default=5.0, help="Maximum slowdown, percent")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 8 or args.threshold <= 0:
        parser.error("Use at least 8 samples and a positive threshold")

    # Warm both executables and the filesystem cache before collecting samples.
    expected = measure(args.baseline)
    candidate = measure(args.candidate)
    if {k: v[1] for k, v in expected.items()} != {k: v[1] for k, v in candidate.items()}:
        raise ValueError("Baseline and candidate output checksums differ")

    samples = []
    for index in range(args.samples):
        pair = {}
        order = ("baseline", "candidate") if index % 2 == 0 else ("candidate", "baseline")
        for label in order:
            pair[label] = measure(getattr(args, label))
            if {k: v[1] for k, v in pair[label].items()} != {k: v[1] for k, v in expected.items()}:
                raise ValueError(f"Inconsistent output from {label}")
        samples.append(pair)
        print(f"Completed pair {index + 1}/{args.samples}", flush=True)

    rng = random.Random(42)
    results = {}
    limit = 1 + args.threshold / 100
    status = 0
    print("case                    baseline ms  candidate ms   change       95% CI")
    for name in expected:
        baseline = [p["baseline"][name][0] for p in samples]
        candidate = [p["candidate"][name][0] for p in samples]
        log_ratios = [math.log(b / a) for a, b in zip(baseline, candidate)]
        # Paired bootstrap of the geometric mean ratio; no normality assumption.
        boot = sorted(
            math.exp(statistics.mean(rng.choices(log_ratios, k=args.samples)))
            for _ in range(10_000)
        )
        low, high = boot[250], boot[9749]
        ratio = math.exp(statistics.mean(log_ratios))
        verdict = "pass" if high <= limit else "regression" if low > limit else "inconclusive"
        if verdict != "pass":
            status = max(status, 1 if verdict == "regression" else 2)
        results[name] = {
            "baseline_median_ns": statistics.median(baseline),
            "candidate_median_ns": statistics.median(candidate),
            "paired_ratio": ratio,
            "ratio_ci95": [low, high],
            "verdict": verdict,
        }
        print(f"{name:22} {statistics.median(baseline) / 1e6:11.4f}"
              f" {statistics.median(candidate) / 1e6:13.4f} {100 * (ratio - 1):+7.2f}%"
              f" [{100 * (low - 1):+6.2f}%, {100 * (high - 1):+6.2f}%] {verdict}")
    args.output.write_text(json.dumps({
        "baseline": args.baseline,
        "candidate": args.candidate,
        "samples": args.samples,
        "threshold_percent": args.threshold,
        "results": results,
        "raw_samples": samples,
    }, indent=2) + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
