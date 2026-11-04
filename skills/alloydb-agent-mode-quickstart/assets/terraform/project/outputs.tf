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

