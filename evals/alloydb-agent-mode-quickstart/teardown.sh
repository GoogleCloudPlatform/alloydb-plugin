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

# ==============================================================================
# EvalBench `tear_down_script` hook for alloydb-agent-mode-quickstart
# ==============================================================================
# Deletes what the selected scenarios (EVAL_SCENARIOS, default: all) deployed in
# EVAL_GCP_PROJECT_ID / EVAL_GCP_PROJECT_REGION, then removes their workspaces.
# It never touches other scenarios. Each resource is deleted once, after
# checking that whatever blocks it is gone. EvalBench runs it in a `finally:`
# block after evaluation. Set EVAL_SKIP_TEARDOWN=1 in the shell that launches
# EvalBench to keep everything for debugging.
# ==============================================================================

set -uo pipefail
export PATH="${HOME}/.local/bin:${PATH}"

if [[ "${EVAL_SKIP_TEARDOWN:-0}" == "1" ]]; then
  echo "[teardown] EVAL_SKIP_TEARDOWN=1 set; keeping deployments and workspaces."
  exit 0
fi
if [[ -v EVAL_SCENARIOS && -z "${EVAL_SCENARIOS}" ]]; then
  echo "[teardown] EVAL_SCENARIOS is set but empty; unset it to tear down all scenarios." >&2
  exit 1
fi

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${EVAL_GCP_PROJECT_ID:?EVAL_GCP_PROJECT_ID must be set}"
REGION="${EVAL_GCP_PROJECT_REGION:?EVAL_GCP_PROJECT_REGION must be set}"
WORKSPACES="/tmp/alloydb-agent-mode-evals/workspaces"

if [[ -n "${EVAL_SCENARIOS:-}" ]]; then
  scenarios="${EVAL_SCENARIOS//,/ }"
else
  scenarios="$(python3 -c 'import json, sys; print(" ".join(s["id"] for s in json.load(open(sys.argv[1]))["scenarios"]))' "${SUITE_DIR}/evalset.json")"
fi
selected() { [[ " ${scenarios} " == *" $1 "* ]]; }

SKILL_DIR="${EVAL_SKILLS_DIR:-${SUITE_DIR}/../../skills}/alloydb-agent-mode-quickstart"

# wait_until <description> <command...>: checks every 15s (up to 30 min) until
# the command succeeds.
wait_until() {
  local desc="$1"
  shift
  for _ in $(seq 120); do
    "$@" && return 0
    sleep 15
  done
  echo "[teardown] Timed out waiting for: ${desc}" >&2
  return 1
}

# 1. CUJ 2 and CUJ 3 deployments, via the skill's own teardown command
#    (deletes Agent Engines, per-deployment stack, and AlloyDB IAM user).
teardown_agent() {
  local scenario="$1" name="$2"
  local ws="${WORKSPACES}/${scenario}"
  mkdir -p "${ws}"
  if [[ ! -x "${ws}/.venv/bin/python" ]]; then
    (cd "${ws}" && bash "${SKILL_DIR}/scripts/bootstrap_env.sh")
  fi
  cat > "${ws}/.teardown.alloydb-agent.yaml" <<EOF
name: "${name}"
project_id: "${PROJECT}"
region: "${REGION}"
name_suffix: "${EVAL_FOUNDATION_SUFFIX:-}"
database:
  cluster: "${EVAL_SHARED_CLUSTER:?EVAL_SHARED_CLUSTER must be set}"
EOF
  "${ws}/.venv/bin/python" "${SKILL_DIR}/scripts/deploy_agent.py" teardown \
    --config "${ws}/.teardown.alloydb-agent.yaml" --yes
}
selected cuj2-simple-agent && teardown_agent cuj2-simple-agent "${CUJ2_NAME:?CUJ2_NAME must be set}"
selected cuj3-agent-swarm && teardown_agent cuj3-agent-swarm "${CUJ3_NAME:?CUJ3_NAME must be set}"

if selected cuj1-provision-agent-pool; then
  : "${CUJ1_CLUSTER:?CUJ1_CLUSTER must be set}" "${CUJ1_POOL:?CUJ1_POOL must be set}"
  : "${CUJ1_VPC:?CUJ1_VPC must be set}" "${CUJ1_SUBNET:?CUJ1_SUBNET must be set}"

  # 2. CUJ 1 AlloyDB resources. CUJ 1's agent deletes everything it created as
  #    the last part of the scenario; steps 2-3 remove whatever a failed run left
  #    behind. Delete the pool first, as the skill's teardown guide does, then
  #    the cluster (`--force` also deletes the primary instance).
  gcloud beta alloydb instances delete "${CUJ1_POOL}" --cluster="${CUJ1_CLUSTER}" \
    --project="${PROJECT}" --region="${REGION}" --quiet
  gcloud beta alloydb clusters delete "${CUJ1_CLUSTER}" \
    --project="${PROJECT}" --region="${REGION}" --force --quiet

  # 3. CUJ 1 network. Once the pool's PSC endpoint is gone, delete the SCP and
  #    the subnet. Delete all firewall rules in one call and the VPC right after.
  no_psc_endpoint() {
    [[ -z "$(gcloud compute forwarding-rules list --project="${PROJECT}" \
      --filter="network~/${CUJ1_VPC}$" --format='value(name)' 2>/dev/null)" ]]
  }
  wait_until "PSC endpoint removed from ${CUJ1_VPC}" no_psc_endpoint
  gcloud network-connectivity service-connection-policies delete "alloydb-agents-${CUJ1_VPC}" \
    --project="${PROJECT}" --region="${REGION}" --quiet
  gcloud compute networks subnets delete "${CUJ1_SUBNET}" \
    --project="${PROJECT}" --region="${REGION}" --quiet
  mapfile -t fw_rules < <(gcloud compute firewall-rules list --project="${PROJECT}" \
    --filter="network~/${CUJ1_VPC}$" --format='value(name)' 2>/dev/null)
  if ((${#fw_rules[@]})); then
    gcloud compute firewall-rules delete "${fw_rules[@]}" --project="${PROJECT}" --quiet
  fi
  gcloud compute networks delete "${CUJ1_VPC}" --project="${PROJECT}" --quiet
fi

# 4. The selected scenarios' workspaces; the shared parents go once no other
#    run uses them.
for scenario in ${scenarios}; do
  rm -rf "${WORKSPACES:?}/${scenario}"
done
rmdir "${WORKSPACES}" /tmp/alloydb-agent-mode-evals 2>/dev/null
echo "[teardown] Done."
