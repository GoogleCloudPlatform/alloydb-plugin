---
name: alloydb-agent-mode-quickstart
description: >-
  Provisions AlloyDB agent pools and deploys AI data agents or multi-agent
  swarms on Vertex AI Agent Engine and Gemini Enterprise. Three capabilities:
  (1) provision an AlloyDB agent pool over Private Service Connect (PSC) using
  gcloud; (2) deploy a single agent querying the pool over MCP (get_schema,
  execute_sql_read_only) with optional per-session writable PostgreSQL scratch
  databases (Cloud Run Agent Workspace); (3) deploy an agent swarm with a
  coordinator that fans questions across parallel worker sessions. Use when the
  user wants to set up an AlloyDB agent pool, or deploy, update, validate,
  register in Gemini Enterprise, or tear down a data agent or agent swarm on an
  AlloyDB database (the agent generates and manages ./<name>.alloydb-agent.yaml
  automatically). Don't use for standard non-agent AlloyDB
  administration or standalone SQL query tuning.
compatibility: >-
  Self-contained (all scripts and assets are under scripts/ and assets/).
  Requires an authenticated gcloud CLI, Python 3.11+, bash, and Google Cloud
  network access. Uses preview GCP APIs (Agent Engine PSC interface). Step 5
  additionally requires a Gemini Enterprise subscription or trial, a
  global-location app, and Gemini Enterprise Admin + Discovery Engine Admin
  roles.
license: Apache-2.0
metadata:
  version: "0.1-preview"
---

# AlloyDB Agent Pool Agents — from one pool to a swarm

Enables an agent pool on a user's AlloyDB cluster, then deploys a running agent
that answers questions against that read-only pool: either a single agent, or a
swarm of parallel investigators with isolated per-session PostgreSQL scratch
databases. The user does not need to write a config file by hand—ask for any
missing settings and generate `./<name>.alloydb-agent.yaml` in the current
working directory to drive the deployment scripts.

## Capabilities (pick one first)

Ask which capability the user wants, then run only its steps:

1.  **Provision an agent pool (Step P, plain `gcloud`, no config file):**
    enables agent mode on an AlloyDB cluster, creates a dedicated VPC/subnet,
    and provisions an `AGENT_POOL` instance reachable over PSC.
2.  **Simple agent (Steps 0–5):** deploys one agent (`<name>_agent`) querying
    the pool over MCP (`get_schema`, `execute_sql_read_only`) and optionally
    publishes it to Gemini Enterprise.
3.  **Agent swarm (Steps 0–5):** deploys a worker agent with per-session scratch
    PostgreSQL databases (`agent_engine.agent.workspace: true`) plus a
    coordinator (`<name>_swarm_coordinator`, via `agent_engine.coordinator`)
    that fans questions across parallel worker sessions.

**Key rules across capabilities:**

-   **Prerequisite pool:** Capabilities 2 and 3 require an AlloyDB agent pool in
    `READY`. Run capability 1 (Step P) first unless the user already has one.
-   **Agent-managed config (`./<name>.alloydb-agent.yaml`):** Generate and
    maintain `./<name>.alloydb-agent.yaml` in the current working directory
    (alongside `./.venv`). Two orthogonal knobs under `agent_engine` control the
    deployed topology:
    1.  `agent.workspace: true | false` — controls whether Step 2 deploys the
        Cloud Run Agent Workspace (`alloydb-agent-workspace-<name>`) to give
        each session a private writable PostgreSQL scratch database.
    2.  `coordinator` (optional block) — controls whether Step 3 deploys the
        Swarm Coordinator (`<name>_swarm_coordinator`) and Step 5 registers the
        coordinator instead of the single agent in Gemini Enterprise.
-   **Upgrade in place or tear down:** A simple agent can enable scratch
    databases or a coordinator later by updating `./<name>.alloydb-agent.yaml`
    and re-running Steps 2–5. For updates and reverse-order teardown, see
    [references/updates_and_teardown.md](references/updates_and_teardown.md).
    Read it before deleting anything. To delete one deployment, run
    `deploy_agent.py teardown --config <config_path>`: it only lists what it
    would delete. Show that list, end your turn, and re-run with `--yes` only
    after the user confirms, even when they already asked for the teardown.

**Working directory and `<skill>` path.** Run Steps 0–5 from a consistent
working directory (where `bootstrap_env.sh` creates `./.venv`), replacing
`<skill>` in commands below with the path to this skill directory. All cloud
resources are namespaced by `<name>` so multiple deployments in one project
never collide.

## Workflow (run in this order)

Each step is a task node that provisions or verifies cloud resources. Follow
these execution rules across the graph:

-   **Collect missing inputs before running commands:** Before running Step P or
    Step 0, check the required inputs for the chosen capability (listed in Step
    P or Step 1), ask the user for any missing settings directly in your chat
    reply, and **end your turn** to wait for their answer. If an interactive
    question tool is skipped or unavailable, ask in plain text—never invent
    resource names, passwords, or network settings.
-   **Explain the overall plan before creating cloud resources:** Once inputs
    are collected (before Step P or before Step 2), briefly tell the user what
    resources will be created and the expected total time (~15–30 min for an
    agent pool; ~8–15 min for a simple agent; ~12–20 min for an agent swarm).
-   **Before each step:** explain in plain language what the step is about to do
    and how long it typically takes (`Takes`) before running the command.
-   **After each step:** report what succeeded and the outputs needed by
    downstream steps (`AGENT_SA`, `AGENT_WORKSPACE_URL`, Agent Engine resource
    names).
-   **Never chain steps silently on failure:** verify each step's output before
    proceeding; stop and troubleshoot with the user on any error.

### P. Provision the AlloyDB agent pool (capability 1)

> **Skip** if the user already has a `READY` agent pool. Put its cluster, pool
> instance, and database into `database` in `./<name>.alloydb-agent.yaml` and
> start at Step 0.

**Goal:** Enable agent mode on the user's AlloyDB cluster and provision a
dedicated VPC, subnet, service connection policy, and `AGENT_POOL` instance
reachable over PSC.

-   **Input:** `<project_id>`, `<region>`, `<cluster>`, `<primary>` and its
    size, `<pool>`, `<vpc>`, `<subnet>`, and the initial `postgres` password (if
    new cluster) (collect in one message)
-   **Output:** a `READY` agent pool with `agentPoolInfo.dnsName`, plus the
    `project_id`, `region`, `vpc`, and `database` values for
    `./<name>.alloydb-agent.yaml`
-   **Takes:** ~15–30 min (prepare the network in parallel while agent mode
    provisions)

**Prerequisites:** permissions to create AlloyDB clusters/instances, VPCs, and
service connection policies in `<project_id>`.

**Guidance:** Follow
[references/agent_pool_setup.md](references/agent_pool_setup.md) step by step
using `gcloud`, confirming each command's output before running the next.

**Rules:**

-   Strict creation order: enable `dns.googleapis.com` → create VPC, subnet, and
    service connection policy → wait for cluster `agentModeInfo.state: ACTIVE` →
    create the `AGENT_POOL` instance. Out-of-order creation leaves the pool's
    private DNS zone unprovisioned.
-   At most one agent pool per cluster; deleting a pool blocks recreation on
    that cluster until backend cleanup finishes. Never delete a pool to retry
    without asking.
-   Use only the cluster the user names; never offer or change other clusters in
    the project.
-   Loading sample data (P.3) is optional and runs in AlloyDB Studio; do not
    block Steps 0–3 on it.

### 0. Environment initialization

**Goal:** Verify local CLI prerequisites (`python3` 3.11+, `gcloud`, user auth,
and ADC auth) and initialize `./.venv` in the working directory.

-   **Input:** current working directory
-   **Output:** `./.venv` with pinned runtime and deployment packages
-   **Takes:** ~1 min

**Prerequisites:** required settings for Step 1 collected from the user (or from
Step P); run from the working directory you will use for Steps 1–5.

**Guidance:** Run `bootstrap_env.sh` once per working directory:

```bash
"<skill>"/scripts/bootstrap_env.sh
```

**Rules:**

-   User credentials and ADC must both work before Step 1. If either fails, ask
    the user to run `gcloud auth login` or `gcloud auth application-default
    login`; never run them yourself (they need the user's browser).

### 1. Generate and validate the config

**Goal:** Collect any missing settings from the user, generate
`./<name>.alloydb-agent.yaml` in the current working directory from the
template, and validate all fields and topology settings offline.

-   **Input:** user requirements and environment settings; writes
    `<config_path>` (`./<name>.alloydb-agent.yaml`) in the current working
    directory for Steps 2–5 and teardown
-   **Output:** `==> Topology: ...` and `==> Valid.`, or a list of errors to fix
-   **Takes:** seconds (offline check)

**Prerequisites:** Step 0 passed.

**Guidance:**

1.  **Collect missing inputs in one message** (never guess environment names; if
    you just ran Step P, reuse its outputs without re-asking):
    -   **Required from the user:** `<project_id>`, `<region>`, `database`
        (`cluster`, `instance` pool ID, `database` name), and `vpc` (`network`,
        `subnet`, and `network_attachment`—or offer defaults `agents-vpc`,
        `agents-subnet`, `agents-psc-attachment<name_suffix>`).
    -   **Ask only if relevant or requested:** deployment `name` (otherwise
        derive `<db>-agent` or `<db>-swarm` with `_` replaced by `-`, lowercase
        alphanumeric and hyphens only, truncated to `<=24` chars), `name_suffix`
        (for shared foundation isolation), domain `context`, and
        `gemini_enterprise.app_id`.
    -   **Auto-populate defaults:** derive `agent_engine.agent.display_name`
        (and `coordinator.display_name` when deploying a swarm) from `name`, set
        `agent_engine.agent.workspace` (`false` for simple agent, `true` for
        swarm), and include `agent_engine.coordinator` only when deploying a
        swarm.
2.  **Write `./<name>.alloydb-agent.yaml`** in the current working directory
    (modeled on `"<skill>"/assets/example.alloydb-agent.yaml`) and run
    `validate_config.py`:

```bash
.venv/bin/python "<skill>"/scripts/validate_config.py --config <config_path>
```

Check the printed topology line before continuing:

-   `agent_workspace=NO` vs. `agent_workspace=yes (per-session scratch
    databases)` reflects `agent_engine.agent.workspace`.
-   `coordinator=NO (single agent)` vs. `coordinator=yes (swarm coordinator)`
    reflects whether `agent_engine.coordinator` is present.

**Rules:**

-   Do not proceed until validation exits `0`. Fix `<config_path>`
    directly—never edit generated Terraform or bundle files.
-   Show the user the validated `./<name>.alloydb-agent.yaml` and briefly
    explain what Steps 2–5 will provision and how long they take before starting
    Step 2.
-   `agent_engine.agent.display_name` must not contain `"Coordinator"`;
    `agent_engine.coordinator.display_name` (when set) should contain
    `"Coordinator"`.

### 2. Provision cloud infrastructure

**Goal:** Provision the shared project networking/storage foundation, the
per-deployment service account and AlloyDB IAM user, and (when
`agent_engine.agent.workspace: true`) the Cloud Run Agent Workspace service.

-   **Input:** a validated `<config_path>`
-   **Output:** PSC network attachment, `AGENT_SA`
    (`agent-<name>@<project_id>.iam.gserviceaccount.com`), AlloyDB IAM user
    (`agent-<name>@<project_id>.iam`), and (when `workspace: true`)
    `AGENT_WORKSPACE_URL` for `alloydb-agent-workspace-<name>`
-   **Takes:** ~1–4 min warm; ~5–10 min on first run in a fresh project

**Prerequisites:** Step 1 passed; permissions to enable APIs, manage IAM, and
run Infrastructure Manager in `<project_id>`.

**Guidance:** Run `deploy_infra.py` (idempotent):

```bash
.venv/bin/python "<skill>"/scripts/deploy_infra.py --config <config_path>
```

It provisions two Infrastructure Manager stacks (creating only missing resources
and leaving pre-existing ones untouched), plus the read-only `IAM_BASED` AlloyDB
database user (`agent-<name>@<project_id>.iam`) on `database.cluster`:

1.  **Shared foundation (`alloydb-agent-project<name_suffix>`):** APIs,
    VPC/subnet, PSC endpoint, private `*.run.app` DNS, network attachment,
    service-agent IAM, staging bucket, and Artifact Registry repo.
2.  **Per-deployment stack (`alloydb-agent-<name>`):** `AGENT_SA` + IAM roles,
    and (when `agent_engine.agent.workspace: true`) the
    `alloydb-agent-workspace-<name>` Cloud Run service.

**Rules:**

-   When `agent_engine.agent.workspace: true`, verify `isolation-self-check:
    PASS` in Cloud Run logs on first deploy (`gcloud run services logs read
    alloydb-agent-workspace-<name> --project=<project_id> --region=<region>
    --limit=50`).

### 3. Deploy to Agent Engine

**Goal:** Package and deploy the ADK agent runtime(s) to Vertex AI Agent Engine
with PSC egress and MCP toolsets wired.

-   **Input:** the validated `<config_path>` (auto-resolves the Agent Pool DNS
    name and, when `workspace: true`, the Cloud Run `AGENT_WORKSPACE_URL`)
-   **Output:** deployed Agent Engine resource name(s)
    (`projects/<project_id>/locations/<region>/reasoningEngines/<engine_id>`):
    `<name>_agent`, plus `<name>_swarm_coordinator` when
    `agent_engine.coordinator` is configured
-   **Takes:** ~5 min for a single agent; ~10 min when `coordinator` is also
    configured

**Prerequisites:** Step 2 passed.

**Guidance:** Run `deploy_agent.py deploy` (idempotent—updates existing engines
for `<name>` in place):

```bash
.venv/bin/python "<skill>"/scripts/deploy_agent.py deploy --config <config_path>
```

**Rules:**

-   Record the deployed Agent Engine resource name(s) in your step summary.

### 4. Validate the deployed agent

**Goal:** Run a live validation turn against `<name>_agent` to verify end-to-end
MCP connectivity and tool execution.

-   **Input:** `<config_path>` with Step 3 deployed
-   **Output:** `VALIDATE PASS: ...` (exit 0) or diagnostic failure (exit 1)
-   **Takes:** ~2 min

**Prerequisites:** Step 3 passed.

**Guidance:** Run `deploy_agent.py validate`:

```bash
.venv/bin/python "<skill>"/scripts/deploy_agent.py validate --config <config_path>
```

If validation fails, consult
[references/troubleshooting.md](references/troubleshooting.md).

**Rules:**

-   Report the agent as working only after `deploy_agent.py validate` exits `0`
    (`VALIDATE PASS`); never claim success on a validation failure or script
    error.

### 5. Publish to Gemini Enterprise

> **Skip / No-op** if `gemini_enterprise.app_id` is empty or omitted.

**Goal:** Register the deployed agent into the user's Gemini Enterprise app and
share it with all app users (`sharingConfig.scope: ALL_USERS`).

-   **Input:** `<config_path>` with `gemini_enterprise.app_id` set
-   **Output:** Discovery Engine agent registration shared with `ALL_USERS`
    (registers `<name>_swarm_coordinator` when `agent_engine.coordinator` is
    configured, otherwise `<name>_agent`)
-   **Takes:** seconds

**Prerequisites:** Step 4 passed; a Gemini Enterprise app in the **`global`**
location; caller holds Gemini Enterprise Admin and Discovery Engine Admin roles.

**Guidance:** Run `deploy_agent.py register` (idempotent—creates or patches the
registration in place; no-op if `gemini_enterprise.app_id` is empty):

```bash
.venv/bin/python "<skill>"/scripts/deploy_agent.py register --config <config_path>
```

See [references/swarm_coordinator.md](references/swarm_coordinator.md) for
Gemini Enterprise setup, licensing notes, and chat test prompts.

**Rules:**

-   When `gemini_enterprise.app_id` is set, confirm the output reports `shared
    with: ALL_USERS`.
-   Write `gemini_enterprise.description` in terms of what questions the agent
    can answer (Gemini Enterprise uses this description for query routing).
-   A missing end-user Gemini Enterprise license blocks that user from opening
    the app UI, but is not a registration failure—report the distinction
    clearly.

## References

-   [references/agent_pool_setup.md](references/agent_pool_setup.md) — **Step P
    (capability 1)**: enable agent mode on an AlloyDB cluster, configure VPC/PSC
    networking, and create the `AGENT_POOL` instance.
-   [references/swarm_coordinator.md](references/swarm_coordinator.md) —
    **Gemini Enterprise & swarm test flow**: Step 5 prerequisites, registration,
    and chat test prompts.
-   [references/updates_and_teardown.md](references/updates_and_teardown.md) —
    **Updates & teardown**: updating an existing deployment from
    `./<name>.alloydb-agent.yaml` and tearing down per-deployment stacks,
    project foundation, and AlloyDB pools cleanly.
-   [references/troubleshooting.md](references/troubleshooting.md) —
    **Troubleshooting**: log locations and symptom-to-fix guides for Step P,
    infrastructure, MCP tool calls, Agent Workspace, and Gemini Enterprise.
