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

