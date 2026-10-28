#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Prints per-scenario CUJ evaluation scores and gates CI on pass criteria."""

import csv
import glob
import os
import sys


def main() -> None:
  results_dir = os.environ.get(
      "EVAL_RESULTS_DIR", "/tmp/alloydb-agent-mode-evals/results"
  )
  score_files = sorted(glob.glob(os.path.join(results_dir, "*", "scores.csv")))
  if not score_files:
    print(f"ERROR: No scores.csv generated under {results_dir}", file=sys.stderr)
    sys.exit(1)

  with open(score_files[-1], newline="") as f:
    rows = list(csv.DictReader(f))

  by_scenario: dict[str, list[dict[str, str]]] = {}
  for r in rows:
    by_scenario.setdefault(r.get("id", "unknown"), []).append(r)

  if not by_scenario:
    print("ERROR: scores.csv contained no scenario rows.", file=sys.stderr)
    sys.exit(1)

  failed = False
  print("\n=== AlloyDB Agent Mode CUJ Evaluation Summary ===")
  for sid, srows in sorted(by_scenario.items()):
    metrics: dict[str, float] = {}
    rubric_pass = 0
    rubric_total = 0
    failed_rubrics: list[tuple[str, str]] = []
    for r in srows:
      comp = r.get("comparator", "")
      try:
        val = float(r.get("score", 0) or 0)
      except ValueError:
        val = 0.0
      if comp.startswith("binary_rubric_scorer"):
        rubric_total += 1
        if val >= 100.0 or val == 1.0:
          rubric_pass += 1
        else:
          failed_rubrics.append((comp, (r.get("comparison_logs") or "")[:240]))
      else:
        metrics[comp] = val

    st = metrics.get("skills_trajectory", 0.0)
    gc = metrics.get("goal_completion", 0.0)
    sbp = metrics.get("skills_best_practices", 0.0)
    turns = metrics.get("turn_count", 0.0)
    lat = metrics.get("end_to_end_latency", 0.0)
    print(
        f"  [{sid}] skills_trajectory={st:.1f}% | goal_completion={gc:.1f}% | "
        f"binary_rubric={rubric_pass}/{rubric_total} | "
        f"skills_best_practices={sbp:.1f} | turns={turns:.0f} | "
        f"latency={lat:.1f}s"
    )
    for rname, rlog in failed_rubrics:
      print(f"    - Missed {rname}: {rlog}")
    if st < 100.0 or gc < 100.0:
      failed = True

  if failed:
    print(
        "ERROR: One or more CUJs failed skills_trajectory or goal_completion.",
        file=sys.stderr,
    )
    sys.exit(1)
  print("All executed CUJs passed!")


if __name__ == "__main__":
  main()
