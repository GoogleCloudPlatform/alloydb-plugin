output "network" {
  value       = var.network
  description = "Consumed by the service module as var.network."
}

output "subnet" {
  value       = var.subnet
  description = "Consumed by the service module as var.subnet."
}

output "network_attachment" {
  value       = var.network_attachment
  description = "Config vpc.network_attachment; deploy_agent.py reads it."
}

output "staging_bucket" {
  value       = "gs://${var.project_id}-agent-staging${var.name_suffix}"
  description = "GCS staging bucket URI for Agent Engine deployments."
}

output "existing" {
  value       = var.existing
  description = "Pre-existing resource keys reused without Terraform ownership."
}

