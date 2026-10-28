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

set -uo pipefail

BASE_DIR="/tmp/alloydb-agent-mode-evals"

if [[ "${EVAL_SKIP_TEARDOWN:-0}" == "1" ]]; then
  echo "[teardown] EVAL_SKIP_TEARDOWN=1 set; keeping deployments and workspaces."
  exit 0
fi

if [[ "${FORCE_TEARDOWN:-0}" != "1" && -f "${BASE_DIR}/.teardown_done" ]]; then
  echo "[teardown] Cleanup already completed for this run; skipping duplicate invocation."
  exit 0
fi

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${EVAL_SKILLS_DIR:-$(cd "${SUITE_DIR}/../../skills" && pwd)}/alloydb-agent-mode-quickstart"
PROJECT="${EVAL_GCP_PROJECT_ID:?EVAL_GCP_PROJECT_ID must be set}"
REGION="${EVAL_GCP_PROJECT_REGION:?EVAL_GCP_PROJECT_REGION must be set}"

if [[ -n "${EVAL_SCENARIOS:-}" ]]; then
  scenarios="${EVAL_SCENARIOS//,/ }"
else
  scenarios="$(python3 -c 'import json, sys; print(" ".join(s["id"] for s in json.load(open(sys.argv[1]))["scenarios"]))' "${SUITE_DIR}/evalset.json")"
fi
selected() { [[ " ${scenarios} " == *" $1 "* ]]; }

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

teardown_agent() {
  local scenario="$1" name="$2"
  local ws="${BASE_DIR}/workspaces/${scenario}"
  mkdir -p "${ws}"
  if [[ ! -x "${ws}/.venv/bin/python" ]]; then
    (cd "${ws}" && bash "${SKILL_DIR}/scripts/bootstrap_env.sh") || true
  fi
  if [[ -x "${ws}/.venv/bin/python" ]]; then
    cat > "${ws}/.teardown.alloydb-agent.yaml" <<EOF
name: "${name}"
project_id: "${PROJECT}"
region: "${REGION}"
name_suffix: "${EVAL_FOUNDATION_SUFFIX:-}"
database:
  cluster: "${EVAL_SHARED_CLUSTER:-}"
EOF
    "${ws}/.venv/bin/python" "${SKILL_DIR}/scripts/deploy_agent.py" teardown \
      --config "${ws}/.teardown.alloydb-agent.yaml" --yes || true
  fi
}

selected cuj2-simple-agent && [[ -n "${CUJ2_NAME:-}" ]] && teardown_agent cuj2-simple-agent "${CUJ2_NAME}"
selected cuj3-agent-swarm && [[ -n "${CUJ3_NAME:-}" ]] && teardown_agent cuj3-agent-swarm "${CUJ3_NAME}"

if selected cuj1-provision-agent-pool && [[ -n "${CUJ1_CLUSTER:-}" ]]; then
  gcloud beta alloydb instances delete "${CUJ1_POOL}" --cluster="${CUJ1_CLUSTER}" \
    --project="${PROJECT}" --region="${REGION}" --quiet 2>/dev/null || true
  gcloud beta alloydb clusters delete "${CUJ1_CLUSTER}" \
    --project="${PROJECT}" --region="${REGION}" --force --quiet 2>/dev/null || true

  if [[ -n "${CUJ1_VPC:-}" ]]; then
    no_psc_endpoint() {
      [[ -z "$(gcloud compute forwarding-rules list --project="${PROJECT}" \
        --filter="network~/${CUJ1_VPC}$" --format='value(name)' 2>/dev/null)" ]]
    }
    wait_until "PSC endpoint removed from ${CUJ1_VPC}" no_psc_endpoint || true
    gcloud network-connectivity service-connection-policies delete "alloydb-agents-${CUJ1_VPC}" \
      --project="${PROJECT}" --region="${REGION}" --quiet 2>/dev/null || true
    gcloud compute networks subnets delete "${CUJ1_SUBNET}" \
      --project="${PROJECT}" --region="${REGION}" --quiet 2>/dev/null || true
    mapfile -t fw_rules < <(gcloud compute firewall-rules list --project="${PROJECT}" \
      --filter="network~/${CUJ1_VPC}$" --format='value(name)' 2>/dev/null)
    if ((${#fw_rules[@]})); then
      gcloud compute firewall-rules delete "${fw_rules[@]}" --project="${PROJECT}" --quiet 2>/dev/null || true
    fi
    gcloud compute networks delete "${CUJ1_VPC}" --project="${PROJECT}" --quiet 2>/dev/null || true
  fi
fi

for scenario in ${scenarios}; do
  rm -rf "${BASE_DIR}/workspaces/${scenario}"
done
mkdir -p "${BASE_DIR}"
touch "${BASE_DIR}/.teardown_done"
echo "[teardown] Done."
exit 0
