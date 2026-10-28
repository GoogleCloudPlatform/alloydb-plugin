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

r"""Deploys agent runtimes to Agent Engine and registers them in Gemini Enterprise.

Runtimes (in assets/agent_engine/):
  * agent.py       — main data agent (read-only primary DB + scratch DB)
  * coordinator.py — swarm coordinator (launches parallel investigations)

Usage (from the working directory):
    python scripts/deploy_agent.py {deploy|validate|register|teardown} --config
    <name>.alloydb-agent.yaml
"""

import argparse
import importlib
import importlib.metadata as im
import json
import os
import pathlib
import subprocess
import sys
import time
from typing import Any

from deploy_infra import _capture
from deploy_infra import _wait_deployment_unlocked
from deploy_infra import DeploymentConfig
from google.api_core import exceptions as api_exceptions
import requests

_DISCOVERYENGINE = "https://discoveryengine.googleapis.com/v1alpha"
# Every Gemini Enterprise registration is shared with all users of the app.
_GE_SHARE_SCOPE = "ALL_USERS"

SKILL_ROOT = pathlib.Path(__file__).resolve().parent.parent
AGENTS_DIR = SKILL_ROOT / "assets" / "agent_engine"

_COMMON_PINNED_PKGS = (
    "google-cloud-aiplatform",
    "google-adk",
    "pydantic",
    "google-auth",
    "mcp",
    "httpx2",
    "cloudpickle",
)
MAIN_PINNED_PKGS = _COMMON_PINNED_PKGS
COORDINATOR_PINNED_PKGS = (*_COMMON_PINNED_PKGS, "requests")


# =============================================================================
# 1. Top-Level Entrypoint (Big Picture)
# =============================================================================


def main() -> None:
  """Parses CLI arguments and dispatches the requested agent action."""
  args = _build_parser().parse_args()
  cfg = DeploymentConfig.from_file(args.config)

  if args.cmd == "deploy":
    AgentEngineDeployer(cfg).deploy()
  elif args.cmd == "validate":
    AgentValidator(cfg).validate()
  elif args.cmd == "register":
    GeminiEnterpriseRegistrar(cfg).register()
  elif args.cmd == "teardown":
    Teardown(cfg).run(yes=args.yes)


def _build_parser() -> argparse.ArgumentParser:
  """Builds the CLI argument parser for deploy_agent.py."""
  ap = argparse.ArgumentParser(
      description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
  )
  cfg_parent = argparse.ArgumentParser(add_help=False)
  cfg_parent.add_argument("--config", required=True)

  sub = ap.add_subparsers(dest="cmd", required=True)
  sub.add_parser(
      "deploy",
      parents=[cfg_parent],
      help=(
          "deploy the configured agent runtime(s) (main agent for a simple"
          " agent; main agent + swarm coordinator for an agent swarm)"
      ),
  )
  sub.add_parser(
      "validate",
      parents=[cfg_parent],
      help="validate the deployed main agent end-to-end",
  )
  sub.add_parser(
      "register",
      parents=[cfg_parent],
      help=(
          "register the deployed agent into a Gemini Enterprise app, shared"
          " with all users"
      ),
  )
  teardown = sub.add_parser(
      "teardown",
      parents=[cfg_parent],
      help=(
          "list what Steps 2-5 created for `name` (GE registrations, Agent"
          " Engines, per-deployment stack, AlloyDB IAM user); with --yes,"
          " delete it and verify that nothing is left"
      ),
  )
  teardown.add_argument(
      "--yes",
      action="store_true",
      help="delete the listed resources (only after the user confirmed them)",
  )
  return ap


# =============================================================================
# 2. Core Workflows (Top-Down Call Stack)
# =============================================================================


class AgentEngineDeployer:
  """Deploys the main agent and/or swarm coordinator to Agent Engine."""

  def __init__(self, cfg: DeploymentConfig) -> None:
    """Initializes the deployer with the deployment configuration."""
    self.cfg = cfg

  def deploy(self) -> tuple[str, str | None]:
    """Deploys the configured agent runtime(s) to Vertex AI Agent Engine.

    Always deploys the main data agent. When `agent_engine.coordinator` is
    configured, also deploys the swarm coordinator wired to the main agent.
    Existing engines for this deployment `name` are updated in place
    automatically.

    Returns:
      A `(main_resource, coordinator_resource)` tuple where
      `coordinator_resource` is None when no coordinator is configured.
    """
    main_resource = self.deploy_main()
    if not self.cfg.coordinator:
      return main_resource, None
    print("==> Wiring coordinator to the main agent")
    coord_resource = self.deploy_coordinator(main_resource)
    return main_resource, coord_resource

  def deploy_main(self) -> str:
    """Deploys the main data agent (`assets/agent_engine/agent.py`).

    Returns:
      The deployed or updated Agent Engine resource name.
    """
    resolved_workspace_url = (
        self.cfg.resolve_workspace_url() if self.cfg.agent_workspace else ""
    )
    runtime_env = {
        "AGENT_MODEL": self.cfg.model,
        "AGENT_NAME": _agent_name(self.cfg, "agent"),
        "AGENT_WORKSPACE_URL": resolved_workspace_url,
        "AGENT_CONTEXT": self.cfg.agent_context("agent"),
        **self._direct_primary_env(),
    }
    remote = self._stage_and_deploy_engine(
        module_name="agent",
        runtime_env=runtime_env,
        display_name=self.cfg.agent_display_name,
        pinned_pkgs=MAIN_PINNED_PKGS,
        enable_tracing=True,
    )
    print("==> Agent Engine resource:", remote.resource_name)
    print(f"    Runs as: {self.cfg.agent_sa}")
    return remote.resource_name

  def deploy_coordinator(self, target_engine: str) -> str:
    """Deploys the swarm coordinator (`assets/agent_engine/coordinator.py`).

    The coordinator always reaches the primary DIRECTLY at the AlloyDB Agent
    Pool (its generic `execute_sql_read_only` / `get_schema`); it has no
    scratch database of its own.

    Args:
      target_engine: Target main Agent Engine resource name.

    Returns:
      The deployed or updated coordinator Agent Engine resource name.
    """
    print(f"==> Swarm target: {target_engine}")
    coordinator_display, _ = self.cfg.coordinator_display_info()

    runtime_env = {
        "TARGET_ENGINE": target_engine,
        "TARGET_PROJECT": self.cfg.project_id,
        "TARGET_LOCATION": self.cfg.region,
        "TARGET_DISPLAY": self.cfg.agent_display_name,
        "AGENT_NAME": _agent_name(self.cfg, "coordinator"),
        "AGENT_CONTEXT": self.cfg.agent_context("coordinator"),
        "SWARM_WORK_PREAMBLE": self._work_preamble(),
        "AGENT_MODEL": self.cfg.model,
        **self._direct_primary_env(),
    }
    remote = self._stage_and_deploy_engine(
        module_name="coordinator",
        runtime_env=runtime_env,
        display_name=coordinator_display,
        pinned_pkgs=COORDINATOR_PINNED_PKGS,
    )
    print("==> Swarm coordinator resource:", remote.resource_name)
    print(f"    Runs as: {self.cfg.agent_sa}")
    print(f"    Target : {target_engine}")
    print(
        "    Register into Gemini Enterprise (chat-only; charts render inline)"
        " with:\n             .venv/bin/python"
        f" {pathlib.Path(__file__).resolve()} register --config"
        f" {self.cfg.path.name}"
    )
    return remote.resource_name

  def _direct_primary_env(self) -> dict[str, str]:
    """Returns PRIMARY_DB_* env vars pointing at the AlloyDB Agent Pool.

    Both agents use it: the pool serves `execute_sql_read_only` and
    `get_schema`; the Agent Workspace only hosts per-session scratch DBs.

    Returns:
      A mapping of PRIMARY_DB_* environment variables, or {} when unset.
    """
    ep = self.cfg.primary_endpoint()
    if not ep["url"]:
      return {}
    return {
        "PRIMARY_DB_URL": ep["url"],
        "PRIMARY_DB_CA_PEM": ep["ca_pem"],
        "PRIMARY_DB_NAME": self.cfg.db_name,
        "PRIMARY_DB_USER": self.cfg.agent_sa.removesuffix(
            ".gserviceaccount.com"
        ),
    }

  def _work_preamble(self) -> str:
    """Builds the investigation workflow preamble for the swarm coordinator."""
    parts = [
        "WORK DIRECTLY OFF THE PRIMARY:\n1. get_schema FIRST to learn the"
        " tables and columns.\n2. Answer every metric with"
        " execute_sql_read_only — read-only; keep result sets small; never"
        " claim a number a query did not return."
    ]
    if self.cfg.agent_workspace:
      parts.append(
          "To quantify a proposed remediation, SIMULATE it in your PRIVATE"
          " scratch database: scratch_provision_database, load the data you"
          " need and run the CURRENT baseline and your PROPOSED change on it"
          " with scratch_execute_sql, report the delta, then"
          " scratch_release_database. Provision ONLY for this step."
      )
    parts.append("Work autonomously (no clarifying questions).")
    return "\n".join(parts)

  def _stage_and_deploy_engine(
      self,
      module_name: str,
      runtime_env: dict[str, str],
      display_name: str,
      pinned_pkgs: tuple[str, ...],
      *,
      enable_tracing: bool = False,
  ):
    """Loads `root_agent` under `runtime_env` and deploys it with that env.

    The agent module reads its config from environment variables at import
    time, both here (where `root_agent` is built and pickled) and on the
    Agent Engine runtime (where unpickling re-imports the module). So the
    same values are set in the local `os.environ` for the import and shipped
    as the runtime's `env_vars`.

    Args:
      module_name: Name of the agent module in `assets/agent_engine/`.
      runtime_env: Environment variables injected at import and runtime.
      display_name: Human-readable display name for the Agent Engine.
      pinned_pkgs: Package names whose installed versions are pinned.
      enable_tracing: Whether to wrap the agent in `AdkApp` with Cloud Trace.

    Returns:
      The created or updated Vertex AI Agent Engine remote resource.
    """
    agent_engines = _init_vertexai(self.cfg)
    os.chdir(AGENTS_DIR)
    if str(AGENTS_DIR) not in sys.path:
      sys.path.insert(0, str(AGENTS_DIR))

    saved_env = {k: os.environ.get(k) for k in runtime_env}
    os.environ.update(runtime_env)
    try:
      if module_name in sys.modules:
        mod = importlib.reload(sys.modules[module_name])
      else:
        mod = importlib.import_module(module_name)
      agent_obj = mod.root_agent
    finally:
      for k, v in saved_env.items():
        if v is None:
          os.environ.pop(k, None)
        else:
          os.environ[k] = v

    extra_reqs: list[str] = []
    if enable_tracing:
      agent_obj = agent_engines.AdkApp(agent=agent_obj, enable_tracing=True)
      extra_reqs = ["opentelemetry-sdk", "opentelemetry-exporter-gcp-trace"]
      print("==> Tracing ENABLED (Cloud Trace).")

    pinned = [f"{pkg}=={im.version(pkg)}" for pkg in pinned_pkgs]
    create_kwargs: dict[str, Any] = {
        "agent_engine": agent_obj,
        "display_name": display_name,
        "gcs_dir_name": runtime_env["AGENT_NAME"],
        "extra_packages": [f"{module_name}.py", "utility.py"],
        "requirements": [
            "google-cloud-aiplatform[adk,agent_engines]",
            "matplotlib>=3.8",
            *pinned,
            *extra_reqs,
        ],
        "env_vars": {
            # Makes ADK's McpToolset open each MCP session with
            # `server/discover` (protocol 2026-07-28): the agent pool returns
            # row arrays as structuredContent, which the legacy initialize
            # handshake rejects.
            "ADK_ENABLE_MCP_MODERN_PROTOCOL": "1",
            **{k: v for k, v in runtime_env.items() if v},
        },
        "service_account": self.cfg.agent_sa,
    }
    psc = self._psc_interface_config()
    if psc:
      create_kwargs["psc_interface_config"] = psc

    existing = _find_engine(self.cfg, module_name)
    if existing:
      print(
          f"==> Updating existing Agent Engine ({display_name}):"
          f" {existing.resource_name}"
      )
      return agent_engines.update(
          resource_name=existing.resource_name, **create_kwargs
      )
    return agent_engines.create(**create_kwargs)

  def _psc_interface_config(self) -> dict[str, Any]:
    """Builds PSC egress + DNS peering config for `run.app` & `alloydb.goog`."""
    if not (self.cfg.network_attachment and self.cfg.network):
      return {}
    return {
        "network_attachment": (
            f"projects/{self.cfg.project_id}/regions/{self.cfg.region}"
            f"/networkAttachments/{self.cfg.network_attachment}"
        ),
        "dns_peering_configs": [
            {
                "domain": domain,
                "target_project": self.cfg.project_id,
                "target_network": self.cfg.network,
            }
            for domain in ("run.app.", "alloydb.goog.")
        ],
    }


class GeminiEnterpriseRegistrar:
  """Registers or updates an agent in a Gemini Enterprise app."""

  def __init__(self, cfg: DeploymentConfig) -> None:
    """Initializes the registrar with the deployment configuration."""
    self.cfg = cfg

  def register(self) -> None:
    """Registers or updates the deployed agent in the configured GE application.

    No-op when `gemini_enterprise.app_id` is not configured. Otherwise the agent
    is always shared with every user of the app
    (`sharingConfig.scope=ALL_USERS`);
    an existing registration with any other scope is patched to it.
    """
    app_id = (self.cfg.gemini_enterprise.get("app_id") or "").strip()
    if not app_id:
      print("==> gemini_enterprise.app_id not set; skipping registration")
      return
    all_engines = _find_engines(self.cfg)
    # With a coordinator configured, register the coordinator; never fall back
    # to the main agent in its place.
    role = "coordinator" if self.cfg.coordinator else "agent"
    engine = next(
        (
            e
            for e in all_engines
            if _engine_agent_name(e) == _agent_name(self.cfg, role)
        ),
        None,
    )
    if engine is None:
      what = "swarm coordinator" if self.cfg.coordinator else "main agent"
      sys.exit(
          f"No {what} Agent Engine found for {self.cfg.name} — run"
          " `deploy_agent.py deploy --config <config>` first."
      )
    engine_resource = engine.resource_name
    deployment_engines = {e.resource_name for e in all_engines}
    if self.cfg.coordinator:
      display, desc = self.cfg.coordinator_display_info()
    else:
      display = self.cfg.agent_display_name
      desc = self.cfg.gemini_enterprise.get("description") or (
          f"Answers questions about {display} using read-only SQL queries and"
          " inline charts."
      )

    print(
        f"==> Registering {engine_resource.split('/')[-1]} into GE app {app_id}"
    )
    base = (
        f"{_DISCOVERYENGINE}/projects/{self.cfg.project_id}"
        f"/locations/global/collections/default_collection/engines/{app_id}"
        "/assistants/default_assistant/agents"
    )
    body = {
        "displayName": display,
        "description": desc,
        "sharingConfig": {"scope": _GE_SHARE_SCOPE},
        "adkAgentDefinition": {
            "toolSettings": {"toolDescription": desc},
            "provisionedReasoningEngine": {"reasoningEngine": engine_resource},
        },
    }
    existing = next(
        (
            a
            for a in _list_ge_agents(base, self.cfg.project_id)
            if a.get("adkAgentDefinition", {})
            .get("provisionedReasoningEngine", {})
            .get("reasoningEngine")
            in deployment_engines
        ),
        None,
    )
    if existing:
      agent_id = existing["name"].split("/")[-1]
      fields = [
          f
          for f in ("displayName", "description")
          if existing.get(f) != body[f]
      ]
      existing_re = (
          existing.get("adkAgentDefinition", {})
          .get("provisionedReasoningEngine", {})
          .get("reasoningEngine")
      )
      if existing_re != engine_resource or "description" in fields:
        fields.append("adkAgentDefinition")
      if (existing.get("sharingConfig") or {}).get("scope") != _GE_SHARE_SCOPE:
        fields.append("sharingConfig")
      if fields:
        _rest(
            "PATCH",
            f"{_DISCOVERYENGINE}/{existing['name']}",
            self.cfg.project_id,
            params={"updateMask": ",".join(fields)},
            body={f: body[f] for f in fields},
        )
        print(f"    updated existing agent {agent_id} ({', '.join(fields)})")
      else:
        print(f"    already registered ({agent_id}); no change")
      print(f"    shared with: {_GE_SHARE_SCOPE}")
      return

    created = _rest("POST", base, self.cfg.project_id, body=body)
    print(
        f"    registered agent {created.get('name', '').split('/')[-1]} "
        f"(state {created.get('state')}), shared with:"
        f" {(created.get('sharingConfig') or {}).get('scope', _GE_SHARE_SCOPE)}"
    )


class Teardown:
  """Deletes what Steps 2-5 created for one deployment, in dependency order.

  Finds everything from `name` (not from the current topology settings), so a
  partial deployment or a changed config still tears down cleanly, and it is
  safe to re-run. Keeps the shared foundation, the network, and the pool.
  """

  def __init__(self, cfg: DeploymentConfig) -> None:
    """Initializes the teardown with the deployment configuration."""
    self.cfg = cfg
    self.stack = (
        f"projects/{cfg.project_id}/locations/{cfg.region}"
        f"/deployments/alloydb-agent-{cfg.name}"
    )
    self.db_user = cfg.agent_sa.removesuffix(".gserviceaccount.com")

  def run(self, yes: bool) -> None:
    """Lists the deployment's resources; with `yes`, deletes and verifies them."""
    found = self._inventory()
    print(
        "==> Keeps the shared foundation (alloydb-agent-project"
        f"{self.cfg.name_suffix}), the network, and the pool"
    )
    if not found:
      print(f"TEARDOWN PASS: nothing left for {self.cfg.name}")
      return
    print(f"==> Deployed for {self.cfg.name}:")
    for kind, item in found:
      print(f"    {kind} {_label(item)}")
    if not yes:
      print(
          "==> Nothing deleted. Show this list to the user and re-run with"
          " --yes once they confirm."
      )
      return
    try:
      for kind, item in found:
        self._delete(kind, item)
    except (
        subprocess.CalledProcessError,
        RuntimeError,
        api_exceptions.GoogleAPIError,
    ) as exc:
      sys.exit(
          f"TEARDOWN FAIL: {exc}. Fix it and re-run; done steps are skipped."
      )
    left = self._inventory()
    for _ in range(5):  # Listings can lag behind a finished deletion.
      if not left:
        break
      time.sleep(10)
      left = self._inventory()
    if left:
      sys.exit(
          "TEARDOWN FAIL: still present: "
          + "; ".join(f"{kind} {_label(item)}" for kind, item in left)
      )
    print(f"TEARDOWN PASS: nothing left for {self.cfg.name}")

  def _inventory(self) -> list[tuple[str, Any]]:
    """Returns (kind, resource) for what exists, in deletion order."""
    engines = _find_engines(self.cfg)
    found = [("Gemini Enterprise agent", a) for a in self._ge_agents(engines)]
    found += [("Agent Engine", eng) for eng in engines]
    if self._stack_exists():
      found.append(("stack", self.stack))
    if self._db_user_exists():
      found.append(("AlloyDB IAM database user", self.db_user))
    return found

  def _delete(self, kind: str, item: Any) -> None:
    """Deletes one resource and waits until the deletion has finished."""
    print(f"==> Deleting {kind} {_label(item)}")
    if kind == "Gemini Enterprise agent":
      _rest(
          "DELETE",
          f"{_DISCOVERYENGINE}/{item}",
          self.cfg.project_id,
          allow_404=True,
      )
    elif kind == "Agent Engine":
      item.delete(force=True)  # Also deletes its sessions.
    elif kind == "stack":
      _wait_deployment_unlocked(
          self.cfg.project_id, self.cfg.region, f"alloydb-agent-{self.cfg.name}"
      )
      subprocess.run(
          [
              "gcloud",
              "infra-manager",
              "deployments",
              "delete",
              item,
              f"--project={self.cfg.project_id}",
              "--delete-policy=DELETE",
              "--quiet",
          ],
          check=True,
      )
    else:
      res = _capture(
          ["gcloud", "alloydb", "users", "delete", item, *self._on_cluster()]
      )
      if res.returncode != 0 and "NOT_FOUND" not in (res.stderr or ""):
        raise RuntimeError((res.stderr or res.stdout or "").strip())

  def _ge_agents(self, engines: list[Any]) -> list[str]:
    """Returns the Gemini Enterprise agents that point at `engines`."""
    app_id = (self.cfg.gemini_enterprise.get("app_id") or "").strip()
    if not app_id or not engines:
      return []
    url = (
        f"{_DISCOVERYENGINE}/projects/{self.cfg.project_id}"
        f"/locations/global/collections/default_collection/engines/{app_id}"
        "/assistants/default_assistant/agents"
    )
    targets = {eng.resource_name for eng in engines}
    return [
        a["name"]
        for a in _list_ge_agents(url, self.cfg.project_id, allow_404=True)
        if a.get("adkAgentDefinition", {})
        .get("provisionedReasoningEngine", {})
        .get("reasoningEngine")
        in targets
    ]

  def _stack_exists(self) -> bool:
    """Returns whether the per-deployment stack exists."""
    res = subprocess.run(
        [
            "gcloud",
            "infra-manager",
            "deployments",
            "describe",
            self.stack,
            f"--project={self.cfg.project_id}",
            "--format=value(state)",
        ],
        capture_output=True,
        check=False,
        text=True,
    )
    if res.returncode and "NOT_FOUND" not in res.stderr:
      sys.exit(f"Could not check {self.stack}: {res.stderr.strip()}")
    return res.returncode == 0

  def _db_user_exists(self) -> bool:
    """Returns whether the database user exists on the cluster."""
    if not self.cfg.cluster:
      return False
    res = _capture(["gcloud", "alloydb", "users", "list", *self._on_cluster()])
    if res.returncode == 0:
      return any(n.endswith(f"/{self.db_user}") for n in res.stdout.split())
    if "NOT_FOUND" in (res.stderr or ""):
      print(f"    cluster {self.cfg.cluster} is gone")
      return False
    sys.exit(f"Could not list users on {self.cfg.cluster}: {res.stderr}")

  def _on_cluster(self) -> list[str]:
    """Returns the gcloud flags that address `database.cluster` quietly."""
    return [
        f"--cluster={self.cfg.cluster}",
        f"--region={self.cfg.region}",
        f"--project={self.cfg.project_id}",
        "--format=value(name)",
        "--quiet",
    ]


def _label(item: Any) -> str:
  """Returns a printable name for a resource from `Teardown._inventory`."""
  return getattr(item, "resource_name", item)


class AgentValidator:
  """Validates a deployed Agent Engine runtime end-to-end."""

  _SIMPLE_PROMPT = (
      "Inspect the database schema with get_schema, then run"
      " execute_sql_read_only to count the rows of any table (or SELECT 1 if"
      " there are no tables) and report the result."
  )
  _SIMPLE_TOOLS = ("get_schema", "execute_sql_read_only")

  _SWARM_PROMPT = (
      "Inspect the primary database with get_schema and run"
      " execute_sql_read_only to sample up to 5 rows from any table (or SELECT"
      " 1 if empty). Then call scratch_provision_database, create a scratch"
      " table and insert the sample with scratch_execute_sql, verify the row"
      " count, and call scratch_release_database."
  )
  _SWARM_TOOLS = (
      "get_schema",
      "execute_sql_read_only",
      "scratch_provision_database",
      "scratch_execute_sql",
      "scratch_release_database",
  )

  def __init__(self, cfg: DeploymentConfig) -> None:
    """Initializes the validator with the deployment configuration."""
    self.cfg = cfg

  def validate(self) -> None:
    """Streams a schema-agnostic validation prompt and verifies expected tool calls."""
    agent = _find_engine(self.cfg, "agent")
    if agent is None:
      sys.exit(f"No Agent Engine deployment found for {self.cfg.name}.")
    if self.cfg.agent_workspace:
      message, expect_tools = self._SWARM_PROMPT, self._SWARM_TOOLS
    else:
      message, expect_tools = self._SIMPLE_PROMPT, self._SIMPLE_TOOLS
    print(
        f"==> Validate: {agent.resource_name.split('/')[-1]} "
        f" message={message!r}"
    )
    tool_calls, succeeded_tools, tool_errors, texts, has_image = (
        [],
        set(),
        0,
        [],
        False,
    )
    for ev in agent.stream_query(
        user_id="deploy-agent-validate", message=message
    ):
      parts = (
          (ev.get("content") or {}).get("parts", [])
          if isinstance(ev, dict)
          else []
      )
      for part in parts:
        if "function_call" in part:
          name = part["function_call"].get("name")
          tool_calls.append(name)
          args_preview = json.dumps(part["function_call"].get("args", {}))[:120]
          print(f"[tool] {name}({args_preview})")
        elif "function_response" in part:
          fn_resp = part["function_response"]
          rname = fn_resp.get("name")
          resp = fn_resp.get("response")
          if _is_tool_error(resp):
            tool_errors += 1
          elif rname:
            succeeded_tools.add(rname)
          resp_preview = str(resp)[:160]
          print(f"[resp] {resp_preview}")
        elif part.get("inline_data") or part.get("inlineData"):
          has_image = True
        elif "text" in part:
          texts.append(part["text"])
          print(part["text"])

    final = "\n".join(texts).strip()
    problems = []
    if not tool_calls:
      problems.append("no tool calls")
    elif tool_errors >= len(tool_calls):
      problems.append(f"all {tool_errors} tool call(s) returned errors")
    if not final:
      problems.append("empty final response")
    elif len(final) < 250 and any(
        k in final.lower() for k in ("i cannot", "i can't", "unable to")
    ):
      problems.append("final response looks like a refusal/error")
    for tool_name in expect_tools:
      if tool_name not in tool_calls:
        problems.append(f"expected tool `{tool_name}` was not called")
      elif tool_name not in succeeded_tools:
        problems.append(f"expected tool `{tool_name}` returned an error")
    if problems:
      print("VALIDATE FAIL:", "; ".join(problems))
      sys.exit(1)
    print(
        f"VALIDATE PASS: {len(tool_calls)} tool call(s)"
        f"{' + chart' if has_image else ''}, {len(final)}-char response"
    )


def _is_tool_error(resp: Any) -> bool:
  """Returns True if a tool response dictionary indicates an execution error.

  Also checks the payloads a response can wrap: ADK's `result` (a non-dict
  tool return) and an MCP tool result's `structuredContent`, where the Agent
  Workspace returns its errors as ordinary results (`{"error": ...}`).
  """
  if not isinstance(resp, dict):
    return False
  for payload in (resp, resp.get("result"), resp.get("structuredContent")):
    if isinstance(payload, dict) and (
        payload.get("error")
        or payload.get("status") in ("failed", "error")
        or payload.get("isError")
        or payload.get("is_error")
    ):
      return True
  return False


# =============================================================================
# 3. Shared SDK, Metadata & REST Helpers
# =============================================================================


def _init_vertexai(cfg: DeploymentConfig):
  """Initializes `vertexai` for `cfg` and returns `vertexai.agent_engines`."""
  import vertexai  # pylint: disable=g-import-not-at-top
  from vertexai import agent_engines  # pylint: disable=g-import-not-at-top

  vertexai.init(
      project=cfg.project_id,
      location=cfg.region,
      staging_bucket=cfg.staging_bucket,
  )
  return agent_engines


def _agent_name(cfg: DeploymentConfig, role: str) -> str:
  """Returns the unique `AGENT_NAME` identifier for `cfg.name` and `role`."""
  suffix = "swarm_coordinator" if role == "coordinator" else "agent"
  return f"{cfg.name.replace('-', '_')}_{suffix}"


def _engine_agent_name(eng: Any) -> str:
  """Returns the `AGENT_NAME` env value on `eng`, or `""`."""
  for v in eng.gca_resource.spec.deployment_spec.env:
    if v.name == "AGENT_NAME":
      return v.value
  return ""


def _find_engines(cfg: DeploymentConfig, *roles: str) -> list[Any]:
  """Returns deployed Agent Engines for `cfg.name` matching `roles` in order."""
  names = [_agent_name(cfg, r) for r in roles or ("coordinator", "agent")]
  found = [
      (names.index(n), e)
      for e in _init_vertexai(cfg).list()
      if (n := _engine_agent_name(e)) in names
  ]
  return [e for _, e in sorted(found, key=lambda pair: pair[0])]


def _find_engine(cfg: DeploymentConfig, role: str) -> Any:
  """Finds the deployed Agent Engine for `cfg.name` and `role`, or None."""
  engines = _find_engines(cfg, role)
  return engines[0] if engines else None


_ADC_CREDS = None


def _adc_token() -> str:
  """Returns a valid Google Cloud Platform OAuth2 access token from ADC."""
  global _ADC_CREDS
  import google.auth  # pylint: disable=g-import-not-at-top
  import google.auth.transport.requests  # pylint: disable=g-import-not-at-top

  if _ADC_CREDS is None:
    _ADC_CREDS, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
  if not _ADC_CREDS.valid:
    _ADC_CREDS.refresh(google.auth.transport.requests.Request())
  return _ADC_CREDS.token


_TRANSIENT = (
    requests.exceptions.ConnectionError,
    requests.exceptions.Timeout,
    requests.exceptions.ChunkedEncodingError,
)


def _rest(
    method: str,
    url: str,
    project: str,
    body: dict[str, Any] | None = None,
    params: dict[str, Any] | None = None,
    ok: tuple[int, ...] = (200,),
    allow_404: bool = False,
) -> dict[str, Any]:
  """Performs an ADC-authenticated JSON REST request with transient retries."""
  last = None
  for attempt in range(4):
    try:
      resp = requests.request(
          method,
          url,
          params=params or {},
          headers={
              "Authorization": f"Bearer {_adc_token()}",
              "X-Goog-User-Project": project,
              "Content-Type": "application/json",
          },
          json=body,
          timeout=120,
      )
      if allow_404 and resp.status_code == 404:
        return {}
      if resp.status_code >= 500:
        last = RuntimeError(
            f"{method} {url.split('?')[0]} -> {resp.status_code}:"
            f" {resp.text[:300]}"
        )
      elif resp.status_code not in ok and not resp.ok:
        raise RuntimeError(
            f"{method} {url.split('?')[0]} -> {resp.status_code}:"
            f" {resp.text[:400]}"
        )
      else:
        return resp.json() if resp.text.strip() else {}
    except _TRANSIENT as exc:
      last = exc
    time.sleep(min(2**attempt, 8))
  raise last if last else RuntimeError(f"{method} {url} failed after retries")


def _list_ge_agents(
    url: str, project: str, allow_404: bool = False
) -> list[dict[str, Any]]:
  """Returns every agent from a Gemini Enterprise `agents` URL, page by page."""
  agents: list[dict[str, Any]] = []
  params: dict[str, Any] = {}
  while True:
    page = _rest("GET", url, project, params=params, allow_404=allow_404)
    agents += page.get("agents", [])
    if not page.get("nextPageToken"):
      return agents
    params = {"pageToken": page["nextPageToken"]}


if __name__ == "__main__":
  main()
