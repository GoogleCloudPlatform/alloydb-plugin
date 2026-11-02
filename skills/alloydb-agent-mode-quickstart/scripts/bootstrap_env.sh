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

# =============================================================================
# Checks the local environment, then creates (or updates) the workspace
# virtualenv with everything the provisioning scripts need.
#
# The checks come first because every one of them fails LATER and less
# obviously otherwise: a missing ADC token surfaces as a 401 from Discovery
# Engine later on, an old Python as an import error mid-deploy.
#
# Run from the working directory; the venv lands at ./.venv.
# =============================================================================
set -euo pipefail
export PYTHONSAFEPATH=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${PWD}/.venv"
FAIL=0

fail() { echo "  MISSING  $1" >&2; FAIL=1; }
ok()   { echo "  ok       $1"; }
warn() { echo "  WARN     $1"; }

echo "==> Checking the environment"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 (need 3.11+)"
elif ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
  fail "python3 is $(python3 -V 2>&1 | cut -d' ' -f2); need 3.11+"
else
  ok "python3 $(python3 -V 2>&1 | cut -d' ' -f2)"
fi

if ! command -v gcloud >/dev/null 2>&1; then
  fail "gcloud CLI"
else
  ok "$(gcloud --version 2>/dev/null | head -1)"
  # Two DIFFERENT credentials, both required. The user account authorizes the
  # gcloud calls; ADC authorizes the Python SDKs and the REST calls in
  # deploy_agent.py register (the plain gcloud token is rejected).
  if [ -z "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ]; then
    fail "an active gcloud account — run: gcloud auth login"
  else
    ok "gcloud account $(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
  fi
  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    fail "application-default credentials — run: gcloud auth application-default login"
  else
    ok "application-default credentials"
  fi
fi


[ "$FAIL" -eq 0 ] || { echo "==> Fix the items above, then re-run." >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
  REQ_HASH="$(sha256sum "${SCRIPT_DIR}/requirements.txt" | awk '{print $1}')"
else
  REQ_HASH="$(shasum -a 256 "${SCRIPT_DIR}/requirements.txt" | awk '{print $1}')"
fi
STAMP_FILE="${VENV_DIR}/.requirements.sha256"

if [ -x "${VENV_DIR}/bin/python" ] && [ -f "${STAMP_FILE}" ] && [ "$(cat "${STAMP_FILE}")" = "${REQ_HASH}" ]; then
  echo "==> Environment already up-to-date: ${VENV_DIR}"
  exit 0
fi

echo "==> Creating the virtualenv (${VENV_DIR})"
if command -v uv >/dev/null 2>&1; then
  uv venv --allow-existing "${VENV_DIR}"
  PYTHONPATH="" uv pip install --python "${VENV_DIR}/bin/python" -r "${SCRIPT_DIR}/requirements.txt"
else
  python3 -m venv "${VENV_DIR}"
  # Isolate pip from any inherited PYTHONPATH (e.g. EvalBench runner environment)
  PYTHONPATH="" "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
  echo "==> Installing dependencies (google-adk, vertexai, mcp, matplotlib...)"
  PYTHONPATH="" "${VENV_DIR}/bin/pip" install --quiet --no-warn-conflicts -r "${SCRIPT_DIR}/requirements.txt"
fi
echo "${REQ_HASH}" > "${STAMP_FILE}"
echo "==> Environment ready: ${VENV_DIR}"
