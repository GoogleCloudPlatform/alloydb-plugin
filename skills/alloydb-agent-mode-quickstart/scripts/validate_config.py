#!/usr/bin/env python3
"""Validates a `*.alloydb-agent.yaml` file offline and reports its topology.

Usage:
    .venv/bin/python scripts/validate_config.py --config
    <name>.alloydb-agent.yaml
"""

import argparse
import pathlib
import re
import sys

from deploy_infra import DeploymentConfig

NAME_RE = re.compile(r"^[a-z]([a-z0-9-]*[a-z0-9])?$")
SUFFIX_RE = re.compile(r"^-[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
REGION_RE = re.compile(r"^[a-z]+-[a-z]+[0-9]$")


# =============================================================================
# 1. Top-Level Entrypoint (Big Picture)
# =============================================================================


def main() -> None:
  """Parses CLI arguments and runs offline validation on the config file."""
  ap = argparse.ArgumentParser(description=__doc__)
  ap.add_argument("--config", required=True)
  args = ap.parse_args()

  cfg_path = pathlib.Path(args.config)
  if not cfg_path.exists():
    sys.exit(f"config not found: {cfg_path}")
  cfg = DeploymentConfig.from_file(cfg_path)

  print(f"==> {cfg_path.name}")
  errors, warnings = ConfigValidator(cfg).validate()

  for warning in warnings:
    print(f"    WARNING: {warning}")
  for error in errors:
    print(f"    ERROR:   {error}")
  if errors:
    sys.exit(f"==> {len(errors)} error(s); fix the config before step 2.")

  print(
      "==> Topology: primary=direct (AlloyDB Agent Pool), "
      + (
          "agent_workspace=yes (per-session scratch databases), "
          if cfg.agent_workspace
          else "agent_workspace=NO, "
      )
      + (
          "coordinator=yes (swarm coordinator)"
          if cfg.coordinator
          else "coordinator=NO (single agent)"
      )
  )
  print("==> Valid.")


# =============================================================================
# 2. Config Validator (Top-Down Call Stack)
# =============================================================================


class ConfigValidator:
  """Offline validator for `*.alloydb-agent.yaml` configuration files."""

  def __init__(self, cfg: DeploymentConfig) -> None:
    """Initializes the validator with the deployment configuration."""
    self.cfg = cfg
    self.errors: list[str] = []
    self.warnings: list[str] = []

  def validate(self) -> tuple[list[str], list[str]]:
    """Validates all config sections and returns `(errors, warnings)`."""
    self._check_base()
    if not self.cfg.database:
      self.errors.append("database is required")
    else:
      missing_db = [
          k
          for k in ("cluster", "instance", "database")
          if not (self.cfg.database.get(k) or "").strip()
      ]
      for k in missing_db:
        self.errors.append(f"database.{k} is required")
    return self.errors, self.warnings

  def _check_base(self) -> None:
    """Validates top-level fields, VPC, and Agent Engine names."""
    cfg = self.cfg
    err, warn = self.errors.append, self.warnings.append

    if not cfg.project_id:
      err("project_id is required")
    if not cfg.region:
      err("region is required")
    elif not REGION_RE.match(cfg.region):
      warn(
          f"region {cfg.region!r} does not look like a GCP region (e.g."
          " us-central1)"
      )

    missing_vpc = [
        k
        for k in ("network", "subnet")
        if not str(cfg.vpc.get(k) or "").strip()
    ]
    if missing_vpc:
      err(f"vpc.{', vpc.'.join(missing_vpc)} is required")

    if cfg.name_suffix:
      if not SUFFIX_RE.match(cfg.name_suffix) or len(cfg.name_suffix) > 20:
        err(
            f"name_suffix {cfg.name_suffix!r} must start with '-' followed by"
            " lowercase letters, digits, or hyphens (<=20 chars, e.g."
            " '-dev')"
        )

    if not cfg.name:
      err("name is required")
    else:
      if not NAME_RE.match(cfg.name):
        err(
            f"name {cfg.name!r} must be lowercase letters, digits and hyphens, "
            "starting with a letter"
        )
      if len(cfg.name) > 24:
        err(
            f"name is {len(cfg.name)} chars; agent-<name>@ must fit IAM's "
            "30-character account id, so 24 is the ceiling"
        )
    if not (cfg.raw.get("model") or "").strip():
      warn("model is unset; the default (gemini-3.8-flash) will be used")

    display = cfg.agent_display_name
    if not display:
      err("agent_engine.agent.display_name is required")
    elif "coordinator" in display.lower():
      err(
          f"agent_engine.agent.display_name {display!r} must not contain"
          " 'Coordinator' (coordinator target auto-discovery skips engines"
          " with 'Coordinator' in the name)"
      )
    coord_display = cfg.coordinator.get("display_name")
    if coord_display and "coordinator" not in coord_display.lower():
      warn(
          f"agent_engine.coordinator.display_name {coord_display!r} does not"
          " contain 'Coordinator'; target auto-discovery may pick the"
          " coordinator as its own target"
      )

    for role, block in (("agent", cfg.agent), ("coordinator", cfg.coordinator)):
      ctx = block.get("context")
      if ctx is None:
        continue
      if not isinstance(ctx, str):
        err(
            f"agent_engine.{role}.context must be plain text (use a"
            " YAML block scalar `|-` for multi-line text)"
        )
      elif len(ctx) > 20000:
        warn(
            f"agent_engine.{role}.context is {len(ctx)} chars; it is"
            " sent with every model call, so keep it focused"
        )

    raw_ws = cfg.agent.get("workspace")
    if raw_ws is not None and not isinstance(raw_ws, bool):
      err(
          "agent_engine.agent.workspace must be a boolean (`workspace: true`"
          " or `workspace: false`)"
      )

    ae = cfg.raw.get("agent_engine") or {}
    if isinstance(ae, dict) and "coordinator" in ae:
      raw_coord = ae.get("coordinator")
      if raw_coord is not None and not isinstance(raw_coord, dict):
        err(
            "agent_engine.coordinator must be a mapping (or omit the"
            " `coordinator` key for a single agent)"
        )


if __name__ == "__main__":
  main()
