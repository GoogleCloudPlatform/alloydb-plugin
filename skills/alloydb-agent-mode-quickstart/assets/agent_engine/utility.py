"""Shared runtime pieces for agent.py and coordinator.py.

Bundled next to both agents by scripts/deploy_agent.py. Holds no deployment
state of its own: each agent reads its environment variables (set by
deploy_agent.py) at import time via `env_str()` / `PrimaryDB.from_env()` /
`context_section()`, so one deploy process can build both agents
without stale module state.

Contents:
  * Primary database: `PrimaryDB` (connection settings), `pool_toolset()`
    (the AlloyDB Agent Pool's `execute_sql_read_only` / `get_schema`, direct),
    `bind_database()`.
  * Agent Workspace (per-session scratch DBs): `workspace_toolset()`,
    `SessionIdHeader`.
  * Inline charts: `render_b64()`, `stash_chart()`, `charts_after_model()`.
  * Model: `GlobalGemini` (global endpoint with retries), `agent_name()`.

ADK must open MCP sessions with `server/discover` (deploy_agent.py sets
ADK_ENABLE_MCP_MODERN_PROTOCOL=1 on the runtime): the agent pool returns row
arrays as `structuredContent`, which the legacy handshake rejects.
"""

import asyncio
import base64
import dataclasses
import io
import os
import re
import ssl
import threading
from typing import Any

from google.adk.models.google_llm import Gemini
from google.adk.tools.mcp_tool import mcp_session_manager
from google.adk.tools.mcp_tool import mcp_toolset
from google.adk.tools.tool_context import ToolContext
import google.auth
import google.auth.transport.requests
from google.genai import Client
from google.genai import types
import google.oauth2.id_token
import httpx2

# =============================================================================
# Environment (set by deploy_agent.py on the Agent Engine runtime)
# =============================================================================


def env_str(name: str, default: str = "") -> str:
  return (os.environ.get(name) or "").strip() or default


def context_section(usage: str) -> str:
  """Returns the prompt block for the deployment owner's AGENT_CONTEXT, or "".

  The text is the config's optional plain-text `context`, kept verbatim (line
  breaks included). The owner's text informs the agent but never outranks the
  data: tables, columns, and numbers still come from the schema and from query
  results.

  Args:
    usage: Guidance telling this agent what to do with the context block.

  Returns:
    The formatted `<context>` prompt block, or "" when unset.
  """
  text = env_str("AGENT_CONTEXT")
  if not text:
    return ""
  return (
      "CONTEXT (written by the owner of this deployment). "
      + usage
      + " Prefer its definitions, terminology, and any queries it gives when"
      " they fit the question, but check table and column names against the"
      " schema before relying on them, and never state a number a query did"
      " not return.\n<context>\n"
      + text
      + "\n</context>"
  )


class StaticInstruction:
  """A fixed instruction, passed to ADK as a callable.

  ADK treats `{name}` in a STRING instruction as a session-state placeholder
  (and fails on unknown names); a callable instruction skips that. Owner text
  such as `context` may legitimately contain braces (SQL, JSON), so
  both agents pass their prompt through this. A class (not a closure) so it
  pickles into the Agent Engine deployment.
  """

  def __init__(self, text: str):
    self.text = text

  def __call__(self, readonly_context) -> str:
    del readonly_context  # unused
    return self.text


# =============================================================================
# Primary database (MCP)
# =============================================================================

SQL_TOOL = "execute_sql_read_only"
SCHEMA_TOOL = "get_schema"
# The Agent Workspace's tools, all keyed by the X-Session-Id header.
WORKSPACE_TOOLS = (
    "provision_database",
    "execute_sql",
    "get_schema",
    "release_database",
)
# The model sees scratch_provision_database, scratch_execute_sql, ...; the
# prefix keeps scratch get_schema apart from the primary's.
SCRATCH_PREFIX = "scratch"

_ALLOYDB_SCOPE = "https://www.googleapis.com/auth/alloydb.login"
_TIMEOUT = httpx2.Timeout(30.0, read=300.0)


@dataclasses.dataclass(frozen=True)
class PrimaryDB:
  """Connection settings for the primary's AlloyDB Agent Pool."""

  url: str = ""
  database: str = "postgres"
  user: str = ""
  ca_pem: str = ""

  @classmethod
  def from_env(cls) -> "PrimaryDB":
    """Reads PRIMARY_DB_URL / _NAME / _USER / _CA_PEM."""
    return cls(
        url=env_str("PRIMARY_DB_URL").rstrip("/"),
        database=env_str("PRIMARY_DB_NAME", "postgres"),
        user=env_str("PRIMARY_DB_USER"),
        ca_pem=env_str("PRIMARY_DB_CA_PEM"),
    )


class _BearerAuth(httpx2.Auth):
  """Sends a fresh Google bearer token (ID token for `audience`, else AlloyDB OAuth)."""

  def __init__(self, audience: str = ""):
    self._audience = audience
    self._creds = None
    self._lock = threading.Lock()

  def _token(self) -> str:
    with self._lock:
      request = google.auth.transport.requests.Request()
      if self._creds is None:
        if self._audience:
          self._creds = google.oauth2.id_token.fetch_id_token_credentials(
              self._audience, request=request
          )
        else:
          self._creds, _ = google.auth.default(scopes=[_ALLOYDB_SCOPE])
      if not self._creds.valid:
        self._creds.refresh(request)
      return self._creds.token

  def auth_flow(self, request):
    request.headers["Authorization"] = f"Bearer {self._token()}"
    yield request

  async def async_auth_flow(self, request):
    token = await asyncio.to_thread(self._token)
    request.headers["Authorization"] = f"Bearer {token}"
    yield request


class _HttpClientFactory:
  """`httpx_client_factory` for ADK: attaches the bearer token (and CA).

  A class (not a closure) so the toolset pickles into the Agent Engine
  deployment: the auth object, with its lock and credentials, is dropped from
  the pickle and rebuilt on first use in the runtime. The TLS context is built
  per client for the same reason (an `ssl.SSLContext` does not pickle).
  """

  def __init__(self, *, audience: str = "", ca_pem: str = ""):
    # audience set -> Cloud Run ID token; empty -> AlloyDB access token.
    # ca_pem set -> trust only that root CA (the AlloyDB cluster's); empty ->
    # the system trust store (Cloud Run's Google-managed certificate).
    self._audience = audience
    self._ca_pem = ca_pem
    self._auth = None

  def __getstate__(self):
    state = self.__dict__.copy()
    state["_auth"] = None
    return state

  def __setstate__(self, state):
    self.__dict__.update(state)

  def __call__(self, headers=None, timeout=None, auth=None):
    del auth  # replaced by our own; ADK has no token to give us
    if self._auth is None:
      self._auth = _BearerAuth(self._audience)
    verify = True
    if self._ca_pem:
      verify = ssl.create_default_context(cadata=self._ca_pem)
    return httpx2.AsyncClient(
        follow_redirects=True,
        verify=verify,
        headers=headers,
        timeout=timeout or _TIMEOUT,
        auth=self._auth,
    )


def pool_toolset(primary: PrimaryDB) -> mcp_toolset.McpToolset:
  """The Agent Pool's `execute_sql_read_only` / `get_schema`, direct.

  Connects over HTTPS, verifying the pool's certificate against the cluster's
  root CA (`primary.ca_pem`), and authenticates as the runtime's service
  account (AlloyDB IAM user, read-only grants). Mount with `bind_database()`
  so the model never chooses the database.

  Args:
    primary: Primary AlloyDB connection configuration.

  Returns:
    Configured MCP toolset for the Agent Pool.
  """
  return mcp_toolset.McpToolset(
      connection_params=mcp_session_manager.StreamableHTTPConnectionParams(
          url=f"{primary.url}/mcp",
          headers={"AlloyDB-User": primary.user} if primary.user else None,
          timeout=60.0,
          terminate_on_close=False,
          httpx_client_factory=_HttpClientFactory(ca_pem=primary.ca_pem),
      ),
      tool_filter=[SQL_TOOL, SCHEMA_TOOL],
  )


class SessionIdHeader:
  """`header_provider` sending the ADK session id as X-Session-Id.

  The Agent Workspace keys each session's scratch database by this header, so
  the agent holds no database state. Set by code on every MCP call; the model
  cannot see or change it. A class (not a closure) so it pickles into the
  Agent Engine deployment.
  """

  def __call__(self, readonly_context) -> dict[str, str]:
    return {"X-Session-Id": readonly_context.session.id}


def workspace_toolset(url: str) -> mcp_toolset.McpToolset:
  """Mounts the Agent Workspace MCP tools (/mcp, Cloud Run IAM).

  Exposes scratch_provision_database, scratch_execute_sql, scratch_get_schema,
  and scratch_release_database, each routed to this session's database by
  X-Session-Id.

  Args:
    url: Base URL of the Agent Workspace Cloud Run service.

  Returns:
    Configured MCP toolset for the Agent Workspace.
  """
  return mcp_toolset.McpToolset(
      connection_params=mcp_session_manager.StreamableHTTPConnectionParams(
          url=f"{url}/mcp",
          timeout=60.0,
          terminate_on_close=False,
          httpx_client_factory=_HttpClientFactory(audience=url),
      ),
      tool_filter=list(WORKSPACE_TOOLS),
      header_provider=SessionIdHeader(),
      tool_name_prefix=SCRATCH_PREFIX,
  )


def bind_database(database: str):
  """before_tool_callback forcing `database` on the pool's SQL/schema tools."""

  def _bind(tool, args, tool_context):
    del tool_context  # unused
    if tool.name in (SQL_TOOL, SCHEMA_TOOL):
      args["database"] = database
    return None

  return _bind


# =============================================================================
# Inline charts: matplotlib PNG -> base64 -> inline image Part in the reply
# =============================================================================

KINDS = ("line", "bar", "grouped_bar")
MAX_POINTS = 400
K_CHARTS = "pending_charts"
_PALETTE = ["#1a73e8", "#e8710a", "#188038", "#9334e6", "#d93025", "#12849c"]


def validate_spec(kind, title, x, series) -> str | None:
  """Returns an error message for an invalid chart spec, else None."""
  if kind not in KINDS:
    return f"unknown kind {kind!r} (use one of {KINDS})"
  if not title or not isinstance(title, str):
    return "title required"
  if not isinstance(x, list) or len(x) < 2:
    return "x must be a list of at least 2 labels"
  if len(x) > MAX_POINTS:
    return f"too many points ({len(x)} > {MAX_POINTS}) — aggregate first"
  if not isinstance(series, dict) or not series:
    return "series must be a non-empty dict of name -> list of numbers"
  for name, vals in series.items():
    if not isinstance(vals, list) or len(vals) != len(x):
      return (
          f"series {name!r} has {len(vals) if isinstance(vals, list) else '?'} "
          f"values but x has {len(x)} labels"
      )
    try:
      [float(v) for v in vals if v is not None]
    except (TypeError, ValueError):
      return f"series {name!r} contains non-numeric values"
  if kind == "bar" and len(series) != 1:
    return "kind 'bar' takes exactly one series (use grouped_bar for more)"
  return None


def render_png(kind, title, x, series, caption="") -> bytes:
  """Returns PNG bytes for a validated spec.

  matplotlib is imported lazily so local pickling environments don't need it;
  the deployed runtime gets it via the deploy script's requirements list.

  Args:
    kind: Chart type ('line', 'bar', or 'grouped_bar').
    title: Chart title text.
    x: List of x-axis labels.
    series: Mapping of series name to list of numeric values.
    caption: Optional footnote caption text.

  Returns:
    Rendered PNG image bytes.
  """
  import matplotlib  # pylint: disable=g-import-not-at-top

  matplotlib.use("Agg")
  import matplotlib.pyplot as plt  # pylint: disable=g-import-not-at-top

  # dpi kept modest (≈800x450 PNG): a lighter image transfers/decodes faster,
  # which reduces the lag before the chart renders inline in the chat client.
  fig, ax = plt.subplots(figsize=(8.0, 4.5), dpi=100)
  n = len(x)
  if kind == "line":
    for i, (name, vals) in enumerate(series.items()):
      vals = [None if v is None else float(v) for v in vals]
      ax.plot(
          range(n),
          vals,
          marker="o",
          markersize=3.5,
          linewidth=1.8,
          label=name,
          color=_PALETTE[i % len(_PALETTE)],
      )
  else:
    names = list(series)
    width = 0.8 / len(names)
    for i, name in enumerate(names):
      vals = [0 if v is None else float(v) for v in series[name]]
      offs = [j + (i - (len(names) - 1) / 2) * width for j in range(n)]
      ax.bar(
          offs,
          vals,
          width=width * 0.92,
          label=name,
          color=_PALETTE[i % len(_PALETTE)],
      )
  ax.set_xticks(range(n))
  rotate = 30 if max(len(str(v)) for v in x) > 6 or n > 8 else 0
  ax.set_xticklabels(
      [str(v) for v in x],
      rotation=rotate,
      ha="right" if rotate else "center",
      fontsize=8,
  )
  ax.set_title(title, fontsize=12, loc="left", pad=10)
  ax.grid(axis="y", linewidth=0.4, alpha=0.4)
  for side in ("top", "right"):
    ax.spines[side].set_visible(False)
  ax.tick_params(labelsize=8)
  if len(series) > 1:
    ax.legend(fontsize=8, frameon=False)
  if caption:
    fig.text(0.01, 0.005, caption, fontsize=7.5, color="#5f6368")
  fig.tight_layout(rect=(0, 0.03 if caption else 0, 1, 1))
  buf = io.BytesIO()
  fig.savefig(buf, format="png")
  plt.close(fig)
  return buf.getvalue()


def render_b64(kind, title, x, series, caption, drilldowns) -> dict[str, Any]:
  """Validate + render a chart; the PNG comes back base64 for inline display.

  No upload / URL — the caller stashes the base64 (`stash_chart`) and
  `charts_after_model` attaches it as an inline image Part.

  Args:
    kind: Chart type ('line', 'bar', or 'grouped_bar').
    title: Chart title text.
    x: List of x-axis labels.
    series: Mapping of series name to list of numeric values.
    caption: Optional footnote caption text.
    drilldowns: Optional list of drilldown follow-up labels.

  Returns:
    Dictionary with status, metadata, and base64-encoded PNG (or error).
  """
  err = validate_spec(kind, title, x, series)
  if err:
    return {"status": "error", "error": err}
  try:
    png = render_png(kind, title, x, series, caption or "")
  except Exception as e:  # pylint: disable=broad-exception-caught
    return {"status": "error", "error": f"{type(e).__name__}: {e}"}
  return {
      "status": "rendered",
      "kind": kind,
      "title": title,
      "caption": caption or "",
      "png_b64": base64.b64encode(png).decode(),
      "points": len(x),
      "series": list(series),
      "drilldowns": drilldowns or [],
  }


def stash_chart(
    tool_context: ToolContext, result: dict[str, Any], note: str
) -> dict[str, Any]:
  """Moves a rendered PNG into session state; the model gets a placeholder.

  `note` tells the model where to put the placeholder token in its reply.

  Args:
    tool_context: ADK tool execution context.
    result: Chart result dictionary from `render_b64`.
    note: Instruction string telling the model how to place the chart token.

  Returns:
    Updated result dictionary with `png_b64` replaced by a placeholder token.
  """
  if result.get("status") != "rendered":
    return result
  png_b64 = result.pop("png_b64", None)
  if png_b64:
    pending = list(tool_context.state.get(K_CHARTS) or [])
    token = f"[[chart:{len(pending) + 1}]]"
    pending.append({"token": token, "png_b64": png_b64})
    tool_context.state[K_CHARTS] = pending
    result["placeholder"] = token
    result["note"] = note
  return result


def charts_after_model(callback_context, llm_response):
  """after_model_callback: swaps `[[chart:N]]` tokens for inline PNG parts.

  Streamed partial chunks pass through untouched: the token may not have
  arrived yet, and only the final response is saved to the session. Only
  visible text is split; thought parts and non-text parts are kept as they
  are, and a split part's `thought_signature` stays on the text after its
  last token.
  """
  if getattr(llm_response, "partial", False):
    return None
  pending = callback_context.state.get(K_CHARTS) or []
  if not pending:
    return None
  content = getattr(llm_response, "content", None)
  parts = list(getattr(content, "parts", None) or [])
  if any(getattr(p, "function_call", None) for p in parts):
    return None

  def _img(c):
    return types.Part.from_bytes(
        data=base64.b64decode(c["png_b64"]), mime_type="image/png"
    )

  by_idx = {i + 1: c for i, c in enumerate(pending)}
  new_parts, used = [], set()
  for p in parts:
    if p.thought or not p.text:
      new_parts.append(p)
      continue
    last = 0
    for m in re.finditer(r"\[\[\s*chart:\s*(\d+)\s*\]\]", p.text):
      c = by_idx.get(int(m.group(1)))
      if not c:
        continue
      before = p.text[last : m.start()]
      if before.strip():
        new_parts.append(types.Part(text=before))
      new_parts.append(_img(c))
      used.add(int(m.group(1)))
      last = m.end()
    tail = p.text[last:]
    if not last:  # no token in this part
      new_parts.append(p)
    elif tail.strip() or p.thought_signature:
      new_parts.append(p.model_copy(update={"text": tail}))
  for i, c in by_idx.items():
    if i not in used:
      new_parts.append(_img(c))
  callback_context.state[K_CHARTS] = []
  return llm_response.model_copy(
      update={"content": types.Content(role="model", parts=new_parts)}
  )


# =============================================================================
# Model
# =============================================================================

_RETRY_OPTIONS = types.HttpRetryOptions(
    attempts=8, initial_delay=1.0, max_delay=60.0, exp_base=2.0, jitter=1.0
)


class GlobalGemini(Gemini):
  """Gemini on the global Vertex endpoint, with exponential-backoff retries."""

  @property
  def api_client(self) -> Client:
    return Client(
        vertexai=True,
        location="global",
        http_options=types.HttpOptions(retry_options=_RETRY_OPTIONS),
    )


def agent_name(raw: Any, default: str) -> str:
  """A valid ADK agent name from a configured display-ish name."""
  return re.sub(r"\W", "_", str(raw or "")) or default
