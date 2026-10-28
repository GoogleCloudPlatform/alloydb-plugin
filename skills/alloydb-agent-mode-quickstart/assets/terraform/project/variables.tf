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

variable "project_id" {
  type        = string
  description = "GCP project to set up."
}

variable "region" {
  type        = string
  description = "Region for the subnet and the PSC network attachment."
}

variable "network" {
  type        = string
  default     = "agents-vpc"
  description = "VPC name. Databases are reachable ONLY from inside this network."
}

variable "subnet" {
  type        = string
  default     = "agents-subnet"
  description = "Subnet the PSC network attachment binds to."
}

variable "network_attachment" {
  type        = string
  default     = "agents-psc-attachment"
  description = "PSC network attachment: the path Agent Engine takes into the VPC."
}

variable "name_suffix" {
  type        = string
  default     = ""
  description = <<-EOT
    Appended to the project-foundation resources whose names are otherwise fixed
    (PSC address `psc-googleapis`, forwarding rule `pscgapis`, private DNS zone
    `run-app-private`, staging bucket `<project_id>-agent-staging`, and Artifact
    Registry repository `alloydb-agent`). It exists so an isolated deployment
    can be applied and torn down with `--delete-policy=DELETE` in a shared
    project without colliding with or deleting other users' live resources.
  EOT
}

variable "psc_googleapis_ip" {
  type        = string
  default     = "10.10.255.10"
  description = <<-EOT
    RFC1918 address inside the VPC that serves the Google APIs bundle.
    Internal-ingress Cloud Run must be reached at a private address in THIS
    VPC: Agent Engine's PSC interface only routes private ranges through the
    network attachment, so the public PGA VIPs arrive without the VPC's
    identity and internal ingress rejects them (404).
  EOT
}

variable "subnet_cidr" {
  type        = string
  default     = "10.10.0.0/24"
  description = "Primary IPv4 range for the subnet when created by this module."
}

variable "existing" {
  type        = set(string)
  default     = []
  description = "Pre-existing resource keys to reuse without managing in Terraform state."
}
