output "agent_sa" {
  value       = local.agent_sa_email
  description = "Runtime service account email for the deployment."
}

output "agent_workspace_url" {
  value       = var.enable_workspace ? google_cloud_run_v2_service.db[0].uri : ""
  description = "Cloud Run URL of the Agent Workspace service (empty when enable_workspace is false)."
}

output "service_name" {
  value = var.enable_workspace ? google_cloud_run_v2_service.db[0].name : ""
}

output "existing" {
  value       = var.existing
  description = "Pre-existing resource keys reused without Terraform ownership."
}

