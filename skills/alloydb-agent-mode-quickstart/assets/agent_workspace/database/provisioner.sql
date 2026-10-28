-- Copyright 2026 Google LLC
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- Postgres init hook (mounted into /docker-entrypoint-initdb.d of the shared
-- Agent Workspace service's Postgres sidecar). Runs on every cold start because
-- pgdata is a fresh in-memory volume — exactly the ephemeral model we want.
--
-- WHY THIS EXISTS: the official postgres image makes POSTGRES_USER a SUPERUSER,
-- and a superuser bypasses all GRANT/REVOKE checks — so SQL run as it can reach
-- COPY ... FROM PROGRAM (shell exec), pg_read_server_files, CREATE EXTENSION
-- (native code), and dblink/fdw. The bootstrap superuser ($POSTGRES_USER, e.g.
-- pgadmin) is therefore NEVER exposed outside this container. Instead we create
-- `provisioner`, the NOSUPERUSER role the ROUTER runs per-session DDL as:
-- CREATEDB + CREATEROLE let it mint one database + one login role per agent
-- session, but NOSUPERUSER keeps every superuser-only escape hatch closed even
-- if the router itself were compromised.
--
-- Cross-session isolation groundwork laid here (the router adds the per-DB
-- REVOKE CONNECT ... FROM PUBLIC at each provision):
--   * PUBLIC loses CONNECT on the maintenance DBs (postgres, template1), so a
--     session role can reach NOTHING it isn't explicitly granted;
--   * pg_signal_backend lets provisioner terminate session backends, which
--     DROP DATABASE ... WITH (FORCE) requires at release/reap time.
\set ON_ERROR_STOP on
\getenv pw PROVISIONER_PASSWORD
CREATE ROLE provisioner LOGIN PASSWORD :'pw'
    NOSUPERUSER CREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
GRANT CONNECT ON DATABASE postgres TO provisioner;
GRANT pg_signal_backend TO provisioner;
