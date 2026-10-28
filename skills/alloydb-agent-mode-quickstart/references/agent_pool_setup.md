# Step P — Provision an AlloyDB agent pool (capability 1)

Both agent tiers read one existing AlloyDB **agent pool**: an `AGENT_POOL`
instance that runs an MCP server (`get_schema`, `execute_sql_read_only`) on its
own nodes, apart from the primary's transactional workload. This file creates
one, either on a **new** cluster or by enabling agent mode on the user's
**existing** cluster. It can be the user's whole request. If the user already
has a pool in `READY`, skip this file and go to
[the hand-off](#hand-off-to-the-workflow).

These are plain `gcloud` commands, not scripts. Once the user provides the
settings below, briefly explain the provisioning sequence and total expected
time (~15–30 min), then run the commands one at a time—explaining what each step
does and how long it takes before running it—and stop on any failure. Everything
after the pool (service account, network attachment, agent code, deploy, test,
publish) is handled by the workflow steps in [SKILL.md](../SKILL.md).

## Ask the user first

Collect any missing values in a single plain-text reply and **end your turn** to
wait for the user's answer (never invent resource names, passwords, or network
settings if an interactive question tool is skipped):

-   **New or existing cluster:** create a new cluster, or enable agent mode on
    one the user already runs (P.2b, which skips `<DB_PASSWORD>` and P.3).
-   **`<PROJECT>`:** GCP project for the cluster, pool, and agent (`project_id`
    in the config, e.g. `my-project`).
-   **`<REGION>`:** GCP region for all resources (`region` in the config, e.g.
    `us-central1`).
-   **`<CLUSTER>`:** AlloyDB cluster ID (`database.cluster`, e.g.
    `cluster-demo`).
-   **`<PRIMARY>`:** primary instance ID (e.g. `primary-demo`). For a new
    cluster, also ask for its size (`<CPU_COUNT>`, `<AVAILABILITY>`): `8` and
    `REGIONAL` for production, or `2` and `ZONAL` for a trial.
-   **`<POOL>`:** agent pool instance ID (`database.instance`, e.g.
    `pool-demo`).
-   **`<DB_PASSWORD>` (new cluster only):** initial `postgres` password.
-   **`<VPC>` and `<SUBNET>`:** dedicated network and subnet (`vpc.network` and
    `vpc.subnet`, e.g. `agents-vpc`, `agents-subnet`).

## Ordering rules (hard to fix afterwards)

1.  **Cloud DNS API on before the pool.** The pool's PSC automation creates
    the private `alloydb.goog.` zone only if `dns.googleapis.com` is already
    enabled, and it never backfills the zone. A pool created without it reports
    `READY`, but its hostname never resolves.
2.  **VPC, subnet, and service connection policy before the pool.** The pool
    names its consumer network at create time, and that can't be changed. A
    wrong network means deleting the pool.
3.  **Agent mode `ACTIVE` before the pool.** Until then the pool create fails
    with `FAILED_PRECONDITION`.
4.  **One pool per cluster, and no quick recreate.** A deleted pool still
    counts for a while. To rebuild, use a new cluster (or wait).

## P.1 Enable the APIs

```bash
gcloud services enable alloydb.googleapis.com compute.googleapis.com \
    servicenetworking.googleapis.com networkconnectivity.googleapis.com \
    dns.googleapis.com aiplatform.googleapis.com storage.googleapis.com \
    iam.googleapis.com discoveryengine.googleapis.com \
    --project=<PROJECT>
```

Step 2 (`deploy_infra.py`) enables the rest it needs. `dns.googleapis.com` is
the one that must be on now (rule 1).

## P.2 Create the cluster with agent mode, and its primary

Run the cluster create first and wait for it to return exit code `0` before
creating the primary instance (do not background or run them in parallel):

```bash
gcloud beta alloydb clusters create <CLUSTER> \
    --project=<PROJECT> --region=<REGION> \
    --database-version=POSTGRES_18 \
    --password=<DB_PASSWORD> \
    --enable-private-service-connect \
    --enable-agent-mode

gcloud beta alloydb instances create <PRIMARY> \
    --project=<PROJECT> --region=<REGION> --cluster=<CLUSTER> \
    --instance-type=PRIMARY \
    --cpu-count=<CPU_COUNT> --availability-type=<AVAILABILITY> \
    --database-flags=alloydb.iam_authentication=on
```

-   `--enable-agent-mode` exists only in `beta`/`alpha`. An "unrecognized
    arguments" error means `gcloud components update`.
-   `alloydb.iam_authentication=on` is what lets the agent log in as its
    service account. Step 2 creates that `IAM_BASED` database user.
-   Agent mode provisions in the background and stays `PROVISIONING` until the
    primary is `READY`, then typically takes another ~10–20 min. Do P.4 while
    waiting, then check:

```bash
gcloud beta alloydb clusters describe <CLUSTER> \
    --project=<PROJECT> --region=<REGION> \
    --format='value(agentModeInfo.state)'      # wait for ACTIVE
```

## P.2b Or: enable agent mode on an existing cluster

Use this instead of P.2 when the user already runs an AlloyDB cluster. It is a
live operation: the primary stays online, with no restart and no dropped
connections.

```bash
gcloud beta alloydb clusters update <CLUSTER> \
    --project=<PROJECT> --region=<REGION> \
    --enable-agent-mode
```

-   Then wait for `agentModeInfo.state` = `ACTIVE` with the same `describe`
    as in P.2, and do P.4 meanwhile.
-   The agent logs in as its service account, so the primary needs
    `alloydb.iam_authentication=on`. Check its flags first (`gcloud alloydb
    instances describe <PRIMARY> --project=<PROJECT> --region=<REGION>
    --cluster=<CLUSTER> --format='value(databaseFlags)'`). If the flag is
    missing, **ask before adding it**: `--database-flags` on `instances update`
    replaces the whole flag set, so pass the existing flags too, and the update
    may restart the primary.
-   Skip P.3; the user's own database becomes `database.database`.

## P.3 Load data (optional)

A new cluster starts with an empty `postgres` database, which is enough to
provision the pool and pass Step 4 (`deploy_agent.py validate`). Skip this step
unless the user wants to load SQL data now.

To import a `.sql` or `.sql.gz` file from Cloud Storage once `<PRIMARY>` is
`READY` and no other cluster operation is running (for example, after P.6):

```bash
gcloud alloydb clusters import <CLUSTER> \
    --project=<PROJECT> --region=<REGION> \
    --database=postgres --user=postgres \
    --gcs-uri=gs://<BUCKET>/<FILE>.sql \
    --sql
```

-   For a private bucket, grant `roles/storage.objectViewer` on `gs://<BUCKET>`
    to `service-<PROJECT_NUMBER>@gcp-sa-alloydb.iam.gserviceaccount.com` first.
-   `gcloud` has no `alloydb databases create` command. Pass
    `--database=postgres` when the SQL file creates and switches to its own
    database (`COMMIT;` first to exit `clusters import`'s implicit transaction,
    then `CREATE DATABASE` and `\connect <DB>`), or create `<DB>` in **AlloyDB
    Studio** first and pass `--database=<DB>`.

## P.4 Prepare the network

Use a dedicated network, not `default`. Step 2 reuses this VPC and subnet and
adds the network attachment to the same subnet, which puts the Agent Engine
runtime and the pool's endpoint on one network. Run the network create in the
foreground and wait for it to return exit code `0` before creating the subnet
(never background or run them in parallel):

```bash
gcloud compute networks create <VPC> \
    --project=<PROJECT> --subnet-mode=custom

# Wait for the network create above to exit 0; the subnet create fails with
# resourceNotReady if started while the network is still provisioning.
gcloud compute networks subnets create <SUBNET> \
    --project=<PROJECT> --region=<REGION> \
    --network=<VPC> --range=10.20.0.0/24
```

No firewall rules are needed: the agent opens outbound connections only.

Then let AlloyDB place the pool's PSC endpoint in that subnet, and confirm the
policy exists:

```bash
gcloud network-connectivity service-connection-policies create alloydb-agents-<VPC> \
    --project=<PROJECT> --region=<REGION> \
    --service-class=google-cloud-alloydb \
    --network=<VPC> --subnets=<SUBNET> \
    --psc-connection-limit=10

gcloud network-connectivity service-connection-policies list \
    --project=<PROJECT> --region=<REGION>
```

A policy naming the wrong service class is ignored without any error: no
endpoint gets created, the same as having no policy.

## P.5 Create the agent pool

```bash
gcloud beta alloydb instances create <POOL> \
    --project=<PROJECT> --region=<REGION> --cluster=<CLUSTER> \
    --instance-type=AGENT_POOL \
    --agent-pool-min-size=1 \
    --agent-pool-max-size=3 \
    --psc-auto-connections=project=<PROJECT>,network=projects/<PROJECT>/global/networks/<VPC>
```

-   The pool autoscales between `min` and `max` nodes.
-   `--psc-auto-connections` is required. It creates the PSC endpoint and the
    private DNS record, and without it the pool is unreachable.
-   The pool reports `READY` only after the endpoint exists and the DNS record
    is published, typically ~2–3 min after the create starts.

## P.6 Confirm the hostname

```bash
gcloud beta alloydb instances describe <POOL> \
    --project=<PROJECT> --region=<REGION> --cluster=<CLUSTER> \
    --format="yaml(state, agentPoolInfo.dnsName)"
```

Expect `state: READY` and a `dnsName` shaped
`<instance-uid>.<cluster-uid>.<REGION>.alloydb.goog.`. You don't need to copy
it. The deploy scripts resolve it from `database.cluster` + `database.instance`.
Use `beta`: GA `gcloud` doesn't return `agentPoolInfo`. If the hostname won't
resolve later, see
[troubleshooting.md](troubleshooting.md#agent-pool-capability-1).

## Hand off to the workflow

If the user only wanted the pool, stop here and report its `dnsName` (the MCP
endpoint is `https://<dnsName>/mcp`). Otherwise, continue with Step 0 and Step 1
in [SKILL.md](../SKILL.md): generate `./<name>.alloydb-agent.yaml` in the
current working directory (from
[assets/example.alloydb-agent.yaml](../assets/example.alloydb-agent.yaml))
pre-filled with `project_id: <PROJECT>`, `region: <REGION>`, `vpc.network:
<VPC>`, `vpc.subnet: <SUBNET>`, `database.cluster: <CLUSTER>`, and
`database.instance: <POOL>`.
