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

r"""Infrastructure provisioning for alloydb-agent-mode-quickstart (step 2).

Provisions two isolated Terraform layers through Infrastructure Manager using a
uniform "create-if-missing, delete-only-what-we-created" ownership model
(`existing` set variable/output, zero `imports.tf`):
  1. `alloydb-agent-project` (`assets/terraform/project`) — shared project
     APIs, VPC, subnet, PSC endpoint, private `*.run.app` DNS, network
     attachment, service-agent/Cloud Build IAM, staging bucket, and the
     `alloydb-agent` Artifact Registry repository. Any resource that already
     exists before deployment is recorded in `existing` (`count = 0`) and left
     untouched on `--delete-policy=DELETE`; any resource missing before
     deployment is created (`count = 1`) and deleted on teardown.
  2. `alloydb-agent-<name>` (`assets/terraform/workspace`) — per-deployment
     `agent-<name>@` service account + IAM roles (and its `IAM_BASED` AlloyDB
     database user), plus the `alloydb-agent-workspace-<name>` Cloud Run
     service and secrets when `agent_engine.agent.workspace: true`.

Usage (from the working directory):
    python scripts/deploy_infra.py --config <name>.alloydb-agent.yaml
"""

import argparse
from collections.abc import Callable
import dataclasses
import hashlib
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any

import yaml

os.environ.setdefault("CLOUDSDK_CORE_DISABLE_PROMPTS", "1")

SCRIPTS = pathlib.Path(__file__).resolve().parent
SKILL_ROOT = SCRIPTS.parent
SETUP_MODULE = SKILL_ROOT / "assets" / "terraform" / "project"
WORKSPACE_MODULE = SKILL_ROOT / "assets" / "terraform" / "workspace"
INITDB_SQL = (
    SKILL_ROOT / "assets" / "agent_workspace" / "database" / "provisioner.sql"
)
ROUTER_SERVICE_SRC = SKILL_ROOT / "assets" / "agent_workspace" / "service"

DEFAULT_SUBNET_CIDR = "10.10.0.0/24"
DEFAULT_PSC_GAPIS_IP = "10.10.255.10"

BOOTSTRAP_APIS = (
    "config.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudbuild.googleapis.com",
    "storage.googleapis.com",
    "compute.googleapis.com",
    "aiplatform.googleapis.com",
)

RUNNER_ROLES = (
    "roles/config.agent",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/compute.networkAdmin",
    "roles/dns.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/storage.admin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    "roles/run.admin",
    "roles/iam.serviceAccountUser",
)

VERTEX_AGENT_ROLES = ("roles/compute.networkAdmin", "roles/dns.peer")
CLOUDBUILD_ROLES = (
    "roles/cloudbuild.builds.builder",
    "roles/cloudbuild.builds.editor",
    "roles/storage.admin",
    "roles/artifactregistry.writer",
)
AGENT_ROLES = (
    "roles/aiplatform.user",
    "roles/alloydb.databaseUser",
    "roles/alloydb.client",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/logging.logWriter",
    "roles/cloudtrace.agent",
    "roles/monitoring.metricWriter",
)


# =============================================================================
# 1. Top-Level Entrypoint (Big Picture)
# =============================================================================


def main() -> None:
  """Parses CLI arguments and provisions project and deployment infrastructure."""
  args = _build_parser().parse_args()
  cfg = DeploymentConfig.from_file(args.config)
  ProjectBootstrapper(cfg).run()
  url = WorkspaceDeployer(cfg).run()
  print(f"\n==> AGENT_SA={cfg.agent_sa}", flush=True)
  if cfg.agent_workspace:
    print(f"==> AGENT_WORKSPACE_URL={url}", flush=True)
  print(
      f"==> Next: .venv/bin/python {SCRIPTS / 'deploy_agent.py'} deploy"
      f" --config {args.config}",
      flush=True,
  )


def _build_parser() -> argparse.ArgumentParser:
  """Builds the CLI argument parser for deploy_infra.py."""
  ap = argparse.ArgumentParser(
      description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
  )
  ap.add_argument("--config", required=True)
  return ap


# =============================================================================
# 2. Core Workflows (Top-Down Call Stack)
# =============================================================================


class ProjectBootstrapper:
  """Layer 1 (`alloydb-agent-project`): shared project & VPC foundation."""

  def __init__(self, cfg: "DeploymentConfig") -> None:
    """Initializes the bootstrapper with the deployment configuration."""
    self.cfg = cfg

  def run(self) -> None:
    """Bootstraps the Infra Manager runner SA and applies project Terraform."""
    self._bootstrap_infra_manager()
    self._apply_project_terraform()

  def _bootstrap_infra_manager(self) -> None:
    """Enables bootstrap APIs, creates `infra-manager@` SA, and grants roles."""
    project = self.cfg.project_id
    runner = self.cfg.runner_sa
    # Idempotent, so run it even when the runner SA already exists.
    _run([
        "gcloud",
        "services",
        "enable",
        *BOOTSTRAP_APIS,
        f"--project={project}",
    ])
    if not _sa_exists(runner, project):
      print("==> Infra Manager runner missing; creating it", flush=True)
      res = _capture([
          "gcloud",
          "iam",
          "service-accounts",
          "create",
          "infra-manager",
          f"--project={project}",
          "--display-name=Infrastructure Manager runner (alloydb-agent)",
      ])
      # A concurrent run may have created it first (ALREADY_EXISTS).
      if res.returncode != 0 and not _sa_exists(runner, project):
        sys.exit(
            f"FAILED: could not create {runner}:\n{(res.stderr or '').strip()}"
        )

    _ensure_project_roles(project, runner, RUNNER_ROLES)
    print(f"==> Runner ready: {runner}", flush=True)

  def _apply_project_terraform(self) -> None:
    """Applies `assets/terraform/project` via Infrastructure Manager."""
    suffix = self.cfg.name_suffix
    deployment_id = f"alloydb-agent-project{suffix}"
    _wait_deployment_unlocked(
        self.cfg.project_id, self.cfg.region, deployment_id
    )
    subnet_cidr, psc_ip, existing = self._detect_existing_resources(
        deployment_id
    )
    inputs = {
        "project_id": self.cfg.project_id,
        "region": self.cfg.region,
        "network": self.cfg.network,
        "subnet": self.cfg.subnet,
        "network_attachment": self.cfg.network_attachment,
        "subnet_cidr": subnet_cidr,
        "psc_googleapis_ip": psc_ip,
        "name_suffix": suffix,
        "existing": existing,
    }
    deployment = _apply_infra_manager(
        self.cfg, deployment_id, SETUP_MODULE, inputs
    )
    _run([
        "gcloud",
        "infra-manager",
        "deployments",
        "describe",
        deployment,
        f"--project={self.cfg.project_id}",
        '--format=value[separator="  "](state,latestRevision)',
    ])

  def _detect_existing_resources(
      self, deployment_id: str
  ) -> tuple[str, str, list[str]]:
    """Detects pre-existing project resources to reuse without Terraform ownership."""
    project, region = self.cfg.project_id, self.cfg.region
    suffix = self.cfg.name_suffix
    network, subnet = self.cfg.network, self.cfg.subnet
    attachment = self.cfg.network_attachment
    current: set[str] = set()

    existing_cidr = _out([
        "gcloud",
        "compute",
        "networks",
        "subnets",
        "describe",
        subnet,
        f"--region={region}",
        f"--project={project}",
        "--format=value(ipCidrRange)",
    ])
    if existing_cidr:
      current.add("subnet")
    subnet_cidr = existing_cidr or DEFAULT_SUBNET_CIDR

    existing_ip = _out([
        "gcloud",
        "compute",
        "addresses",
        "describe",
        f"psc-googleapis{suffix}",
        "--global",
        f"--project={project}",
        "--format=value(address)",
    ])
    if existing_ip:
      current.add("psc_address")
    psc_ip = existing_ip or DEFAULT_PSC_GAPIS_IP

    clean_suffix = re.sub(r"[^A-Za-z0-9]", "", suffix).lower()
    fwd_name = f"pscgapis{clean_suffix}"[:20]
    zone_name = f"run-app-private{suffix}"
    checks = (
        ("vpc", ["compute", "networks", "describe", network]),
        (
            "psc_forwarding_rule",
            ["compute", "forwarding-rules", "describe", fwd_name, "--global"],
        ),
        ("dns_zone", ["dns", "managed-zones", "describe", zone_name]),
        (
            "network_attachment",
            [
                "compute",
                "network-attachments",
                "describe",
                attachment,
                f"--region={region}",
            ],
        ),
        (
            "staging_bucket",
            ["storage", "buckets", "describe", self.cfg.staging_bucket],
        ),
        (
            "artifact_repo",
            [
                "artifacts",
                "repositories",
                "describe",
                self.cfg.artifact_repo,
                f"--location={region}",
            ],
        ),
    )
    for key, args in checks:
      if _ok(["gcloud", *args, f"--project={project}"]):
        current.add(key)
    if "dns_zone" in current and _ok([
        "gcloud",
        "dns",
        "record-sets",
        "describe",
        "*.run.app.",
        "--type=A",
        f"--zone={zone_name}",
        f"--project={project}",
    ]):
      current.add("dns_record")

    num = _out(
        [
            "gcloud",
            "projects",
            "describe",
            project,
            "--format=value(projectNumber)",
        ],
        check=True,
    )
    sa_roles = _get_project_sa_roles(project)
    vertex_sa = f"service-{num}@gcp-sa-aiplatform.iam.gserviceaccount.com"
    if set(VERTEX_AGENT_ROLES) <= sa_roles.get(vertex_sa, set()):
      current.add("aiplatform_iam")
    cb_sa = f"{num}-compute@developer.gserviceaccount.com"
    if set(CLOUDBUILD_ROLES) <= sa_roles.get(cb_sa, set()):
      current.add("cloudbuild_iam")

    prev = _get_deployment_existing(project, region, deployment_id)
    existing = sorted(current if prev is None else (current & prev))
    if existing:
      print(
          f"==> Reusing {len(existing)} pre-existing project resource(s)"
          f" (untouched on teardown): {', '.join(existing)}",
          flush=True,
      )
    return subnet_cidr, psc_ip, existing


class WorkspaceDeployer:
  """Layer 2 (`alloydb-agent-<name>`): agent identity and optional Workspace."""

  def __init__(self, cfg: "DeploymentConfig") -> None:
    """Initializes the deployer with the deployment configuration."""
    self.cfg = cfg

  def run(self) -> str:
    """Provisions `alloydb-agent-<name>`, AlloyDB IAM user, and optional Cloud Run."""
    image = ""
    if self.cfg.agent_workspace:
      image = self._build_router_image()
      print(f"==> router image: {image}", flush=True)

    url = self._apply_workspace_terraform(router_image=image)
    self._ensure_alloydb_iam_user(self.cfg.agent_sa)
    return url

  def _build_router_image(self) -> str:
    """Builds router image if source changed and returns digest reference."""
    project, region = self.cfg.project_id, self.cfg.region
    tag = self._source_digest(ROUTER_SERVICE_SRC)
    repo = self.cfg.artifact_repo
    image = f"{region}-docker.pkg.dev/{project}/{repo}/agent-workspace:{tag}"

    if _ok([
        "gcloud",
        "artifacts",
        "docker",
        "images",
        "describe",
        image,
        f"--project={project}",
    ]):
      print(
          f"==> Router image already built for this source: {tag}",
          flush=True,
      )
    else:
      print(f"==> Building router image {tag}", flush=True)
      with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        fh.write(
            "steps:\n- name: gcr.io/cloud-builders/docker\n  args: ['build',"
            f" '-t', '{image}', '.']\nimages: ['{image}']\noptions:\n"
            "  logging: CLOUD_LOGGING_ONLY\n"
        )
        build_cfg = pathlib.Path(fh.name)
      try:
        _run([
            "gcloud",
            "builds",
            "submit",
            str(ROUTER_SERVICE_SRC),
            f"--config={build_cfg}",
            f"--project={project}",
        ])
      finally:
        build_cfg.unlink(missing_ok=True)

    ref = _out(
        [
            "gcloud",
            "artifacts",
            "docker",
            "images",
            "describe",
            image,
            f"--project={project}",
            "--format=value(image_summary.fully_qualified_digest)",
        ],
        check=True,
    )
    if not ref:
      sys.exit(f"FAILED: could not read the digest for {image}")
    return ref

  @staticmethod
  def _source_digest(src_dir: pathlib.Path) -> str:
    """Computes a 12-char SHA-256 digest over the router source files."""
    hasher = hashlib.sha256()
    source_files = sorted(
        p
        for p in src_dir.rglob("*")
        if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"
    )
    for file_path in source_files:
      hasher.update(hashlib.sha256(file_path.read_bytes()).hexdigest().encode())
      hasher.update(str(file_path.relative_to(src_dir)).encode())
    return hasher.hexdigest()[:12]

  def _apply_workspace_terraform(self, router_image: str) -> str:
    """Applies `assets/terraform/workspace` and returns the Cloud Run URL."""
    project = self.cfg.project_id
    deployment_id = f"alloydb-agent-{self.cfg.name}"
    current: set[str] = set()
    if _sa_exists(self.cfg.agent_sa, project):
      current.add("agent_sa")
      sa_roles = _get_project_sa_roles(project).get(self.cfg.agent_sa, set())
      if set(AGENT_ROLES).issubset(sa_roles):
        current.add("agent_iam")
    prev = _get_deployment_existing(project, self.cfg.region, deployment_id)
    existing = sorted(current if prev is None else (current & prev))
    inputs = {
        "project_id": project,
        "region": self.cfg.region,
        "agent_name": self.cfg.name,
        "agent_display_name": self.cfg.agent_display_name or self.cfg.name,
        "enable_workspace": self.cfg.agent_workspace,
        "router_image": router_image,
        "network": self.cfg.network,
        "subnet": self.cfg.subnet,
        "initdb_sql": (
            INITDB_SQL.read_text() if self.cfg.agent_workspace else ""
        ),
        "existing": existing,
    }
    _apply_infra_manager(self.cfg, deployment_id, WORKSPACE_MODULE, inputs)
    return self.cfg.resolve_workspace_url() if self.cfg.agent_workspace else ""

  def _ensure_alloydb_iam_user(self, agent_sa: str) -> None:
    """Ensures the Agent SA exists as an `IAM_BASED` AlloyDB user with read access."""
    cluster = self.cfg.cluster
    if not cluster:
      return
    db_user = agent_sa.removesuffix(".gserviceaccount.com")
    db_roles = "alloydbiamuser,pg_read_all_data"
    base_args = [
        db_user,
        f"--cluster={cluster}",
        f"--region={self.cfg.region}",
        f"--project={self.cfg.project_id}",
    ]
    create_cmd = [
        "gcloud",
        "alloydb",
        "users",
        "create",
        *base_args,
        "--type=IAM_BASED",
        f"--db-roles={db_roles}",
    ]
    set_roles_cmd = [
        "gcloud",
        "alloydb",
        "users",
        "set-roles",
        *base_args,
        f"--db-roles={db_roles}",
    ]
    res = _capture(create_cmd)
    if res.returncode == 0:
      print(
          f"==> Created AlloyDB IAM user {db_user} on cluster {cluster}"
          f" ({db_roles})",
          flush=True,
      )
      return
    if "ALREADY_EXISTS" in (res.stderr or ""):
      role_res = _capture(set_roles_cmd)
      if role_res.returncode != 0:
        sys.exit(
            f"Failed to set roles ({db_roles}) on AlloyDB user {db_user}:\n"
            f"{(role_res.stderr or '').strip()}"
        )
      print(
          f"==> AlloyDB IAM user already exists: {db_user}"
          f" (ensured roles: {db_roles})",
          flush=True,
      )
      return
    sys.exit(
        f"Failed to create AlloyDB IAM user {db_user} on cluster {cluster}:\n"
        f"{(res.stderr or '').strip()}"
    )


# =============================================================================
# 3. Configuration Model & Shared Helpers
# =============================================================================

_POOL_URL_CACHE: dict[tuple[str, str, str, str], str] = {}
_CLUSTER_CA_CACHE: dict[tuple[str, str, str], str] = {}


@dataclasses.dataclass(frozen=True)
class DeploymentConfig:
  """Parsed `*.alloydb-agent.yaml` configuration."""

  raw: dict[str, Any]
  path: pathlib.Path
  name: str
  project_id: str
  region: str
  agent: dict[str, Any]
  coordinator: dict[str, Any]
  gemini_enterprise: dict[str, Any]
  database: dict[str, Any]
  agent_workspace: bool
  vpc: dict[str, Any]

  @classmethod
  def from_file(cls, cfg_path: str | pathlib.Path) -> "DeploymentConfig":
    """Loads and resolves a deployment configuration from a YAML file path."""
    path = pathlib.Path(cfg_path).resolve()
    raw = _as_dict(yaml.safe_load(path.read_text()))
    ae = _as_dict(raw.get("agent_engine"))
    agent = _as_dict(ae.get("agent"))
    ge = _as_dict(raw.get("gemini_enterprise"))
    ws_flag = agent.get("workspace")
    raw_coord = ae.get("coordinator")
    if "coordinator" in ae and (
        raw_coord is None or isinstance(raw_coord, dict)
    ):
      coord = dict(raw_coord) if isinstance(raw_coord, dict) else {}
      if not coord.get("display_name"):
        base_display = str(
            agent.get("display_name") or raw.get("name") or ""
        ).strip()
        coord["display_name"] = f"{base_display} Swarm Coordinator".strip()
    else:
      coord = {}
    return cls(
        raw=raw,
        path=path,
        name=(raw.get("name") or "").strip(),
        project_id=(raw.get("project_id") or "").strip(),
        region=(raw.get("region") or "").strip(),
        agent=agent,
        coordinator=coord,
        gemini_enterprise=ge,
        database=_as_dict(raw.get("database")),
        agent_workspace=bool(ws_flag) if isinstance(ws_flag, bool) else False,
        vpc=_as_dict(raw.get("vpc")),
    )

  @property
  def agent_display_name(self) -> str:
    """Returns the main agent's display name (defaults from `name`)."""
    explicit = (self.agent.get("display_name") or "").strip()
    if explicit:
      return explicit
    return f"{self.name.replace('-', ' ').title()} Agent".strip()

  @property
  def agent_sa(self) -> str:
    """Returns the deployment's runtime service account email."""
    return f"agent-{self.name}@{self.project_id}.iam.gserviceaccount.com"

  @property
  def runner_sa(self) -> str:
    """Returns the Infrastructure Manager runner service account email."""
    return f"infra-manager@{self.project_id}.iam.gserviceaccount.com"

  @property
  def name_suffix(self) -> str:
    """Returns the optional `name_suffix` for project-foundation isolation."""
    return (self.raw.get("name_suffix") or "").strip()

  @property
  def staging_bucket(self) -> str:
    """Returns the `gs://` staging bucket URI for Agent Engine deployments."""
    return f"gs://{self.project_id}-agent-staging{self.name_suffix}"

  @property
  def artifact_repo(self) -> str:
    """Returns the Artifact Registry repository ID for router images."""
    return f"alloydb-agent{self.name_suffix}"

  @property
  def model(self) -> str:
    """Returns the configured top-level Gemini model identifier."""
    return (self.raw.get("model") or "gemini-3.8-flash").strip()

  @property
  def network(self) -> str:
    """Returns the configured VPC network name (default: `agents-vpc`)."""
    return (self.vpc.get("network") or "agents-vpc").strip()

  @property
  def subnet(self) -> str:
    """Returns the configured VPC subnet name (default: `agents-subnet`)."""
    return (self.vpc.get("subnet") or "agents-subnet").strip()

  @property
  def network_attachment(self) -> str:
    """Returns the configured PSC network attachment name."""
    return (
        self.vpc.get("network_attachment")
        or f"agents-psc-attachment{self.name_suffix}"
    ).strip()

  @property
  def cluster(self) -> str:
    """Returns the configured AlloyDB cluster ID."""
    return (self.database.get("cluster") or "").strip()

  @property
  def instance(self) -> str:
    """Returns the configured AlloyDB Agent Pool instance ID."""
    return (self.database.get("instance") or "").strip()

  @property
  def db_name(self) -> str:
    """Returns the configured PostgreSQL database name."""
    return (self.database.get("database") or "postgres").strip()

  def agent_context(self, role: str) -> str:
    """Returns the optional plain-text context for `role` (`agent` or `coordinator`)."""
    agent_ctx = str(self.agent.get("context") or "").strip()
    if role == "coordinator":
      return str(self.coordinator.get("context") or "").strip() or agent_ctx
    return agent_ctx

  def coordinator_display_info(self) -> tuple[str, str]:
    """Returns `(display_name, description)` for the swarm coordinator."""
    display = (
        self.coordinator.get("display_name")
        or f"{self.agent_display_name} Swarm Coordinator"
    )
    desc = self.gemini_enterprise.get("description") or (
        "Launches a swarm of parallel investigation agents against"
        f" {self.agent_display_name}, tracks their progress, and synthesizes a"
        " ranked findings report with inline charts. Ask it to investigate a"
        " problem with N agents; check back for status and the report."
    )
    return display, desc

  def resolve_workspace_url(self) -> str:
    """Resolves the Agent Workspace Cloud Run URL via `gcloud run services`."""
    service = f"alloydb-agent-workspace-{self.name}"
    url = _out([
        "gcloud",
        "run",
        "services",
        "describe",
        service,
        f"--project={self.project_id}",
        f"--region={self.region}",
        "--format=value(status.url)",
    ]).rstrip("/")
    if not url:
      sys.exit(
          f"ERROR: Could not resolve Cloud Run service {service} in "
          f"{self.project_id}/{self.region}; "
          "run `deploy_infra.py --config <config>` first."
      )
    print(f"==> Resolved Agent Workspace ({service}): {url}", flush=True)
    return url

  def primary_endpoint(self) -> dict[str, str]:
    """Resolves primary database endpoint metadata from `database:` config."""
    if not (self.cluster and self.instance):
      return {"url": "", "ca_pem": ""}
    return {
        "url": _resolve_agent_pool_url(
            self.project_id, self.region, self.cluster, self.instance
        ),
        "ca_pem": _resolve_cluster_ca(
            self.project_id, self.region, self.cluster
        ),
    }


def _resolve_agent_pool_url(
    project_id: str, region: str, cluster: str, instance: str
) -> str:
  """Resolves an AlloyDB Agent Pool instance's MCP base URL via gcloud."""
  key = (project_id, region, cluster, instance)
  if key in _POOL_URL_CACHE:
    return _POOL_URL_CACHE[key]
  base_cmd = [
      "gcloud",
      "beta",
      "alloydb",
      "instances",
      "describe",
      instance,
      f"--project={project_id}",
      f"--region={region}",
      f"--cluster={cluster}",
      "--format=value(agentPoolInfo.dnsName)",
  ]
  res = _capture(base_cmd)
  dns_name = (
      (res.stdout or "").strip().rstrip(".") if res.returncode == 0 else ""
  )
  if not dns_name:
    last_err = (res.stderr or res.stdout or "").strip()
    sys.exit(
        "FAILED: could not resolve agentPoolInfo.dnsName for "
        f"projects/{project_id}/locations/{region}/clusters/{cluster}"
        f"/instances/{instance}: {last_err}"
    )
  url = f"https://{dns_name}"
  print(
      f"==> Resolved AlloyDB Agent Pool ({cluster}/{instance}): {url}",
      flush=True,
  )
  _POOL_URL_CACHE[key] = url
  return url


def _resolve_cluster_ca(project_id: str, region: str, cluster: str) -> str:
  """Returns the cluster's root CA (`certificateAuthorityInfo.rootCaCert`)."""
  key = (project_id, region, cluster)
  if key in _CLUSTER_CA_CACHE:
    return _CLUSTER_CA_CACHE[key]
  res = _capture([
      "gcloud",
      "beta",
      "alloydb",
      "clusters",
      "describe",
      cluster,
      f"--project={project_id}",
      f"--region={region}",
      "--format=json(certificateAuthorityInfo.rootCaCert)",
  ])
  ca_pem = ""
  if res.returncode == 0:
    info = json.loads(res.stdout or "{}").get("certificateAuthorityInfo") or {}
    ca_pem = (info.get("rootCaCert") or "").strip()
  if "BEGIN CERTIFICATE" not in ca_pem:
    last_err = (res.stderr or res.stdout or "").strip()
    sys.exit(
        "FAILED: could not resolve certificateAuthorityInfo.rootCaCert for "
        f"projects/{project_id}/locations/{region}/clusters/{cluster}: "
        f"{last_err or 'empty'}"
    )
  print(f"==> Resolved cluster root CA ({cluster})", flush=True)
  _CLUSTER_CA_CACHE[key] = ca_pem
  return ca_pem


def _wait_deployment_unlocked(
    project: str, region: str, deployment_id: str
) -> None:
  """Waits (up to 20 min) while another apply holds the Infra Manager deployment."""
  deployment = (
      f"projects/{project}/locations/{region}/deployments/{deployment_id}"
  )
  # Two deployments in one project both re-apply the shared foundation stack,
  # and an apply takes several minutes.
  for _ in range(240):
    state = _out([
        "gcloud",
        "infra-manager",
        "deployments",
        "describe",
        deployment,
        f"--project={project}",
        '--format=value[separator=","](state,lockState)',
    ])
    if not state or (
        "LOCKED" not in state.split(",")
        and not state.startswith(("CREATING", "UPDATING", "DELETING"))
    ):
      return
    print(f"==> Waiting for {deployment_id} lock ({state})...", flush=True)
    time.sleep(5)


def _apply_infra_manager(
    cfg: DeploymentConfig,
    deployment_id: str,
    module_dir: pathlib.Path,
    inputs: dict[str, Any],
) -> str:
  """Stages a Terraform module with tfvars JSON and applies via Infra Manager."""
  project, region = cfg.project_id, cfg.region
  deployment = (
      f"projects/{project}/locations/{region}/deployments/{deployment_id}"
  )
  _wait_deployment_unlocked(project, region, deployment_id)
  with tempfile.TemporaryDirectory() as staged:
    for tf_file in module_dir.glob("*.tf"):
      shutil.copy(tf_file, staged)
    (pathlib.Path(staged) / "config.auto.tfvars.json").write_text(
        json.dumps(inputs, indent=2)
    )
    attempts = 3
    apply_cmd = [
        "gcloud",
        "infra-manager",
        "deployments",
        "apply",
        deployment,
        f"--project={project}",
        f"--service-account=projects/{project}/serviceAccounts/{cfg.runner_sa}",
        f"--local-source={staged}",
    ]
    for attempt in range(1, attempts + 1):
      print(f"==> Applying {deployment}", flush=True)
      print(f"==> {' '.join(apply_cmd)}", flush=True)
      proc = subprocess.Popen(apply_cmd, stderr=subprocess.PIPE, text=True)
      err = []
      for line in proc.stderr:  # Show gcloud's progress and keep its errors.
        sys.stderr.write(line)
        err.append(line)
      if proc.wait() == 0:
        break
      # Two applies of one deployment at once (for example two deployments
      # re-applying the shared foundation): the later one is refused ("unable
      # to queue the operation"), and its gcloud deletes the earlier one's
      # staged source ("blueprint fetch failed"). Retry both once the other
      # apply is done; any other failure is real.
      if attempt == attempts or not any(
          msg in "".join(err)
          for msg in (
              "unable to queue",
              "blueprint fetch failed",
              "The specified key does not exist",
          )
      ):
        raise subprocess.CalledProcessError(proc.returncode, apply_cmd)
      # Random delay so two runs that failed together don't retry in lockstep.
      delay = random.uniform(1, 10) * attempt
      print(f"==> Concurrent apply; retrying in {delay:.0f}s", flush=True)
      time.sleep(delay)
      _wait_deployment_unlocked(project, region, deployment_id)
  return deployment


def _get_deployment_existing(
    project: str, region: str, deployment_id: str
) -> set[str] | None:
  """Returns the deployment's recorded `existing` set, or None if it has none.

  Uses the `existing` output of the latest successful apply. A failed apply
  records no outputs but may already have created resources, so until one
  succeeds, falls back to the `existing` input staged for the latest revision
  that ran Terraform (Infra Manager keeps its `config.auto.tfvars.json` under
  `applyResults.content`). Otherwise a retry would mistake those resources for
  pre-existing ones and destroy them (`count` 1 -> 0).
  """
  res = subprocess.run(
      [
          "gcloud",
          "infra-manager",
          "revisions",
          "list",
          f"--deployment=projects/{project}/locations/{region}/deployments/{deployment_id}",
          f"--project={project}",
          "--sort-by=~createTime",
          "--format=json",
      ],
      capture_output=True,
      check=False,
      text=True,
  )
  if res.returncode != 0:
    if "NOT_FOUND" in (res.stderr or ""):
      return None
    sys.exit(
        f"FAILED: could not query revisions for {deployment_id}:"
        f" {(res.stderr or '').strip()}"
    )
  revisions = json.loads(res.stdout or "[]")
  for rev in revisions:
    outputs = (rev.get("applyResults") or {}).get("outputs") or {}
    if "existing" in outputs:
      return set(outputs["existing"].get("value") or [])
  for rev in revisions:
    content = (rev.get("applyResults") or {}).get("content")
    if not content:
      continue
    res = _capture(
        ["gcloud", "storage", "cat", f"{content}/config.auto.tfvars.json"]
    )
    if res.returncode != 0:
      # Absent if the revision failed before Terraform ran (nothing created).
      if "matched no objects" in (res.stderr or ""):
        continue
      # Any other error: stop rather than guess, since guessing wrong destroys
      # resources the failed apply created.
      sys.exit(
          f"FAILED: could not read the inputs of {deployment_id} from"
          f" {content}: {(res.stderr or '').strip()}"
      )
    tfvars = json.loads(res.stdout or "{}")
    if "existing" in tfvars:
      return set(tfvars["existing"] or [])
  return None


def _get_project_sa_roles(project: str) -> dict[str, set[str]]:
  """Returns `{sa_email: {role, ...}}` granted unconditionally on `project`."""
  raw = _out(
      ["gcloud", "projects", "get-iam-policy", project, "--format=json"],
      check=True,
  )
  roles_by_sa: dict[str, set[str]] = {}
  for binding in (json.loads(raw) if raw else {}).get("bindings", []):
    if binding.get("condition"):
      continue  # A conditional grant may not apply, so don't count it.
    role = binding.get("role", "")
    for member in binding.get("members", []):
      if member.startswith("serviceAccount:"):
        sa = member.removeprefix("serviceAccount:")
        roles_by_sa.setdefault(sa, set()).add(role)
  return roles_by_sa


def _ensure_project_roles(
    project: str, sa: str, roles: tuple[str, ...]
) -> None:
  """Ensures `sa` holds all `roles` on `project`, binding only missing roles."""
  existing = _get_project_sa_roles(project).get(sa, set())
  for role in roles:
    if role not in existing:
      print(f"==> Granting {role} to {sa} on {project}", flush=True)
      _retry(
          lambda r=role: _bind_project_role(project, sa, r),
          f"grant {role} to {sa}",
      )


def _bind_project_role(project: str, sa: str, role: str) -> bool:
  """Binds `role` to `sa` on `project`, returning True on exit status 0."""
  return _ok([
      "gcloud",
      "projects",
      "add-iam-policy-binding",
      project,
      f"--member=serviceAccount:{sa}",
      f"--role={role}",
      "--condition=None",
  ])


def _sa_exists(sa: str, project: str) -> bool:
  """Returns True if service account `sa` exists in `project`."""
  return _ok([
      "gcloud",
      "iam",
      "service-accounts",
      "describe",
      sa,
      f"--project={project}",
  ])


def _run(argv: list[str]) -> None:
  """Prints and executes a command, raising CalledProcessError on failure."""
  print(f"==> {' '.join(argv)}", flush=True)
  subprocess.run(argv, check=True)


def _ok(argv: list[str]) -> bool:
  """Returns True if the command exits with status 0 (output suppressed)."""
  return subprocess.run(argv, check=False, capture_output=True).returncode == 0


def _out(argv: list[str], check: bool = False) -> str:
  """Runs a command and returns its stripped stdout."""
  res = subprocess.run(argv, check=check, capture_output=True, text=True)
  return (res.stdout or "").strip()


def _capture(argv: list[str]) -> subprocess.CompletedProcess[str]:
  """Runs a command without raising and returns its captured result."""
  return subprocess.run(argv, check=False, capture_output=True, text=True)


def _as_dict(value: Any) -> dict[str, Any]:
  """Returns `value` if it is a mapping, else `{}` (missing or malformed)."""
  return value if isinstance(value, dict) else {}


def _retry(
    fn: Callable[[], bool],
    description: str,
    attempts: int = 12,
    delay_s: int = 5,
) -> None:
  """Polls `fn()` until it returns True, or exits with an error."""
  for _ in range(attempts):
    if fn():
      return
    time.sleep(delay_s)
  sys.exit(f"FAILED: could not {description}")


if __name__ == "__main__":
  try:
    main()
  except subprocess.CalledProcessError as exc:
    sys.exit(f"FAILED: {' '.join(exc.cmd)} exited {exc.returncode}")
