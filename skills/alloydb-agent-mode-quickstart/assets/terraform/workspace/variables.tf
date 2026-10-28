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

variable "project_id" { type = string }
variable "region" { type = string }

variable "agent_name" {
  type        = string
  description = "Deployment name (`name` in *.alloydb-agent.yaml). Selects `agent-<agent_name>` SA and `alloydb-agent-workspace-<agent_name>` Cloud Run service."
}

variable "agent_display_name" {
  type        = string
  default     = ""
  description = "Human-readable display name for the agent runtime service account."
}

variable "enable_workspace" {
  type        = bool
  default     = true
  description = "Whether to deploy the Cloud Run Agent Workspace service and its secrets (`agent_engine.agent.workspace`)."
}

variable "router_image" {
  type        = string
  default     = ""
  description = "Router image BY DIGEST (required when enable_workspace = true)."
}

variable "network" {
  type    = string
  default = "agents-vpc"
}

variable "subnet" {
  type    = string
  default = "agents-subnet"
}

variable "postgres_image" {
  type        = string
  default     = "gcr.io/alloydb-omni/alloydbomni:16"
  description = "Container image for the Scratch DB sidecar."
}

variable "initdb_sql" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Contents of assets/agent_workspace/database/provisioner.sql."
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "existing" {
  type        = set(string)
  default     = []
  description = "Pre-existing resource keys to reuse without managing in Terraform state."
}

