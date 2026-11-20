# AlloyDB Express Troubleshooting & Lifecycle Reference

Read this reference only when troubleshooting an API/creation error or when the
user asks about scale-to-zero behavior, scaling to 2 vCPUs, or upgrading an
AlloyDB Express cluster to Standard Edition.

## 1. Error Triage & Resolution

Error Message / Code                                  | Root Cause                                                                        | Resolution
----------------------------------------------------- | --------------------------------------------------------------------------------- | ----------
`INVALID_ARGUMENT: only cpu_count of 1 is supported`  | Requested `2+` vCPUs at initial instance creation (or used a multi-vCPU default). | Specify `1` vCPU at initial instance creation (Express defaults an omitted API `cpuCount` to `1`, while CLI flags require specifying `1` vCPU explicitly).
`INVALID_ARGUMENT` on `machineType`                   | Passed a dedicated machine type string (eg `n2-highmem-2`) on Express.            | Remove `machineType` and specify `"cpuCount": 1` instead.
`INVALID_ARGUMENT` on `REGIONAL` `availabilityType`   | Requested regional high availability on an AlloyDB Express instance.              | Use `"availabilityType": "ZONAL"` (or omit `availabilityType`, which defaults to `ZONAL` on Express).
`INVALID_ARGUMENT` on `READ_POOL` `instanceType`      | Attempted to create a read pool instance inside an AlloyDB Express cluster.       | Only a single `PRIMARY` instance is supported on AlloyDB Express.
`INVALID_ARGUMENT` on `enablePublicIp`                | Requested raw IPv4 public IP assignment on an AlloyDB Express instance.           | Configure Public DNS (`"publicDnsEnabled": true` in `networkConfig`) and/or Private Service Connect (`pscInstanceConfig.allowedConsumerProjects`) instead of `enablePublicIp`.
Direct connection refused / timeout over Public DNS   | Public DNS endpoint rejects all direct client IP addresses by default.            | Allowlist only user-specified IPv4 CIDR blocks upon explicit request in authorized external networks (each update replaces the full list; `0.0.0.0/0` is disallowed), or connect via AlloyDB Auth Proxy (`--public-ip`) / Language Connectors.
`INVALID_ARGUMENT` on unsupported region              | Requested cluster creation in a region outside the Express preview list.          | Provision in a supported AlloyDB Express region.
`FAILED_PRECONDITION: Cluster is not ready`           | Submitted primary instance creation before the cluster operation finished.        | Wait for the cluster creation long-running operation to reach `"done": true` before creating the primary instance.
`ALREADY_EXISTS` on `{cluster_id}` or `{instance_id}` | Target resource already exists in `{project_id}` / `{region}`.                    | Inspect the existing resource attributes (`databaseVersion`, `cpuCount`, `availabilityType`, and `publicDnsName` if applicable) and report them if they match the requested Express configuration.

## 2. Scale-to-Zero & Post-Creation Scaling

-   **Automatic scale-to-zero**: AlloyDB Express automatically pauses compute
    after 15 minutes of zero active database connections, reducing compute
    charges to zero while preserving up to 20 GB of storage. When a new client
    connection arrives, compute resumes in under two seconds.
-   **Scaling from 1 vCPU to 2 vCPUs**: Although initial primary instance
    creation requires `"cpuCount": 1`, an existing `READY` AlloyDB Express
    primary instance can be updated post-creation to `"cpuCount": 2` (8 GB RAM).
-   **Upgrading to Standard Edition**: To use `REGIONAL` high availability, read
    pool instances, `>2` vCPUs, `>20 GB` storage, continuous backup / PITR, or
    CMEK, upgrade the cluster from AlloyDB Express to AlloyDB Standard Edition.
