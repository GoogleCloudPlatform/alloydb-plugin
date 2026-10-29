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

# =============================================================================
# Per-deployment agent identity and optional Agent Workspace service.
#
# Applied by deploy_infra.py through Infrastructure Manager (deployment
# `alloydb-agent-<name>`), isolated per deployment so multiple agents in the
# same project never collide.
#
# Always creates:
#   - `agent-<name>@<project_id>` service account and its runtime IAM roles.
#
# When `var.enable_workspace` is true (`agent_engine.agent.workspace: true`),
# also creates:
#   - Per-deployment Secret Manager secrets (`alloydb-agent-*-<name>`).
#   - Cloud Run service `alloydb-agent-workspace-<name>` ([router + PostgreSQL
#     sidecar], internal-only, min=max=1) and static `roles/run.invoker` IAM.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---- Agent runtime identity (agent-<name>@<project_id>) ---------------------
resource "google_service_account" "agent" {
  count      = contains(var.existing, "agent_sa") ? 0 : 1
  account_id = "agent-${var.agent_name}"
  display_name = (
    var.agent_display_name != ""
    ? "Agent ${var.agent_display_name}"
    : "Agent ${var.agent_name}"
  )

  lifecycle {
    ignore_changes = [display_name]
  }
}

locals {
  agent_sa_email = (
    contains(var.existing, "agent_sa")
    ? "agent-${var.agent_name}@${var.project_id}.iam.gserviceaccount.com"
    : google_service_account.agent[0].email
  )
}

resource "google_project_iam_member" "agent_roles" {
  for_each = contains(var.existing, "agent_iam") ? toset([]) : toset([
    "roles/aiplatform.user",
    "roles/alloydb.databaseUser",
    "roles/alloydb.client",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/logging.logWriter",
    "roles/cloudtrace.agent",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.agent_sa_email}"
}

# ---- Per-deployment Agent Workspace secrets (when enable_workspace = true) --
resource "random_password" "superuser" {
  count   = var.enable_workspace ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "provisioner" {
  count   = var.enable_workspace ? 1 : 0
  length  = 32
  special = false
}

locals {
  service = "alloydb-agent-workspace-${var.agent_name}"
  secrets = var.enable_workspace ? {
    superuser = {
      id   = "alloydb-agent-superuser-${var.agent_name}"
      data = random_password.superuser[0].result
    }
    provisioner = {
      id   = "alloydb-agent-provisioner-${var.agent_name}"
      data = random_password.provisioner[0].result
    }
    initdb = {
      id   = "alloydb-agent-initdb-${var.agent_name}"
      data = var.initdb_sql
    }
  } : {}
}

resource "google_secret_manager_secret" "secrets" {
  for_each  = local.secrets
  secret_id = each.value.id
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "secrets" {
  for_each    = local.secrets
  secret      = google_secret_manager_secret.secrets[each.key].id
  secret_data = each.value.data
}

resource "google_secret_manager_secret_iam_member" "secret_accessors" {
  for_each  = local.secrets
  secret_id = google_secret_manager_secret.secrets[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.agent_sa_email}"
}

# ---- The Agent Workspace Cloud Run service ----------------------------------
resource "google_cloud_run_v2_service" "db" {
  count               = var.enable_workspace ? 1 : 0
  name                = local.service
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  labels              = { managed-by = "alloydb-agent" }
  deletion_protection = var.deletion_protection

  template {
    service_account  = local.agent_sa_email
    timeout          = "300s"
    session_affinity = true
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }
    vpc_access {
      egress = "ALL_TRAFFIC"
      network_interfaces {
        network    = var.network
        subnetwork = var.subnet
      }
    }

    containers {
      name       = "router"
      image      = var.router_image
      depends_on = ["postgres"]

      ports { container_port = 8080 }

      env {
        name = "PROVISIONER_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["provisioner"].secret_id
            version = "latest"
          }
        }
      }

      resources {
        limits            = { cpu = "2", memory = "4Gi" }
        startup_cpu_boost = true
      }

      startup_probe {
        tcp_socket { port = 8080 }
        period_seconds    = 2
        failure_threshold = 60
      }
    }

    containers {
      name  = "postgres"
      image = var.postgres_image
      args  = ["postgres", "-c", "max_connections=300", "-c", "google_columnar_engine.enabled=off"]

      env {
        name  = "POSTGRES_DB"
        value = "postgres"
      }
      env {
        name  = "POSTGRES_USER"
        value = "pgadmin"
      }
      env {
        name = "POSTGRES_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["superuser"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "PROVISIONER_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["provisioner"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "POSTGRES_INITDB_ARGS"
        value = "--auth-host=scram-sha-256"
      }
      env {
        name  = "PGDATA"
        value = "/pgdata/data"
      }
      env {
        name  = "OMNI_DISABLE_AUTO_EXTENSION_REINSTALL"
        value = "1"
      }

      resources {
        limits            = { cpu = "4", memory = "16Gi" }
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "pgdata"
        mount_path = "/pgdata"
      }
      volume_mounts {
        name       = "initdb"
        mount_path = "/docker-entrypoint-initdb.d"
      }

      startup_probe {
        tcp_socket { port = 5432 }
        period_seconds    = 2
        failure_threshold = 30
      }
    }

    volumes {
      name = "initdb"
      secret {
        secret = google_secret_manager_secret.secrets["initdb"].secret_id
        items {
          version = "latest"
          path    = "provisioner.sql"
        }
      }
    }

    volumes {
      name = "pgdata"
      empty_dir {
        medium     = "MEMORY"
        size_limit = "8Gi"
      }
    }
  }

  depends_on = [
    google_project_iam_member.agent_roles,
    google_secret_manager_secret_iam_member.secret_accessors,
    google_secret_manager_secret_version.secrets,
  ]
}

# ---- Static IAM on the service ----------------------------------------------
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  count    = var.enable_workspace ? 1 : 0
  name     = google_cloud_run_v2_service.db[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${local.agent_sa_email}"
}

