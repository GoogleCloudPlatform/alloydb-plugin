---
name: alloydb-express
description: >-
  Provisions AlloyDB Express clusters and 1-vCPU ZONAL primary instances for
  rapid, low-cost non-production PostgreSQL 18 workloads over Private Service
  Connect (PSC) or Public DNS, with scale-to-zero cost optimization. Use when
  the user asks to spin up a quick prototype, build a proof of concept (POC),
  try out a feature in a sandbox, or set up a development or staging AlloyDB
  database while minimizing compute costs or avoiding an always-on cluster.
  Don't use for production workloads requiring REGIONAL availability type, read
  pools, continuous backup or point-in-time recovery, CMEK, VPC peering,
  instances over 2 vCPUs, storage over 20 GB, inspecting existing clusters or
  instances, or querying and indexing tables.
metadata:
  lifecycle: preview
---

# AlloyDB Express: Rapid Non-Production Bootstrapping

Fast-starting, non-production AlloyDB for PostgreSQL (`1` vCPU, `4 GB` RAM,
scale-to-zero after 15 minutes idle). Substitute `{project_id}`, `{region}`,
`{cluster_id}`, and `{instance_id}` with user identifiers.

## 1. Prerequisites & Limits

Item                  | AlloyDB Express Requirement
--------------------- | ---------------------------
Supported regions     | `us-west1`, `europe-west2`, `asia-east1`, `asia-east2`, `asia-northeast1`, `asia-southeast1`, `australia-southeast1`
PostgreSQL version    | `POSTGRES_18` (PostgreSQL 18) only
Initial machine size  | `1` vCPU (`4 GB` RAM) at creation
Availability type     | `ZONAL` only (`REGIONAL` availability type and read pools unsupported)
Storage & connections | Up to 20 GB storage; `max_connections` fixed at `200`
Networking            | Private Service Connect (PSC) and/or Public DNS; no VPC peering

## 2. Core Provisioning Workflow

-   [ ] **Step 1 - Create the AlloyDB Express Cluster (IAM-Only Default)**:
    Provision `{cluster_id}` in `{project_id}` / `{region}` with Express enabled
    (skip pre-listing clusters or web searches). Default to IAM database
    authentication by omitting an initial `postgres` password. Never ask for,
    generate, or read plaintext passwords in prompts or environment variables;
    if a user explicitly wants to create a cluster with an initial postgres user
    password, then output the command to do so with a placeholder for password
    and instruct them to fill in the placeholder and run the command in their
    terminal, then resume at Step 2. **Wait for cluster creation to finish**
    before creating the primary instance.
-   [ ] **Step 2 - Create the 1-vCPU Zonal Primary Instance**: Provision
    `{instance_id}` in `{cluster_id}` as a `1`-vCPU `ZONAL` `PRIMARY` instance
    (no `2+` vCPUs, `REGIONAL` availability type, dedicated machine types, or
    raw IPv4 Public IP). PSC is enabled on the cluster by default and Public DNS
    is off unless requested:

    -   **Public DNS only**: Enable Public DNS for external/local access outside
        a VPC. Public DNS rejects direct client IPs by default: allowlist only
        user-specified IPv4 CIDRs upon explicit request (`{cidr_range}`, never
        `0.0.0.0/0`) for direct clients, or connect via AlloyDB Auth Proxy /
        Language Connectors without allowlisting CIDRs.
    -   **PSC only**: Leave Public DNS off and allowlist only explicitly
        requested consumer project IDs (`{allowed_project_id}`).
    -   **Both Public DNS and PSC**: Enable Public DNS and allowlist only
        explicitly requested IPv4 CIDRs (`{cidr_range}`, never `0.0.0.0/0`) or
        consumer project IDs.

    If connectivity (or required PSC projects / direct-client CIDRs) is
    unspecified, ask first (for local/public access without a CIDR, enable
    Public DNS with no open CIDRs). **Wait for instance creation** before
    reading attributes.
-   [ ] **Step 3 - Report Created Resource Attributes**: Read cluster and
    instance metadata and report:

    -   PostgreSQL version
    -   vCPU Count
    -   Availability Type
    -   Public DNS Name (if applicable)

## 3. Gotchas & Common Failure Modes

-   **`only cpu_count of 1 is supported`**: Initial primary creation supports
    `1` vCPU only.
-   **Dedicated machine types or `REGIONAL` rejected**: Use `1` vCPU and `ZONAL`
    instead of machine types (eg `n2-highmem-2`) or `REGIONAL`.
-   **Raw IPv4 Public IP rejected**: Use **Public DNS** and/or **PSC** instead.
-   **Direct Public DNS connections rejected**: Allowlist only user-specified
    IPv4 CIDRs upon explicit request (updates overwrite the full list;
    `0.0.0.0/0` disallowed), or use Auth Proxy (`--public-ip`) / Language
    Connectors.
-   **Triage & scaling**: Read
    [references/troubleshooting.md](references/troubleshooting.md) only on
    creation errors or scaling questions.

## Tooling (Optional)

-   **With AlloyDB remote MCP server tools** (server `alloydb`; camelCase JSON):

    1.  Call `alloydb:create_cluster` (IAM-only), poll `alloydb:get_operation`
        until `"done": true`, and read `databaseVersion`:

        ```json
        {"parent": "projects/{project_id}/locations/{region}", "clusterId": "{cluster_id}", "expressConfig": {"enabled": true}}
        ```

    2.  Call `alloydb:create_instance` matching Step 2
        (`"publicDnsEnabled": true`, `"pscInstanceConfig":
        {"allowedConsumerProjects": ["{allowed_project_id}"]}`, or both; add
        `"authorizedExternalNetworks": ["{cidr_range}"]` only for direct-client
        CIDRs explicitly provided by the user), poll `alloydb:get_operation`
        until `"done": true`, and read `machineConfig.cpuCount`,
        `availabilityType`, and `networkInfo.publicDnsName`:

        ```json
        {"parent": "projects/{project_id}/locations/{region}/clusters/{cluster_id}", "instanceId": "{instance_id}", "type": "PRIMARY", "cpuCount": 1, "publicDnsEnabled": true}
        ```

-   **Without MCP (`v1beta` REST + `gcloud beta alloydb` CLI)**: Create an
    IAM-only Express cluster via `v1beta` REST (if the user wants an initial
    `postgres` user password, output `gcloud beta alloydb clusters create
    {cluster_id} --region={region} --project={project_id} --enable-express
    --password='<YOUR_PASSWORD>'` to their terminal and instruct them to fill in
    the placeholder and run it), poll `clusters describe` until
    `"state": "READY"`, then create (omit `--async`; add
    `--authorized-external-networks={cidr_range}` only for direct-client CIDRs
    explicitly provided by the user) and describe the instance:

    ```bash
    curl -sS --proto-default https -X POST \
      "alloydb.googleapis.com/v1beta/projects/{project_id}/locations/{region}/clusters?clusterId={cluster_id}" \
      -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null || gcloud auth application-default print-access-token)" \
      -H "X-Goog-User-Project: {project_id}" \
      -H "Content-Type: application/json" \
      -d '{"expressConfig": {"enabled": true}}'
    gcloud beta alloydb clusters describe {cluster_id} \
      --region={region} --project={project_id} --format=json

    # Public DNS only:
    gcloud beta alloydb instances create {instance_id} \
      --cluster={cluster_id} --region={region} --project={project_id} \
      --instance-type=PRIMARY --cpu-count=1 --enable-public-dns

    # PSC only:
    gcloud beta alloydb instances create {instance_id} \
      --cluster={cluster_id} --region={region} --project={project_id} \
      --instance-type=PRIMARY --cpu-count=1 --allowed-psc-projects={allowed_project_id}

    # Both Public DNS and PSC:
    gcloud beta alloydb instances create {instance_id} \
      --cluster={cluster_id} --region={region} --project={project_id} \
      --instance-type=PRIMARY --cpu-count=1 --enable-public-dns \
      --allowed-psc-projects={allowed_project_id}

    gcloud beta alloydb instances describe {instance_id} \
      --cluster={cluster_id} --region={region} --project={project_id} --format=json
    ```
