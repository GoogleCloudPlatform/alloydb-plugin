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

rm -f "${BASE_DIR}/.teardown_done"

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
  rm -rf ".venv/fake_home/.gemini/tmp/${scenario}" 2>/dev/null || true
done

# Configure Gemini CLI shell inactivity timeout (40 min) and workspace include
# directories so long-running AlloyDB / Agent Engine operations are not killed
# after the default 5-minute silent stdout window.
python3 - << 'EOF'
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

ctx = data.setdefault("context", {})
inc = ctx.setdefault("includeDirectories", [])
for extra in ("/tmp/alloydb-agent-mode-evals", "/workspace"):
    if os.path.exists(extra) and extra not in inc:
        inc.append(extra)

tools = data.setdefault("tools", {})
shell_cfg = tools.setdefault("shell", {})
shell_cfg["inactivityTimeout"] = 2400

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
print(f"[setup] Updated Gemini CLI settings at {settings_path}")
EOF

echo "[setup] Initialized workspaces for: ${scenarios}"
