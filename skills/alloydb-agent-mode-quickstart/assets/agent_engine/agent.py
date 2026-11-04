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

"""ADK data agent over a shared read-only database and optional scratch DB.

Each session can also provision a DEDICATED scratch database inside the
deployment's shared Agent Workspace service.

Shared database (read-only system of record):
  * `execute_sql_read_only` / `get_schema` — mounted DIRECT from the AlloyDB
    Agent Pool over MCP (AlloyDB IAM auth as the runtime's service account).

Per-session scratch database (only when the deployment has an Agent
Workspace): the Agent Workspace's four MCP tools, mounted as
`scratch_provision_database`, `scratch_execute_sql`, `scratch_get_schema`,
`scratch_release_database`. The Workspace owns the whole lifecycle (create,
idempotency, release, TTL reaping); every call carries this ADK session's id
as the X-Session-Id header (`utility.SessionIdHeader`), which is how the
Workspace picks this session's database. The agent keeps no database state.

Configuration comes from environment variables set by deploy_agent.py:
  AGENT_MODEL, AGENT_NAME, AGENT_WORKSPACE_URL, AGENT_CONTEXT,
  AGENT_POOL_URL / _DB_NAME / _USER / _CA_PEM.
"""

from typing import Any

from google.adk.agents import Agent
import utility  # bundled alongside this module (see deploy_agent.py)

# --- Deployment CAPABILITIES (single source of truth for tools & prompt) -----
AGENT_POOL = utility.AgentPoolDB.from_env()
AGENT_WORKSPACE_URL = utility.env_str("AGENT_WORKSPACE_URL").rstrip("/")
HAS_SCRATCH = bool(AGENT_WORKSPACE_URL)

AGENT_NAME = utility.agent_name(utility.env_str("AGENT_NAME"), "database_agent")

# execute_sql_read_only / get_schema, direct from the Agent Pool.
_POOL_TOOLSET = utility.pool_toolset(AGENT_POOL) if AGENT_POOL.url else None
# scratch_* tools on THIS session's database in the Agent Workspace.
_SCRATCH_TOOLSET = (
    utility.workspace_toolset(AGENT_WORKSPACE_URL) if HAS_SCRATCH else None
)


# --- Chart rendering: matplotlib PNG attached as an inline image Part -------
_CHART_NOTE = (
    "Put this placeholder token on its own line in your reply exactly "
    "where this chart should appear; it is replaced by the image inline. "
    "NEVER begin your reply with the chart: write a one-line lead-in "
    "BEFORE this token, then the chart, then your analysis/takeaway."
)
render_chart = utility.make_render_chart(_CHART_NOTE)

tools: list[Any] = [render_chart]
# Each MCP server tool becomes its own agent tool, described by the server's
# own schema.
if _POOL_TOOLSET is not None:
  tools.append(_POOL_TOOLSET)
if _SCRATCH_TOOLSET is not None:
  tools.append(_SCRATCH_TOOLSET)


def _intro_section() -> str:
  """Builds the opening role and capability summary for the agent."""
  parts = ["You are a data-analytics agent."]
  if AGENT_POOL.url:
    parts.append(
        "You answer questions about a shared read-only database using your"
        " tools."
    )
  if HAS_SCRATCH:
    prefix = (
        "In addition, during each session" if AGENT_POOL.url else "Each session"
    )
    parts.append(
        f"{prefix} you get your OWN private scratch database"
        " (agent_db_<uuid>) inside this deployment's dedicated Agent Workspace"
        " — reachable only through your tools, created on demand and destroyed"
        " when you're done. Other sessions can never see or touch it."
    )
  return " ".join(parts)


def _pool_section() -> str:
  """Builds prompt instructions for querying the read-only AlloyDB Agent Pool."""
  if not AGENT_POOL.url:
    return ""
  return (
      "You have read-only access to the shared AlloyDB database — the"
      " organization's system of record:\n1. Call `get_schema` FIRST to learn"
      " the tables, columns, and types.\n2. Then answer with"
      " `execute_sql_read_only` — SELECT-only; keep result sets small"
      " (GROUP BY / LIMIT); statements time out at 60s.\n3. Never pass"
      " `database`; it is supplied automatically.\nThe shared database is"
      " enforced read-only: never attempt writes."
  )


def _charts_section() -> str:
  return (
      "CHARTS: when a result is a time series or trend, chart it with kind"
      ' "line"; a ranking or single comparison, "bar"; several series across'
      ' the same categories, "grouped_bar". Chart whenever a result has 3+'
      " numeric rows and a chart communicates it better than a table; never"
      " chart a single number. Use `render_chart` for the data you computed or"
      " read. Each call returns a `placeholder` token — write that token on"
      " its own line where the chart belongs (it is replaced by the inline"
      " image), with a one-line takeaway next to it; do NOT write a markdown"
      ' image/link. If the tool returns status "error", present the numbers as'
      " a table and say the chart could not be rendered."
  )


def _scratch_flow_section() -> str:
  if not HAS_SCRATCH:
    return ""
  return (
      "Scratch-database flow (for what-if work the shared read-only database"
      " cannot do):\n1. `scratch_provision_database` first (this will take a"
      " few seconds); its returned name confirms your private database.\n2. It"
      " starts EMPTY. Use `scratch_execute_sql` to run any SQL in it — CREATE"
      " TABLE, INSERT the rows you read from the shared database, UPDATE,"
      " SELECT — and `scratch_get_schema` to see what you have built. These"
      " tools only ever touch YOUR scratch database, never the shared"
      " database. Read-only work needs none of this.\n3. When the user is"
      " done, offer to `scratch_release_database`. If a scratch tool says this"
      " session has no scratch database, it was reaped or the service was"
      " recycled — say so, re-provision, and rebuild."
  )


_INSTRUCTION = "\n\n".join(
    s.strip()
    for s in [
        _intro_section(),
        utility.context_section(
            "Use it to interpret questions, map business terms to the data,"
            " and explain results in the business's own language."
        ),
        _pool_section(),
        _charts_section(),
        _scratch_flow_section(),
        "Never claim results a query did not return; always show the numbers.",
    ]
    if s and s.strip()
)

root_agent = Agent(
    name=AGENT_NAME,
    model=utility.GlobalGemini(
        model=utility.env_str("AGENT_MODEL", "gemini-3.8-flash")
    ),
    after_model_callback=utility.charts_after_model,
    before_tool_callback=utility.bind_database(AGENT_POOL.database),
    instruction=utility.StaticInstruction(_INSTRUCTION),
    tools=tools,
)
