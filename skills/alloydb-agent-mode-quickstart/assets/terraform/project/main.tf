# =============================================================================
# Shared Google Cloud project foundation for alloydb-agent-mode-quickstart.
#
# Applied by deploy_infra.py through Infrastructure Manager (deployment
# `alloydb-agent-project${var.name_suffix}`), so there is no local state file to
# keep.
#
# Ownership rule ("create-if-missing, delete-only-what-we-created"):
#   - `deploy_infra.py` inspects GCP and the deployment's `existing` output
#     before applying, recording in `var.existing` any resource that already
#     existed before this deployment.
#   - Pre-existing resources have `contains(var.existing, "<key>")` (`count = 0`)
#     and are never imported into Terraform state, so `deployments delete
#     --delete-policy=DELETE` deletes ONLY the resources this deployment
#     created and restores the exact pre-deploy state.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google      = { source = "hashicorp/google", version = "~> 6.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 6.0" }
    time        = { source = "hashicorp/time", version = "~> 0.12" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {}

# ---- APIs -------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "alloydb.googleapis.com",
    "servicenetworking.googleapis.com",
    "run.googleapis.com",
    "compute.googleapis.com",
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudtrace.googleapis.com",
    "dns.googleapis.com",
    "discoveryengine.googleapis.com",
  ])
  service = each.value
  # Tearing down this deployment must not disable APIs project-wide; other
  # things in the project use them.
  disable_on_destroy = false
}

# Enablement is eventually consistent — resources created immediately after can
# still 403. This is the declarative form of the old script's "this can take a
# few minutes".
resource "time_sleep" "apis_ready" {
  depends_on      = [google_project_service.apis]
  create_duration = "60s"
}

locals {
  network_id = (
    contains(var.existing, "vpc")
    ? "projects/${var.project_id}/global/networks/${var.network}"
    : google_compute_network.vpc[0].id
  )
  subnet_id = (
    contains(var.existing, "subnet")
    ? "projects/${var.project_id}/regions/${var.region}/subnetworks/${var.subnet}"
    : google_compute_subnetwork.subnet[0].self_link
  )
  psc_address_id = (
    contains(var.existing, "psc_address")
    ? "projects/${var.project_id}/global/addresses/psc-googleapis${var.name_suffix}"
    : google_compute_global_address.psc_googleapis[0].id
  )
  # A PSC-to-Google-APIs forwarding rule has its own naming rule, stricter than
  # every other resource here: 1-20 characters, lowercase letters and digits
  # ONLY (no hyphens), starting with a letter. Strip and truncate so a suffix
  # cannot produce an invalid name.
  forwarding_rule_name = substr(
    "pscgapis${lower(replace(var.name_suffix, "/[^A-Za-z0-9]/", ""))}", 0, 20
  )
  dns_zone_name = (
    contains(var.existing, "dns_zone")
    ? "run-app-private${var.name_suffix}"
    : google_dns_managed_zone.run_app[0].name
  )
}

# ---- VPC + subnet (created only if missing) ---------------------------------
resource "google_compute_network" "vpc" {
  count                   = contains(var.existing, "vpc") ? 0 : 1
  name                    = var.network
  auto_create_subnetworks = false
  depends_on              = [time_sleep.apis_ready]
}

resource "google_compute_subnetwork" "subnet" {
  count         = contains(var.existing, "subnet") ? 0 : 1
  name          = var.subnet
  network       = local.network_id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
  depends_on    = [time_sleep.apis_ready]
}

# ---- PSC endpoint for Google APIs + private *.run.app -----------------------
# A PSC endpoint for the all-apis bundle serves *.run.app with consumer-VPC
# context; the private zone points *.run.app at it.
resource "google_compute_global_address" "psc_googleapis" {
  count        = contains(var.existing, "psc_address") ? 0 : 1
  name         = "psc-googleapis${var.name_suffix}"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  address_type = "INTERNAL"
  network      = local.network_id
  address      = var.psc_googleapis_ip
  depends_on   = [time_sleep.apis_ready]
}

resource "google_compute_global_forwarding_rule" "psc_googleapis" {
  count      = contains(var.existing, "psc_forwarding_rule") ? 0 : 1
  name       = local.forwarding_rule_name
  target     = "all-apis"
  network    = local.network_id
  ip_address = local.psc_address_id
  # Must be empty for a PSC forwarding rule (not a load balancer).
  load_balancing_scheme = ""
  depends_on            = [time_sleep.apis_ready]
}

resource "google_dns_managed_zone" "run_app" {
  count         = contains(var.existing, "dns_zone") ? 0 : 1
  name          = "run-app-private${var.name_suffix}"
  dns_name      = "run.app."
  description   = "Route *.run.app via the PSC endpoint for internal ingress"
  visibility    = "private"
  force_destroy = true

  private_visibility_config {
    networks {
      network_url = local.network_id
    }
  }

  depends_on = [time_sleep.apis_ready]
}

resource "google_dns_record_set" "run_app_wildcard" {
  count        = contains(var.existing, "dns_record") ? 0 : 1
  name         = "*.run.app."
  managed_zone = local.dns_zone_name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.psc_googleapis_ip]
  depends_on   = [time_sleep.apis_ready]
}

# ---- PSC network attachment (Agent Engine -> internal Cloud Run) ------------
resource "google_compute_network_attachment" "psc" {
  count                 = contains(var.existing, "network_attachment") ? 0 : 1
  provider              = google-beta # beta-only resource
  name                  = var.network_attachment
  region                = var.region
  connection_preference = "ACCEPT_AUTOMATIC"
  subnetworks           = [local.subnet_id]
  depends_on            = [time_sleep.apis_ready]
}

# ---- Vertex AI service agent & Cloud Build ----------------------------------
resource "google_project_service_identity" "aiplatform" {
  provider   = google-beta
  project    = var.project_id
  service    = "aiplatform.googleapis.com"
  depends_on = [time_sleep.apis_ready]
}

resource "google_project_iam_member" "aiplatform_agent" {
  for_each = contains(var.existing, "aiplatform_iam") ? toset([]) : toset([
    "roles/compute.networkAdmin",
    "roles/dns.peer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_project_service_identity.aiplatform.email}"
}

resource "google_project_iam_member" "cloudbuild" {
  for_each = contains(var.existing, "cloudbuild_iam") ? toset([]) : toset([
    "roles/cloudbuild.builds.builder",
    "roles/cloudbuild.builds.editor",
    "roles/storage.admin",
    "roles/artifactregistry.writer",
  ])
  project    = var.project_id
  role       = each.value
  member     = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
  depends_on = [time_sleep.apis_ready]
}

# ---- Shared project storage + container registry ----------------------------
resource "google_storage_bucket" "staging" {
  count                       = contains(var.existing, "staging_bucket") ? 0 : 1
  name                        = "${var.project_id}-agent-staging${var.name_suffix}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  depends_on                  = [time_sleep.apis_ready]

  lifecycle {
    ignore_changes = [location, uniform_bucket_level_access]
  }
}

resource "google_artifact_registry_repository" "alloydb_agent" {
  count         = contains(var.existing, "artifact_repo") ? 0 : 1
  location      = var.region
  repository_id = "alloydb-agent${var.name_suffix}"
  format        = "DOCKER"
  depends_on    = [time_sleep.apis_ready]

  lifecycle {
    ignore_changes = [
      description,
      labels,
      mode,
      docker_config,
      cleanup_policy_dry_run,
    ]
  }
}

