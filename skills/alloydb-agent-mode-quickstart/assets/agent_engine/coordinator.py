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

"""Swarm COORDINATOR agent for parallel investigations over a target engine.

Instantiates an investigation swarm against a TARGET deployment (another Agent
Engine resource provisioned by this pipeline), designed to be registered into
Gemini Enterprise.

Configuration comes from environment variables set by deploy_agent.py:
  AGENT_MODEL, AGENT_NAME, TARGET_ENGINE, TARGET_PROJECT, TARGET_LOCATION,
  TARGET_DISPLAY, AGENT_CONTEXT, SWARM_WORK_PREAMBLE,
  SWARM_MAX, SWARM_STAGGER_SECONDS, PRIMARY_DB_URL / _NAME / _USER / _CA_PEM.
"""

import re
import threading
import time
from typing import Any

from google.adk.agents import Agent
from google.adk.tools.tool_context import ToolContext
import google.auth
import google.auth.transport.requests
import requests
import utility  # bundled alongside this module (see deploy_agent.py)
import vertexai
from vertexai import agent_engines

PRIMARY = utility.PrimaryDB.from_env()
TARGET_ENGINE = utility.env_str("TARGET_ENGINE")
TARGET_PROJECT = utility.env_str("TARGET_PROJECT")
TARGET_LOCATION = utility.env_str("TARGET_LOCATION")
TARGET_DISPLAY = utility.env_str("TARGET_DISPLAY", "the target deployment")
SWARM_MAX = int(utility.env_str("SWARM_MAX", "15"))
STAGGER_S = float(utility.env_str("SWARM_STAGGER_SECONDS", "8"))

if not (TARGET_ENGINE and TARGET_PROJECT and TARGET_LOCATION):
  raise ValueError(
      "TARGET_ENGINE, TARGET_PROJECT and TARGET_LOCATION must be set"
  )
_API = f"https://{TARGET_LOCATION}-aiplatform.googleapis.com/v1beta1"

K_RUNS = "swarm_runs"

_engine_lock = threading.Lock()
_engine = None


def _target_engine():
  """The Vertex SDK client for the TARGET deployment (lazy, cached)."""
  global _engine
  with _engine_lock:
    if _engine is None:
      vertexai.init(project=TARGET_PROJECT, location=TARGET_LOCATION)
      _engine = agent_engines.get(TARGET_ENGINE)
    return _engine


def _authed_get(
    url: str, params: dict[str, Any] | None = None
) -> dict[str, Any]:
  """GET against the Agent Engine Sessions REST API as this agent's SA."""
  creds, _ = google.auth.default(
      scopes=["https://www.googleapis.com/auth/cloud-platform"]
  )
  creds.refresh(google.auth.transport.requests.Request())
  r = requests.get(
      url,
      params=params or {},
      headers={"Authorization": f"Bearer {creds.token}"},
      timeout=60,
  )
  r.raise_for_status()
  return r.json()


def _child_report(session_id: str) -> tuple[str | None, bool]:
  """Return (last_model_text, turn_complete) for a child session."""
  url = f"{_API}/{TARGET_ENGINE}/sessions/{session_id}/events"
  events, page = [], None
  while True:
    d = _authed_get(
        url, {"pageSize": 100, **({"pageToken": page} if page else {})}
    )
    events += d.get("sessionEvents", d.get("events", []))
    page = d.get("nextPageToken")
    if not page:
      break

  def _author(ev):
    c = ev.get("content") or {}
    return (ev.get("author") or c.get("role") or "").lower()

  def _parts(ev):
    return (ev.get("content") or {}).get("parts") or []

  last_text = None
  for ev in reversed(events):
    if _author(ev) == "user":
      continue
    text = "".join(
        p.get("text", "") for p in _parts(ev) if isinstance(p, dict)
    ).strip()
    if text:
      last_text = text
      break

  turn_complete = False
  for ev in reversed(events):
    parts = _parts(ev)
    if not parts:
      continue
    if _author(ev) == "user":
      break
    has_call = any(
        isinstance(p, dict)
        and (
            "functionCall" in p
            or "function_call" in p
            or "functionResponse" in p
            or "function_response" in p
        )
        for p in parts
    )
    text = "".join(
        p.get("text", "") for p in parts if isinstance(p, dict)
    ).strip()
    if has_call:
      break
    if text:
      turn_complete = True
      break
  return last_text, turn_complete


def _fire_child(
    session_id: str, user_id: str, brief: str, agent_id: str
) -> None:
  """Send one brief to a child session (daemon thread, stream discarded)."""
  try:
    for _ in _target_engine().stream_query(
        user_id=user_id, session_id=session_id, message=brief
    ):
      pass
    print(
        f"[swarm] {agent_id} stream complete (session {session_id})", flush=True
    )
  except Exception as exc:  # pylint: disable=broad-exception-caught
    print(f"[swarm] {agent_id} stream error: {exc!r}", flush=True)


def _launch_async(children: list[dict[str, Any]]) -> None:
  """Fire all child queries with a stagger between launches."""

  def _run():
    for i, c in enumerate(children):
      if i:
        time.sleep(STAGGER_S)
      threading.Thread(
          target=_fire_child,
          args=(c["session_id"], c["user_id"], c["brief"], c["agent_id"]),
          daemon=True,
      ).start()

  threading.Thread(target=_run, daemon=True).start()


# --------------------------------------------------------------------------
# FunctionTools
# --------------------------------------------------------------------------
def launch_swarm(  # pylint: disable=g-bare-generic
    briefs: list[dict], tool_context: ToolContext
) -> dict[str, Any]:
  """Launches an investigation swarm on the target deployment in parallel.

  Args:
    briefs: List of `{"agent_id": "s01", "brief": "<full mission text>"}` —
      author every brief yourself first (unique missions; each must instruct the
      child to END with a report titled "AGENT <agent_id> FINDINGS").
    tool_context: ADK tool context (supplied automatically).

  Returns:
    The run manifest immediately; the children keep working server-side. Follow
    up later with `swarm_status` and `collect_findings` — never claim results
    at launch time.
  """
  if not briefs:
    return {"error": "no briefs given"}
  if len(briefs) > SWARM_MAX:
    return {"error": f"{len(briefs)} briefs exceeds SWARM_MAX={SWARM_MAX}"}
  run_id = time.strftime("swarm-%Y%m%dT%H%M%SZ", time.gmtime())
  engine = _target_engine()
  children = []
  for b in briefs:
    agent_id = (
        re.sub(r"\W", "", str(b.get("agent_id", "")))[:8]
        or f"s{len(children)+1:02d}"
    )
    user_id = f"{run_id}-{agent_id}"
    s = engine.create_session(user_id=user_id)
    session_id = s["id"] if isinstance(s, dict) else s.id
    children.append({
        "agent_id": agent_id,
        "user_id": user_id,
        "session_id": session_id,
        "brief": str(b.get("brief", "")),
    })
  _launch_async(children)
  runs = dict(tool_context.state.get(K_RUNS) or {})
  runs[run_id] = {
      "children": children,
      "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
  }
  tool_context.state[K_RUNS] = runs
  return {
      "run_id": run_id,
      "launched": [
          {"agent_id": c["agent_id"], "session_id": c["session_id"]}
          for c in children
      ],
      "note": (
          f"{len(children)} child sessions launched ({STAGGER_S:.0f}s stagger)."
          " A run typically takes 5-15 minutes; check back with swarm_status."
      ),
  }


def swarm_status(run_id: str, tool_context: ToolContext) -> dict[str, Any]:
  """Checks the progress of a running swarm investigation.

  Args:
    run_id: Swarm run identifier returned by `launch_swarm`.
    tool_context: ADK tool context (supplied automatically).

  Returns:
    A status summary showing which child agents have delivered their findings,
    which are still working, and which are candidates for `relaunch_agents`.
  """
  run = (tool_context.state.get(K_RUNS) or {}).get(run_id)
  if not run:
    return {
        "error": f"unknown run_id {run_id}",
        "known_runs": list((tool_context.state.get(K_RUNS) or {}).keys()),
    }
  status = []
  for c in run["children"]:
    try:
      text, complete = _child_report(c["session_id"])
    except Exception as exc:  # pylint: disable=broad-exception-caught
      status.append({"agent_id": c["agent_id"], "state": f"poll error: {exc}"})
      continue
    has_marker = (
        text is not None
        and f"AGENT {c['agent_id']}".upper() in text.upper()
        and "FINDINGS" in text.upper()
    )
    if has_marker:
      state = "done"
    elif text and complete:
      state = "done (no title marker)"
    elif text:
      state = "working (partial output)"
    else:
      state = "no output yet"
    status.append({"agent_id": c["agent_id"], "state": state})
  done = sum(1 for s in status if s["state"].startswith("done"))
  return {
      "run_id": run_id,
      "done": done,
      "total": len(status),
      "agents": status,
  }


def relaunch_agents(
    run_id: str, agent_ids: list[str], tool_context: ToolContext
) -> dict[str, Any]:
  """Re-fire specific child agents' briefs (same sessions, sequentially)."""
  run = (tool_context.state.get(K_RUNS) or {}).get(run_id)
  if not run:
    return {"error": f"unknown run_id {run_id}"}
  picked = [c for c in run["children"] if c["agent_id"] in set(agent_ids)]
  if not picked:
    return {"error": f"no children match {agent_ids}"}
  _launch_async(picked)
  return {
      "run_id": run_id,
      "relaunched": [c["agent_id"] for c in picked],
      "note": (
          "sequentially staggered; check swarm_status again in a few minutes"
      ),
  }


def collect_findings(run_id: str, tool_context: ToolContext) -> dict[str, Any]:
  """Fetch every child agent's final findings report (full text) for the run."""
  run = (tool_context.state.get(K_RUNS) or {}).get(run_id)
  if not run:
    return {"error": f"unknown run_id {run_id}"}
  findings, missing = [], []
  for c in run["children"]:
    try:
      text, _ = _child_report(c["session_id"])
    except Exception as exc:  # pylint: disable=broad-exception-caught
      missing.append(
          {"agent_id": c["agent_id"], "reason": f"poll error: {exc}"}
      )
      continue
    if text:
      findings.append({
          "agent_id": c["agent_id"],
          "session_id": c["session_id"],
          "report": text,
      })
    else:
      missing.append({"agent_id": c["agent_id"], "reason": "no output"})
  return {
      "run_id": run_id,
      "findings": findings,
      "missing": missing,
      "session_map": {c["agent_id"]: c["session_id"] for c in run["children"]},
  }


_CONTEXT = utility.context_section(
    "Use it to scope questions, pick the swarm's angles, and phrase findings"
    " in the business's own terms. Child agents get the main agent's own"
    " context, so put in a brief only the parts its mission needs."
)
_WORK_PREAMBLE = utility.env_str("SWARM_WORK_PREAMBLE") or (
    "Work autonomously (no clarifying questions). Learn the primary's schema,"
    " answer with read-only SQL; never fabricate results."
)

_COORD_NAME = utility.agent_name(
    utility.env_str("AGENT_NAME"), "swarm_coordinator"
)

_CHART_NOTE = (
    "Put this placeholder token on its own line where the chart belongs; it"
    " is replaced by the inline image (do NOT write a markdown image). For"
    " a single-chart answer, order the reply: (1) short summary of"
    " findings, (2) analysis, (3) this token (the chart), (4) next steps —"
    " so the chart is near the end, just before next steps, never at the"
    " top."
)


async def render_chart(  # pylint: disable=g-bare-generic
    kind: str,
    title: str,
    x: list,
    series: dict,
    caption: str = "",
    drilldowns: list | None = None,
    tool_context: ToolContext = None,
) -> dict[str, Any]:
  """Renders a chart of numbers collected from the swarm as an inline image.

  Args:
    kind: Chart type: "line" (trends over time), "bar" (one ranked series, e.g.
      revenue lost per root cause), or "grouped_bar" (2+ series across the same
      categories, e.g. baseline vs window fill).
    title: Chart title.
    x: Axis labels.
    series: Mapping of `{"name": [numbers aligned with x]}`.
    caption: Optional caption rendered below the chart.
    drilldowns: Optional list of follow-up questions worth offering.
    tool_context: ADK tool context (supplied automatically).

  Returns:
    A dict containing a `placeholder` token — put it on its own line in your
    report where the chart should appear (it becomes the inline image), with a
    one-line takeaway near it; do NOT write a markdown image/link. On status
    "error", show a table.
  """
  return utility.stash_chart(
      tool_context,
      utility.render_b64(kind, title, x, series, caption, drilldowns),
      _CHART_NOTE,
  )


# The Agent Pool's tools (execute_sql_read_only, get_schema), mounted on the
# coordinator for single-question answers, direct to the pool (AlloyDB IAM).
_POOL_TOOLSET = utility.pool_toolset(PRIMARY) if PRIMARY.url else None


_CHARTS_NOTE = """
Chart placement: NEVER begin a reply with a chart. For a SINGLE-chart answer
(a direct question answered with one plot), keep it SHORT and in this order:
(1) a one- or two-sentence takeaway with the key numbers, (2) at most a
sentence of supporting context, (3) the chart's `placeholder` token on its own
line, then (4) a one-line next step / offer. The chart comes AFTER the short
takeaway and just BEFORE the next step — never at the top, and never padded into
a multi-section report. For a multi-chart REPORT (swarm synthesis), place each
chart's token inline where that chart is referenced (not all bunched at the end).
When synthesizing a report, chart the headline numbers with `render_chart`
(bar: revenue lost per root cause; grouped_bar: baseline-vs-window fill by
slice; line: monthly trends the agents reported). Each call returns a
`placeholder` token — write that token on its own line at the point in the
report where the chart belongs (it is replaced by the inline image), with a
one-line takeaway next to it; do NOT write a markdown image/link. Chart only
numbers taken verbatim from agents' findings."""

_DIRECT_PROMPT = """
YOU CAN ALSO ANSWER SINGLE QUESTIONS DIRECTLY (no swarm needed). You have
read-only access to the same shared primary database the swarm agents use,
straight from its AlloyDB Agent Pool: call `get_schema` to learn its
tables/columns, then answer with `execute_sql_read_only` (SELECT-only; keep
result sets small with GROUP BY / LIMIT). Never pass `database`; it is
supplied automatically.
CHOOSE THE RIGHT MODE:
- A specific, answerable question ("what was fill rate by month?", "which
  suppliers slipped?") -> answer it NOW with a query, show the numbers, and
  offer a swarm for the deeper why.
- An open-ended, multi-hypothesis investigation ("why did fill rate drop?",
  "investigate X with N agents") -> launch a swarm.
Never state a number a tool did not return.

KEEP DIRECT ANSWERS SHORT — a direct question gets a concise answer, NOT a
report. Lead with the key numbers in 1-3 sentences (a compact table or a single
chart only when it genuinely helps), then ONE short line offering a swarm for
the deeper "why". Do NOT write an executive summary, multi-section analysis, or
ranked remediations for a direct question — that depth is reserved for swarm
synthesis.

NEVER EXPOSE INTERNALS TO THE USER: do not name tools, SQL, tables, columns
or run mechanics in your replies (no "execute_sql_read_only", no "I ran a
query"). Speak in business terms — "unit fill rate by month", "supplier
on-time delivery". Same when you synthesize swarm findings: translate the
agents' tool/query references into plain business language."""

_DIRECT_NOTE = _DIRECT_PROMPT if PRIMARY.url else ""

root_agent = Agent(
    name=_COORD_NAME,
    model=utility.GlobalGemini(
        model=utility.env_str("AGENT_MODEL", "gemini-3.8-flash")
    ),
    after_model_callback=utility.charts_after_model,
    before_tool_callback=utility.bind_database(PRIMARY.database),
    instruction=utility.StaticInstruction(
        f"""You are the SWARM COORDINATOR for {TARGET_DISPLAY}. Your
main job is to size a swarm of parallel investigation agents (child
sessions of the deployed agent), author their missions, launch them, track
them, and synthesize their findings.{" You can additionally answer single questions directly off the primary database — see below." if PRIMARY.url else " You never analyze data yourself."}

{_CONTEXT or "No context was provided: ask the user what to investigate, and learn the domain from the schema."}

WHEN THE USER ASKS FOR AN INVESTIGATION:
1. Pick N (user's number, else default 10, hard cap {SWARM_MAX}).
2. Author N UNIQUE briefs. Every brief = (a) this work preamble, verbatim:
---
{_WORK_PREAMBLE}
---
   (b) "YOUR MISSION: <unique mission>" — one distinct angle per agent,
   grounded in the domain and the primary database's schema (plus
   cross-cutting roles like dollar-weighted triage and a devil's advocate
   who tries to REFUTE the leading hypotheses); (c) the instruction to end
   with a report titled "AGENT <agent_id> FINDINGS" with sections: what I
   investigated (queries used), findings with numbers, root-cause
   hypotheses with confidence, proposed remediations with expected impact.
3. Call `launch_swarm` with all briefs. Report the run_id and roster; tell
   the user a run takes 5-15 minutes and to ask for status or the report.
   NEVER wait in-turn for the swarm and NEVER invent results at launch.

ON LATER TURNS:
- "status" -> `swarm_status(run_id)`; summarize. States starting with
  "done" (including "done (no title marker)") ARE complete — an agent that
  finished its analysis without the exact title still counts as done; do
  NOT relaunch it. Only offer `relaunch_agents` for agents stuck at "no
  output yet" well after launch.
- "report" -> once the `done` count covers all (or enough) agents, call
  `collect_findings(run_id)`, then synthesize: executive
  summary; each distinct root cause with its strongest numbers and which
  agents corroborate it; contradictions kept visible; remediations ranked
  by expected impact with rival proposals side by side; agents that
  returned nothing listed as missing (never fabricated). Offer the
  per-agent reports on request — they are in the tool result.
If the user references "the run" without an id, use the most recent run in
your state.
{_DIRECT_NOTE}
{_CHARTS_NOTE}"""
    ),
    tools=[
        launch_swarm,
        swarm_status,
        relaunch_agents,
        collect_findings,
        render_chart,
    ]
    + ([_POOL_TOOLSET] if _POOL_TOOLSET is not None else []),
)
