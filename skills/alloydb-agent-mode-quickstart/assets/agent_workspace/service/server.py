#!/usr/bin/env python3
"""Agent Workspace ROUTER for per-session scratch PostgreSQL databases.

One Cloud Run service per deployment runs [this router + PostgreSQL
sidecar], min=max=1. Each agent session gets its own database
(agent_db_<uuid>) and its own NOSUPERUSER role inside the shared Postgres.
Nothing here creates or deletes cloud resources, and nothing here touches the
primary database: agents query the primary directly through the AlloyDB Agent
Pool.

One surface, one MCP endpoint (/mcp, agent SA via Cloud Run IAM), four tools,
all keyed by the X-Session-Id header (the caller's agent session id, set by
the agent's code, never by the model):
  provision_database()   create the session's database (idempotent)
  release_database()     drop the session's database
  execute_sql(sql)       run SQL in the session's database
  get_schema(table="")   describe the session's database

The whole lifecycle lives here: the agent keeps no database state. Every tool
finds the caller's session by X-Session-Id (isolation layer 1) and SQL runs as
that session's own role, which can CONNECT to its own database only
(isolation layer 2, proven at startup). Callers are trusted agent runtimes:
ingress is internal-only and run.invoker is granted to agent SAs only.

Only PROVISIONER_PASSWORD is injected via Secret Manager env.
"""

import asyncio
import dataclasses
import json
import os
import secrets
import sys
import threading
import time
from typing import Any
import uuid

from mcp.server.mcpserver import Context
from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
import psycopg
from psycopg import sql
from psycopg.rows import dict_row

PG_HOST = "127.0.0.1"
PG_PORT = 5432
PROVISIONER = "provisioner"
PROVISIONER_PASSWORD = os.environ["PROVISIONER_PASSWORD"]

DEFAULT_TTL_MIN = 120
MAX_ACTIVE_DBS = 20
SESSION_CONN_LIMIT = 10
SESSION_STMT_TIMEOUT = "120s"
MAX_ROWS = 1000
PROVISION_WAIT_S = 30  # max wait for another call's in-flight provisioning

SESSION_HEADER = "x-session-id"

# Transport options (stateless HTTP, no DNS-rebinding check) are passed to
# streamable_http_app() at the bottom of this file in mcp 2.x.
mcp = MCPServer("alloydb-agent-workspace")


@dataclasses.dataclass
class Session:
  session_id: str
  database: str
  role: str
  password: str
  created_at: int
  ready: bool = False  # False while CREATE DATABASE is still running
  # Set once provisioning finishes, whether it succeeded or failed.
  done: threading.Event = dataclasses.field(default_factory=threading.Event)


# X-Session-Id -> that session's database.
_sessions: dict[str, Session] = {}
_LOCK = threading.Lock()


# --------------------------------------------------------------------------
# Postgres admin helpers (run as the NOSUPERUSER provisioner role)
# --------------------------------------------------------------------------
def _admin_conn(dbname: str = "postgres") -> psycopg.Connection:
  return psycopg.connect(
      host=PG_HOST,
      port=PG_PORT,
      dbname=dbname,
      user=PROVISIONER,
      password=PROVISIONER_PASSWORD,
      autocommit=True,
      connect_timeout=10,
  )


def _create_db_and_role(database: str, role: str, password: str) -> None:
  """Create a per-session Postgres role and database with strict CONNECT grants."""
  with _admin_conn() as conn:
    conn.execute(
        sql.SQL(
            "CREATE ROLE {} LOGIN PASSWORD {} NOSUPERUSER NOCREATEDB "
            "NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT {}"
        ).format(
            sql.Identifier(role),
            sql.Literal(password),
            sql.Literal(SESSION_CONN_LIMIT),
        )
    )
    conn.execute(
        sql.SQL("ALTER ROLE {} SET statement_timeout = {}").format(
            sql.Identifier(role), sql.Literal(SESSION_STMT_TIMEOUT)
        )
    )
    conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(database)))
    conn.execute(
        sql.SQL("REVOKE CONNECT ON DATABASE {} FROM PUBLIC").format(
            sql.Identifier(database)
        )
    )
    conn.execute(
        sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
            sql.Identifier(database), sql.Identifier(role)
        )
    )
  with _admin_conn(database) as conn:
    conn.execute(
        sql.SQL("GRANT USAGE, CREATE ON SCHEMA public TO {}").format(
            sql.Identifier(role)
        )
    )


def _drop_db_and_role(database: str, role: str) -> None:
  with _admin_conn() as conn:
    conn.execute(
        sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(
            sql.Identifier(database)
        )
    )
    conn.execute(sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(role)))


# --------------------------------------------------------------------------
# Session lookup — THE cross-session isolation check (layer 1)
# --------------------------------------------------------------------------
def _session_id(ctx: Context) -> str:
  return ((ctx.headers or {}).get(SESSION_HEADER) or "").strip()


def _session_from_headers(ctx: Context) -> Session | None:
  """The caller's READY session, by X-Session-Id; None if it has none."""
  session = _sessions.get(_session_id(ctx))
  return session if session is not None and session.ready else None


def _wait_for_provisioning(session: Session) -> None:
  """Waits until no call is still creating the session's database."""
  if not session.done.wait(PROVISION_WAIT_S):
    raise TimeoutError(
        "this session's scratch database is still being created; try again"
        " in a few seconds"
    )


def _release(session: Session) -> None:
  # Never DROP while a provision call is still creating the database: its
  # CREATE would land after the DROP and leak the database and role.
  _wait_for_provisioning(session)
  _drop_db_and_role(session.database, session.role)
  with _LOCK:
    if _sessions.get(session.session_id) is session:
      del _sessions[session.session_id]


# --------------------------------------------------------------------------
# Session-database access — always AS the session's own role (layer 2)
# --------------------------------------------------------------------------
def _session_conn(session: Session) -> psycopg.Connection:
  return psycopg.connect(
      host=PG_HOST,
      port=PG_PORT,
      dbname=session.database,
      user=session.role,
      password=session.password,
      autocommit=True,
      connect_timeout=10,
      row_factory=dict_row,
  )


def _json_safe(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
  """Dates, decimals, UUIDs, ... -> JSON-native values."""
  return json.loads(json.dumps(rows, default=str))


def _run_sql(session: Session, statement: str) -> dict[str, Any]:
  with _session_conn(session) as conn, conn.cursor() as cur:
    cur.execute(statement)
    if cur.description is None:
      return {"status": cur.statusmessage, "rowcount": cur.rowcount}
    rows = cur.fetchmany(MAX_ROWS + 1)
    out: dict[str, Any] = {"rows": _json_safe(rows[:MAX_ROWS])}
    if len(rows) > MAX_ROWS:
      out["truncated"] = f"only the first {MAX_ROWS} rows are returned"
    return out


def _schema(session: Session, table: str) -> dict[str, Any]:
  query = (
      "SELECT table_name AS table, column_name AS column, data_type AS type,"
      " is_nullable = 'YES' AS nullable FROM information_schema.columns"
      " WHERE table_schema = 'public'"
      + (" AND table_name = %s" if table else "")
      + " ORDER BY table_name, ordinal_position"
  )
  with _session_conn(session) as conn, conn.cursor() as cur:
    cur.execute(query, (table,) if table else None)
    return {"rows": _json_safe(cur.fetchall())}


_NO_HEADER = {
    "error": "missing X-Session-Id header (set by the agent runtime)"
}
_NO_SESSION = {
    "error": (
        "this session has no scratch database: provision one first."
        " If you had one before, it was released, reaped after its TTL, or the"
        " service was recycled; its data is gone and must be rebuilt."
    )
}


def _provision(session_id: str) -> dict[str, Any]:
  """Provisions or returns the per-session PostgreSQL database and role."""
  with _LOCK:
    existing = _sessions.get(session_id)
    if existing is None:
      if len(_sessions) >= MAX_ACTIVE_DBS:
        return {
            "error": (
                f"capacity: {MAX_ACTIVE_DBS} active databases "
                "already provisioned; try again after some are "
                "released or reaped"
            )
        }
      instance_id = uuid.uuid4().hex
      session = Session(
          session_id=session_id,
          database=f"agent_db_{instance_id}",
          role=f"agent_{instance_id[:12]}",
          password=secrets.token_urlsafe(24),
          created_at=int(time.time()),
      )
      _sessions[session_id] = session  # reserve before the slow CREATE
  if existing is not None:
    # A concurrent or retried call may still be creating it: wait for that
    # call, so this one never returns a database that is not usable yet.
    _wait_for_provisioning(existing)
    if not existing.ready:
      return {"error": "provisioning failed in a concurrent call; try again"}
    return {"status": "already_provisioned", "database": existing.database}
  try:
    _create_db_and_role(session.database, session.role, session.password)
    session.ready = True
  except Exception:
    with _LOCK:
      _sessions.pop(session_id, None)
    try:
      _drop_db_and_role(session.database, session.role)
    except Exception as exc:  # pylint: disable=broad-exception-caught
      # Log it and re-raise the original error below, not this one.
      print(
          f"[agent-workspace] cleanup failed for {session.database}: {exc!r}",
          flush=True,
      )
    raise
  finally:
    session.done.set()
  print(
      f"[agent-workspace] provisioned {session.database} "
      f"({len(_sessions)}/{MAX_ACTIVE_DBS} active)",
      flush=True,
  )
  return {"status": "provisioned", "database": session.database}


# --------------------------------------------------------------------------
# MCP tools (the whole agent-facing surface; docstrings are what the model
# reads)
# --------------------------------------------------------------------------
@mcp.tool()
async def provision_database(ctx: Context) -> dict[str, Any]:
  """Creates your OWN private, empty scratch PostgreSQL database for this session.

  Call once, before any scratch work; takes a few seconds. Safe to call again:
  it returns the existing database.
  """
  session_id = _session_id(ctx)
  if not session_id:
    return _NO_HEADER
  try:
    return await asyncio.to_thread(_provision, session_id)
  except (psycopg.Error, TimeoutError) as exc:
    return {"error": str(exc).strip()}


@mcp.tool()
async def release_database(ctx: Context) -> dict[str, Any]:
  """Drops your scratch database AND all its data.

  Call when the user is done (a TTL reaper cleans up otherwise).
  """
  session_id = _session_id(ctx)
  if not session_id:
    return _NO_HEADER
  with _LOCK:
    session = _sessions.get(session_id)
  if session is None:
    return {"status": "nothing_to_release"}
  try:
    await asyncio.to_thread(_release, session)
  except (psycopg.Error, TimeoutError) as exc:
    return {"error": str(exc).strip()}
  print(f"[agent-workspace] released {session.database}", flush=True)
  return {"status": "released", "database": session.database}


@mcp.tool()
async def execute_sql(  # pylint: disable=redefined-outer-name
    sql: str, ctx: Context
) -> dict[str, Any]:
  """Runs any SQL statement in your private scratch database.

  Supports CREATE TABLE, INSERT, UPDATE, SELECT, etc. Never touches the primary
  database. Queries return up to 1000 rows.
  """
  if not _session_id(ctx):
    return _NO_HEADER
  session = _session_from_headers(ctx)
  if session is None:
    return _NO_SESSION
  try:
    return await asyncio.to_thread(_run_sql, session, sql)
  except psycopg.Error as exc:
    return {"error": str(exc).strip()}


@mcp.tool()
async def get_schema(ctx: Context, table: str = "") -> dict[str, Any]:
  """Lists the tables and columns built in your private scratch database.

  Pass `table` to describe just one table.
  """
  if not _session_id(ctx):
    return _NO_HEADER
  session = _session_from_headers(ctx)
  if session is None:
    return _NO_SESSION
  try:
    return await asyncio.to_thread(_schema, session, table)
  except psycopg.Error as exc:
    return {"error": str(exc).strip()}


# --------------------------------------------------------------------------
# TTL reaper (in-process daemon thread)
# --------------------------------------------------------------------------
_REAP_INTERVAL_S = 60


def _reap_expired(ttl_minutes: int = DEFAULT_TTL_MIN) -> dict[str, Any]:
  """Drops session databases that have exceeded `ttl_minutes`."""
  now, released = int(time.time()), []
  with _LOCK:
    sessions = list(_sessions.values())
  for session in sessions:
    if now - session.created_at > ttl_minutes * 60:
      try:
        _release(session)
        released.append(session.database)
      except Exception as exc:  # pylint: disable=broad-exception-caught
        print(
            f"[agent-workspace] reap failed for {session.database}: {exc!r}",
            flush=True,
        )
  if released:
    print(f"[agent-workspace] reaped {released}", flush=True)
  return {"released": released}


def _start_reaper_thread(interval_s: int = _REAP_INTERVAL_S) -> None:
  def _loop() -> None:
    while True:
      time.sleep(interval_s)
      try:
        _reap_expired()
      except Exception as exc:  # pylint: disable=broad-exception-caught
        print(f"[agent-workspace] reaper loop error: {exc!r}", flush=True)

  t = threading.Thread(target=_loop, name="ttl-reaper", daemon=True)
  t.start()
  print(
      "[agent-workspace] in-process TTL reaper started "
      f"(ttl={DEFAULT_TTL_MIN}m, interval={interval_s}s)",
      flush=True,
  )


# --------------------------------------------------------------------------
# Startup: wait for Postgres, reconcile orphans, PROVE isolation
# --------------------------------------------------------------------------
def _wait_for_postgres(timeout_s: int = 120) -> None:
  deadline = time.monotonic() + timeout_s
  while True:
    try:
      with _admin_conn():
        return
    except psycopg.OperationalError as exc:
      if time.monotonic() > deadline:
        raise RuntimeError(f"postgres not ready: {exc}") from exc
      time.sleep(1)


def _wipe_orphans() -> None:
  """Drops any orphaned `agent_db_*` databases and `agent_*` roles at startup."""
  with _admin_conn() as conn:
    dbs = [
        r[0]
        for r in conn.execute(
            "SELECT datname FROM pg_database WHERE datname LIKE 'agent_db_%'"
        )
    ]
    roles = [
        r[0]
        for r in conn.execute(
            "SELECT rolname FROM pg_roles WHERE rolname ~"
            " '^agent_[0-9a-f]{12}$'"
        )
    ]
  for db in dbs:
    with _admin_conn() as conn:
      conn.execute(
          sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(
              sql.Identifier(db)
          )
      )
  for role in roles:
    with _admin_conn() as conn:
      conn.execute(
          sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(role))
      )
  if dbs or roles:
    print(
        f"[agent-workspace] wiped orphans: dbs={dbs} roles={roles}", flush=True
    )


def _isolation_self_check() -> None:
  """Prove isolation layer 2 (Postgres grants) before serving traffic."""
  a_id, b_id = uuid.uuid4().hex, uuid.uuid4().hex
  specs = [
      (f"agent_db_{a_id}", f"agent_{a_id[:12]}", secrets.token_urlsafe(24)),
      (f"agent_db_{b_id}", f"agent_{b_id[:12]}", secrets.token_urlsafe(24)),
  ]
  try:
    for db, role, pw in specs:
      _create_db_and_role(db, role, pw)

    def can_connect(db: str, role: str, pw: str) -> bool:
      try:
        with psycopg.connect(
            host=PG_HOST,
            port=PG_PORT,
            dbname=db,
            user=role,
            password=pw,
            connect_timeout=5,
        ):
          return True
      except psycopg.OperationalError:
        return False

    (db_a, role_a, pw_a), (db_b, role_b, pw_b) = specs
    checks = {
        "A reaches own DB": can_connect(db_a, role_a, pw_a),
        "B reaches own DB": can_connect(db_b, role_b, pw_b),
        "A blocked from B's DB": not can_connect(db_b, role_a, pw_a),
        "B blocked from A's DB": not can_connect(db_a, role_b, pw_b),
        "A blocked from maintenance DB": not can_connect(
            "postgres", role_a, pw_a
        ),
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
      print(
          f"[agent-workspace] isolation-self-check: FAIL {failed}", flush=True
      )
      sys.exit(1)
    print("[agent-workspace] isolation-self-check: PASS", flush=True)
  finally:
    for db, role, _ in specs:
      try:
        _drop_db_and_role(db, role)
      except Exception as exc:  # pylint: disable=broad-exception-caught
        print(
            f"[agent-workspace] self-check cleanup failed for {db}: {exc!r}",
            flush=True,
        )


app = mcp.streamable_http_app(
    stateless_http=True,
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=False
    ),
)

if __name__ == "__main__":
  import uvicorn  # pylint: disable=g-import-not-at-top

  _wait_for_postgres()
  _wipe_orphans()
  _isolation_self_check()
  _start_reaper_thread()
  uvicorn.run(app, host="0.0.0.0", port=8080)
