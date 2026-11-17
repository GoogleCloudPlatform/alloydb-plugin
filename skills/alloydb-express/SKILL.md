---
name: alloydb-express
description: >-
  Provisions and configures AlloyDB Express clusters and 1-vCPU ZONAL primary
  instances for rapid, low-cost non-production PostgreSQL 18 workloads,
  including public DNS connectivity and scale-to-zero cost optimization. Use
  when the user asks to spin up a quick prototype, build a proof of concept
  (POC), try out or test a feature in a sandbox, or set up a development or
  staging AlloyDB database while minimizing compute costs or avoiding an
  always-on production cluster. Don't use for production workloads requiring
  high availability (REGIONAL failover), read pool instances, continuous backup
  or point-in-time recovery, customer-managed encryption keys (CMEK), VPC
  peering, instances larger than 2 vCPUs, storage exceeding 20 GB, inspecting
  existing clusters or instances, or querying and indexing existing tables.
metadata:
  lifecycle: preview
---

# AlloyDB Express: Rapid Non-Production Bootstrapping

AlloyDB Express is a fast-starting, cost-optimized edition of AlloyDB for
PostgreSQL for non-production workloads (prototypes, POCs, developer sandboxes,
and feature testing). It provisions in under two seconds, starts at 1 vCPU (4 GB
RAM), and scales compute to zero after 15 minutes of inactivity. Replace
`{project_id}`, `{region}`, `{cluster_id}`, and `{instance_id}` with the user's
identifiers.

## 1. Prerequisites & Limits

Item                  | AlloyDB Express Requirement (Checked 2026-11-11)
--------------------- | ------------------------------------------------
Supported regions     | `us-west1`, `europe-west2`, `asia-east1`, `asia-east2`, `asia-northeast1`, `asia-southeast1`, `australia-southeast1`
PostgreSQL version    | `POSTGRES_18` (PostgreSQL 18) only
Creation machine size | `1` vCPU (`4 GB` RAM) at initial primary instance creation
Availability type     | `ZONAL` only (`REGIONAL` failover and read pools are unsupported)
Storage & connections | Up to 20 GB storage; `max_connections` fixed at `200`
Networking            | Private Service Connect + Public DNS (`*.a.{region}.alloydb.s.cloud.goog.`); no VPC peering

## 2. Core Provisioning Workflow

-   [ ] **Step 1 — Create the AlloyDB Express Cluster**: Provision cluster
    `{cluster_id}` in `{project_id}` / `{region}` with AlloyDB Express enabled
    (skip pre-listing clusters or web searches). If an initial `postgres`
    password is needed, use `{password}` or generate a unique random password
    meeting complexity rules (`8+` chars with uppercase, lowercase, digit, and
    special char). **Wait for cluster creation to finish** before creating the
    primary instance.
-   [ ] **Step 2 — Create the 1-vCPU Zonal Primary Instance with Public DNS**:
    Once cluster creation finishes, provision `{instance_id}` in `{cluster_id}`
    as a `1`-vCPU `ZONAL` `PRIMARY` instance (no `2+` vCPUs, `REGIONAL`
    availability, or N2/C4A machine types) with **Public DNS** enabled
    (`*.a.{region}.alloydb.s.cloud.goog.`) rather than raw IPv4 Public IP.
    **Wait for instance creation to finish** before reading its attributes.
-   [ ] **Step 3 — Report All 4 Resource Attributes**: Read these four values
    from the cluster and instance metadata and **always include all four in your
    final response**:

    -   **PostgreSQL version**: `POSTGRES_18`
    -   **vCPU count**: `1` vCPU
    -   **Availability type**: `ZONAL`
    -   **Public DNS name**: `<uuid>.a.{region}.alloydb.s.cloud.goog.`

## 3. Gotchas & Common Failure Modes

-   **`only cpu_count of 1 is supported`**: Initial primary creation supports
    `1` vCPU only -> Specify `1` vCPU (`4 GB` RAM); never request `2+` vCPUs.
-   **Dedicated machine types or `REGIONAL` availability rejected**: Express
    rejects machine type strings (such as `n2-highmem-2`) and `REGIONAL`
    failover -> Configure `1` vCPU and `ZONAL` availability.
-   **Raw IPv4 Public IP rejected**: Express disallows raw public IPv4 -> Enable
    **Public DNS** instead.
-   **`password complexity is not met`**: Express enforces
    `password.enforce_complexity = on` -> Include `8+` chars with uppercase,
    lowercase, digit, and special char (`!`, `@`, `#`, `$`).
-   **Extended error triage & post-creation scaling**: Only read
    [references/troubleshooting.md](references/troubleshooting.md) if creation
    returns an error or the user asks about post-creation scaling.

## Tooling (Optional)

-   **With AlloyDB MCP tools** (OneMCP JSON schema uses camelCase keys):

    1.  Call `create_cluster` with:

        ```json
        {"parent": "projects/{project_id}/locations/{region}", "clusterId": "{cluster_id}", "expressConfig": {"enabled": true}}
        ```

        Poll `get_operation` on the returned operation name until `"done": true`
        and read `databaseVersion` (`POSTGRES_18`) from the cluster response.

    2.  Call `create_instance` with:

        ```json
        {"parent": "projects/{project_id}/locations/{region}/clusters/{cluster_id}", "instanceId": "{instance_id}", "type": "PRIMARY", "cpuCount": 1, "publicDnsEnabled": true}
        ```

        Poll `get_operation` until `"done": true` before reading
        `machineConfig.cpuCount`, `availabilityType`, and
        `networkInfo.publicDnsName` from the instance response.

-   **With `gcloud beta alloydb` CLI**: Pass `{password}` (from
    `ALLOYDB_PASSWORD` or generated via `secrets.token_hex(12) + "Aa1!"` without
    printing to stdout) through a `0600` `mkstemp` `--flags-file` removed in
    `finally` so credentials never leak to stdout, shell expansion, `argv`, or
    disk, then run `instances create` and `instances describe` synchronously (no
    `--async`):

    ```bash
    python3 - <<'PY' && \
    import json, os, secrets, subprocess, tempfile
    fd, path = tempfile.mkstemp(prefix="express_flags_", suffix=".json")
    try:
      pwd = os.environ.get("ALLOYDB_PASSWORD") or (secrets.token_hex(12) + "Aa1!")
      os.write(fd, json.dumps({"--password": pwd}).encode())
      os.close(fd)
      fd = -1
      rc = subprocess.call([
          "gcloud", "beta", "alloydb", "clusters", "create", "{cluster_id}",
          "--region={region}", "--project={project_id}",
          f"--flags-file={path}", "--enable-express",
      ])
    finally:
      if fd >= 0:
        os.close(fd)
      if os.path.exists(path):
        os.remove(path)
    raise SystemExit(rc)
    PY
    gcloud beta alloydb instances create {instance_id} \
      --cluster={cluster_id} --region={region} --project={project_id} \
      --instance-type=PRIMARY --cpu-count=1 --enable-public-dns && \
    gcloud beta alloydb instances describe {instance_id} \
      --cluster={cluster_id} --region={region} --project={project_id} --format=json
    ```

-   **With AlloyDB `v1beta` REST (`curl`)** (pass `Authorization: Bearer` via
    `curl --config -` and any sensitive JSON body via `--data-binary @-` so
    tokens/passwords stay out of `argv`):

    1.  `POST
        /v1beta/projects/{project_id}/locations/{region}/clusters?clusterId={cluster_id}`
        with body `{"expressConfig": {"enabled": true}}` (include
        `"initialUser": {"password": "{password}"}` via stdin only if
        requested), then poll `GET /v1beta/{operation_name}` (`sleep 2`) until
        `"done": true`.
    2.  `POST
        /v1beta/projects/{project_id}/locations/{region}/clusters/{cluster_id}/instances?instanceId={instance_id}`
        with body `{"instanceType": "PRIMARY", "machineConfig": {"cpuCount": 1},
        "networkConfig": {"publicDnsEnabled": true}}`, then poll
        `GET /v1beta/{operation_name}` (`sleep 2`) until `"done": true` and
        print the completed operation JSON to stdout before reporting the
        resource attributes.
