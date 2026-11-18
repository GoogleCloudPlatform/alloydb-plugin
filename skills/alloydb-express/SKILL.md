---
name: alloydb-express
description: >-
  Provisions AlloyDB Express clusters and 1-vCPU ZONAL primary instances for
  rapid, low-cost non-production PostgreSQL 18 workloads over Private Service
  Connect (PSC) or Public DNS, with scale-to-zero cost optimization. Use when
  the user asks to spin up a quick prototype, build a proof of concept (POC),
  try out a feature in a sandbox, or set up a development or staging AlloyDB
  database while minimizing compute costs or avoiding an always-on cluster.
  Don't use for production workloads requiring REGIONAL failover, read pools,
  continuous backup or point-in-time recovery, CMEK, VPC peering, instances
  over 2 vCPUs, storage over 20 GB, inspecting existing clusters or instances,
  or querying and indexing tables.
metadata:
  lifecycle: preview
---

# AlloyDB Express: Rapid Non-Production Bootstrapping

AlloyDB Express is a fast-starting, cost-optimized edition of AlloyDB for
PostgreSQL for non-production prototypes, POCs, sandboxes, and feature testing.
It provisions in seconds, starts at 1 vCPU (4 GB RAM), and scales compute to
zero after 15 minutes idle. Replace `{project_id}`, `{region}`, `{cluster_id}`,
and `{instance_id}` with the user's identifiers.

## 1. Prerequisites & Limits

Item                  | AlloyDB Express Requirement (as of 2026-11-11)
--------------------- | ----------------------------------------------
Supported regions     | `us-west1`, `europe-west2`, `asia-east1`, `asia-east2`, `asia-northeast1`, `asia-southeast1`, `australia-southeast1`
PostgreSQL version    | `POSTGRES_18` (PostgreSQL 18) only
Creation machine size | `1` vCPU (`4 GB` RAM) at initial primary instance creation
Availability type     | `ZONAL` only (`REGIONAL` failover and read pools unsupported)
Storage & connections | Up to 20 GB storage; `max_connections` fixed at `200`
Networking            | Private Service Connect (PSC) and/or Public DNS; no VPC peering

## 2. Core Provisioning Workflow

-   [ ] **Step 1 - Create the AlloyDB Express Cluster**: Provision cluster
    `{cluster_id}` in `{project_id}` / `{region}` with AlloyDB Express enabled
    (skip pre-listing clusters or web searches). AlloyDB remote MCP server tools
    use IAM database authentication without an initial password. If falling back
    to the CLI (eg when the remote MCP server is not configured) and the user
    has not provided an initial `postgres` password, ask the user for one -
    never decide, generate, or read environment variables for a password. **Wait
    for cluster creation to finish** before creating the primary instance.
-   [ ] **Step 2 - Create the 1-vCPU Zonal Primary Instance**: Provision
    `{instance_id}` in `{cluster_id}` as a `1`-vCPU `ZONAL` `PRIMARY` instance
    (no `2+` vCPUs, `REGIONAL` availability, dedicated machine types, or raw
    IPv4 Public IP). Match connectivity to the user's access needs (programmatic
    MCP and CLI calls enable PSC on the cluster by default and leave Public DNS
    off unless requested):

    -   **Public DNS only**: Enable Public DNS for external or local-machine
        connections outside a VPC.
    -   **Private Service Connect (PSC) only**: Leave Public DNS off and
        allowlist consumer project IDs (`{allowed_project_id}`) for private VPC
        endpoints.
    -   **Both Public DNS and PSC**: Enable Public DNS and allowlist consumer
        project IDs when both external and private VPC access are needed.

    If the user has not specified public/local vs. private VPC access (and any
    PSC consumer project IDs), ask to confirm (combining with any CLI password
    prompt in a single message) before creating resources. **Wait for instance
    creation to finish** before reading its attributes.
-   [ ] **Step 3 - Report Created Resource Attributes**: Read the cluster and
    instance metadata and include these expected fields in your final response:

    -   PostgreSQL version
    -   vCPU Count
    -   Availability Type
    -   Public DNS Name (if applicable)

## 3. Gotchas & Common Failure Modes

-   **`only cpu_count of 1 is supported`**: Initial primary creation supports
    `1` vCPU only; never request `2+` vCPUs.
-   **Dedicated machine types or `REGIONAL` availability rejected**: Express
    rejects machine type strings (eg `n2-highmem-2`) and `REGIONAL` failover;
    configure `1` vCPU and `ZONAL` availability.
-   **Raw IPv4 Public IP rejected**: Express disallows raw public IPv4; use
    **Public DNS** and/or **PSC** instead.
-   **`password complexity is not met`**: Express enforces
    `password.enforce_complexity = on`; if a user-provided CLI password fails,
    ask the user for `8+` chars with uppercase, lowercase, digit, and special
    char (`!`, `@`, `#`, `$`).
-   **Extended error triage & post-creation scaling**: Only read
    [references/troubleshooting.md](references/troubleshooting.md) on creation
    errors or post-creation scaling questions.

## Tooling (Optional)

-   **With AlloyDB remote MCP server tools** (server `alloydb`; camelCase JSON):

    1.  Call `alloydb:create_cluster`:

        ```json
        {"parent": "projects/{project_id}/locations/{region}", "clusterId": "{cluster_id}", "expressConfig": {"enabled": true}}
        ```

        Poll `alloydb:get_operation` until `"done": true` and read
        `databaseVersion` from the cluster response.

    2.  Call `alloydb:create_instance` with connectivity matching Step 2
        (`"publicDnsEnabled": true` for Public DNS, and/or `"pscInstanceConfig":
        {"allowedConsumerProjects": ["{allowed_project_id}"]}` for PSC):

        ```json
        {"parent": "projects/{project_id}/locations/{region}/clusters/{cluster_id}", "instanceId": "{instance_id}", "type": "PRIMARY", "cpuCount": 1, "publicDnsEnabled": true}
        ```

        Poll `alloydb:get_operation` until `"done": true`, then read
        `machineConfig.cpuCount`, `availabilityType`, and (when enabled)
        `networkInfo.publicDnsName` from the instance response.

-   **With `gcloud beta alloydb` CLI**: Pass `{password}` provided by the user
    (never generated or read from environment variables; the user may also run
    `clusters create` in their own terminal). Omit `--async` (use
    `--enable-public-dns` and/or `--allowed-psc-projects={allowed_project_id}`
    per Step 2):

    ```bash
    gcloud beta alloydb clusters create {cluster_id} \
      --region={region} --project={project_id} \
      --password='{password}' --enable-express && \
    gcloud beta alloydb instances create {instance_id} \
      --cluster={cluster_id} --region={region} --project={project_id} \
      --instance-type=PRIMARY --cpu-count=1 --enable-public-dns && \
    gcloud beta alloydb clusters describe {cluster_id} \
      --region={region} --project={project_id} --format=json && \
    gcloud beta alloydb instances describe {instance_id} \
      --cluster={cluster_id} --region={region} --project={project_id} --format=json
    ```
