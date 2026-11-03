#!/usr/bin/env bash
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

set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/tmp/alloydb-agent-mode-evals"

# Stops the run before any scenario starts. EvalBench ignores this script's exit
# code, so kill it. Reads the parent's command line from /proc first, falling
# back to `ps` (not every container image has `ps`).
fail() {
  echo "[setup] ERROR: $*" >&2
  if [[ "$(tr '\0' ' ' < "/proc/${PPID}/cmdline" 2>/dev/null || ps -o args= -p "${PPID}")" == *evalbench.py* ]]; then
    kill -KILL "${PPID}"
  fi
  exit 1
}
trap 'fail "setup.sh failed at line ${LINENO}"' ERR

# teardown.sh refuses an empty EVAL_SCENARIOS, so refuse it before anything is
# created. Also require a lowercase alphanumeric EVAL_RUN_ID so both hyphenated
# GCP resource names and underscored Agent Engine names match evalset.json.
if [[ -v EVAL_SCENARIOS && -z "${EVAL_SCENARIOS}" ]]; then
  fail "EVAL_SCENARIOS is set but empty; unset it to run all scenarios."
fi
if [[ ! "${EVAL_RUN_ID:-}" =~ ^[a-z0-9]{1,15}$ ]]; then
  fail "EVAL_RUN_ID must be 1-15 lowercase letters or digits (e.g. 'local' or 'pr174'); got '${EVAL_RUN_ID:-}'."
fi

if [[ -n "${EVAL_SCENARIOS:-}" ]]; then
  scenarios="${EVAL_SCENARIOS//,/ }"
else
  scenarios="$(python3 -c 'import json, sys; print(" ".join(s["id"] for s in json.load(open(sys.argv[1]))["scenarios"]))' "${SUITE_DIR}/evalset.json")"
fi

for scenario in ${scenarios}; do
  ws="${BASE_DIR}/workspaces/${scenario}"
  rm -rf "${ws}"
  mkdir -p "${ws}"
  # Remove any stale Gemini CLI session directory for this workspace
  rm -rf ".venv/fake_home/.gemini/tmp/${scenario}"
done

# Raise the Gemini CLI shell inactivity timeout above the 5-minute default:
# 40 minutes when CUJ 1 is selected (AlloyDB primary creation can run >15 min
# without output), and 10 minutes for CUJ 2/3 so stray commands fail fast
# instead of exhausting the scenario budget. Do not add the repository checkout
# to the CLI's workspace directories: agents under evaluation must not read the
# evalset.
INACTIVITY_TIMEOUT=600
if [[ " ${scenarios} " == *" cuj1-provision-agent-pool "* ]]; then
  INACTIVITY_TIMEOUT=2400
fi
INACTIVITY_TIMEOUT="${INACTIVITY_TIMEOUT}" python3 - << 'EOF'
import json
import os

settings_path = os.path.abspath(os.path.join(".venv", "fake_home", ".gemini", "settings.json"))
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
data = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path) as f:
            data = json.load(f)
    except Exception:
        data = {}

tools = data.setdefault("tools", {})
shell_cfg = tools.setdefault("shell", {})
shell_cfg["inactivityTimeout"] = int(os.environ["INACTIVITY_TIMEOUT"])

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
print(f"[setup] Updated Gemini CLI settings at {settings_path} (inactivityTimeout={shell_cfg['inactivityTimeout']}s)")
EOF

echo "[setup] Initialized workspaces for: ${scenarios}"
