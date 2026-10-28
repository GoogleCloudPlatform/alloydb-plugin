# AlloyDB Agent Mode Quickstart Evaluations

End-to-end live Critical User Journey (CUJ) evaluations for the
[`alloydb-agent-mode-quickstart`](../../skills/alloydb-agent-mode-quickstart/SKILL.md)
skill, powered by [EvalBench](https://github.com/GoogleCloudPlatform/evalbench).

## Scenarios (`evalset.json`)

| Scenario ID | Capability Tested | Description |
| :--- | :--- | :--- |
| `cuj1-provision-agent-pool` | Capability 1 (Step P) | Provisions a dedicated VPC, subnet, service connection policy, AlloyDB cluster with `--enable-agent-mode`, primary instance, and `AGENT_POOL` instance over PSC, verifies `READY` + `.alloydb.goog.` DNS name, then performs confirmed reverse-order teardown. |
| `cuj2-simple-agent` | Capability 2 (Steps 0–4 + Teardown) | Generates and validates `<name>.alloydb-agent.yaml`, provisions per-deployment infrastructure and IAM database user against a shared AlloyDB agent pool, deploys and validates a read-only ADK agent on Vertex AI Agent Engine, then performs confirmed per-deployment teardown while preserving shared resources. |
| `cuj3-agent-swarm` | Capability 3 (Steps 0–4 + Teardown) | Deploys a Cloud Run Agent Workspace (`isolation-self-check: PASS`), a worker agent with per-session PostgreSQL scratch databases, and a swarm coordinator on Vertex AI Agent Engine, validates end-to-end execution, then tears down both engines, the stack, and the IAM database user while preserving shared resources. |

## Triggering from a Pull Request

When a pull request modifies `skills/alloydb-agent-mode-quickstart/**` or
`evals/agent-mode/**`, Cloud Build runs [`cloudbuild.yaml`](cloudbuild.yaml)
when the `ci:run-agent-mode-evals` label is applied to the PR.

All per-run cloud resources are namespaced by pull request number (`pr<NUMBER>`)
and automatically cleaned up by [`teardown.sh`](teardown.sh).

## Running Locally

From a local [EvalBench](https://github.com/GoogleCloudPlatform/evalbench)
checkout with `gcloud` and Application Default Credentials authenticated:

```bash
export EVAL_SUITE_DIR="/path/to/alloydb-plugin/evals/agent-mode"
export EVAL_SKILLS_DIR="/path/to/alloydb-plugin/skills"
export EVAL_GCP_PROJECT_ID="<your-gcp-project>"
export EVAL_GCP_PROJECT_REGION="us-central1"
export GOOGLE_CLOUD_PROJECT="${EVAL_GCP_PROJECT_ID}"
export EVAL_REPORTING_PROJECT="${EVAL_GCP_PROJECT_ID}"
export EVAL_REPORTING_DATASET="evalbench"
export RELEASE_VERSION="local-dev"

# Shared pool & foundation settings (for CUJ 2 and CUJ 3)
export EVAL_SHARED_CLUSTER="<shared-alloydb-cluster>"
export EVAL_SHARED_POOL="<shared-alloydb-agent-pool>"
export EVAL_SHARED_DATABASE="postgres"
export EVAL_FOUNDATION_SUFFIX="-evals"
export EVAL_SHARED_VPC="agents-vpc"
export EVAL_SHARED_SUBNET="agents-subnet"
export EVAL_SHARED_ATTACHMENT="agents-psc-attachment-evals"

# Per-run resource names
export CUJ1_CLUSTER="cuj1-local-cluster"
export CUJ1_PRIMARY="cuj1-local-primary"
export CUJ1_POOL="cuj1-local-pool"
export CUJ1_VPC="cuj1-local-vpc"
export CUJ1_SUBNET="cuj1-local-subnet"
export CUJ2_NAME="cuj2-local"
export CUJ3_NAME="cuj3-local"
export CUJ3_ENGINE_PREFIX="cuj3_local"

# Optional: select a subset of scenarios (comma-separated)
export EVAL_SCENARIOS="cuj2-simple-agent"

export EVAL_CONFIG="${EVAL_SUITE_DIR}/run_config.yaml"
./evalbench/run.sh
```
