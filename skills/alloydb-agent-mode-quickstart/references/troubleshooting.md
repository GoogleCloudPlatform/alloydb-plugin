# Troubleshooting

## Where the errors are

-   **The agent's logs** (MCP connection failures, tool errors):

    ```bash
    gcloud logging read 'resource.type="aiplatform.googleapis.com/ReasoningEngine"
        AND resource.labels.reasoning_engine_id="<ENGINE_ID>"' \
        --project=<PROJECT> --freshness=1h --limit=50 \
        --format='value(timestamp,severity,textPayload,jsonPayload.message)'
    ```

    These lines are expected and harmless: `[EXPERIMENTAL] feature
    FeatureName.PLUGGABLE_AUTH is enabled` and `..._MCP_MODERN_PROTOCOL is
    enabled`.
-   **The Agent Workspace service** (when `agent.workspace: true`): `gcloud run
    services logs read alloydb-agent-workspace-<name> --project=<PROJECT>
    --region=<REGION>`. Look for `isolation-self-check` and `[agent-workspace]
    provisioned|released|reaped`.

## Agent pool (capability 1)

-   **Pool create fails with `unsupported instanceType`:** The project is not
    enrolled in the PostgreSQL for agents Preview yet; ask the user to request
    access with the form at https://forms.gle/suyoiGCYdrhsqrR28.
-   **Pool create fails with `FAILED_PRECONDITION` about agent mode:** Agent
    mode is not `ACTIVE` yet; wait for P.2 and retry.
-   **Agent mode stays `PROVISIONING` far beyond its usual time:** Background
    provisioning does not retry; run `gcloud beta alloydb clusters update
    <CLUSTER> --project=<PROJECT> --region=<REGION> --enable-agent-mode` to
    retry synchronously.
-   **Primary create fails with `does not have enough resources available`:**
    Transient zone capacity issue (`REGIONAL` requires two zones). Ask the user,
    then retry with `--availability-type=ZONAL` and `--cpu-count=2`, or another
    region; never retry in an unattended loop.
-   **`No more than 1 Agent Pool instance is supported per cluster` (or
    `internal error` right after deleting a pool):** Only one pool per cluster
    is allowed, and a deleted pool still counts until backend cleanup finishes;
    use a new cluster or wait.
-   **No `sca-auto-fr-…` forwarding rule after the pool is `READY`:** Missing
    service connection policy or wrong `--service-class` (P.4:
    `google-cloud-alloydb`). Verify with `gcloud compute forwarding-rules list
    --project=<PROJECT> --filter='network~/<VPC>$'`.
-   **Endpoint exists but no `alloydb.goog.` DNS zone (`Name or service not
    known`):** `dns.googleapis.com` was off when the pool was created and is
    never backfilled. Check `gcloud dns managed-zones list --project=<PROJECT>`;
    recreate on a new cluster with DNS enabled, or create the private zone and
    `A` record manually.
-   **Deploy fails with `could not resolve agentPoolInfo.dnsName`:** Wrong
    `database.cluster`/`instance`/region, or the pool is not `READY` yet (P.6).

## Deploying the agent (steps 2 and 3)

-   **Deploy fails after ~4 min with `NOT_FOUND` on `networkAttachments`:** The
    attachment in `vpc.network_attachment` does not exist; re-run Step 2 and
    verify with `gcloud compute network-attachments describe <name>
    --project=<PROJECT> --region=<REGION>`.
-   **Deploy fails with `Required 'compute.networkAttachments.get' permission`
    or `Permission denied when creating DNS peering zone`:** Vertex AI service
    agent lacks `roles/compute.networkAdmin` or `roles/dns.peer`; re-run Step 2.
-   **Runtime fails to unpickle or has import errors:** Local virtualenv does
    not match pinned runtime packages; re-run `bootstrap_env.sh` and deploy only
    with `./.venv/bin/python`.

## Tool calls against the pool (step 4)

-   **`AlloyDB IAM user authentication failed`:** Agent SA lacks
    `roles/serviceusage.serviceUsageConsumer` or `roles/alloydb.databaseUser`;
    re-run Step 2 and wait a few minutes for IAM propagation.
-   **401/403 on every primary call:** Missing `IAM_BASED` database user, or the
    primary lacks `alloydb.iam_authentication=on`; re-run Step 2 and check the
    primary's database flags.
-   **`pg_hba.conf rejects connection`:** The IAM database user has
    `alloydbsuperuser` or another admin role; reset roles with `gcloud alloydb
    users set-roles agent-<name>@<PROJECT>.iam --cluster=<CLUSTER>
    --region=<REGION> --project=<PROJECT>
    --db-roles=alloydbiamuser,pg_read_all_data` (`set-roles` replaces the full
    set, so always include `alloydbiamuser`).

## Agent Workspace (when `agent.workspace: true`)

-   **401/403 on workspace `/mcp`:** Agent SA lacks `roles/run.invoker` on
    `alloydb-agent-workspace-<name>`; re-run Step 2.
-   **`this session has no scratch database`:** Session never provisioned one,
    released it, was TTL-reaped, or the Cloud Run instance restarted (wiping
    in-memory state); the agent re-provisions and rebuilds automatically.
-   **`capacity: N active databases`:** `max_active_dbs` reached; release
    finished sessions or wait for the TTL reaper.
-   **Router restart loop:** `isolation-self-check` failed at startup (fails
    closed by design); inspect Cloud Run logs and do not bypass the check.
-   **Timeouts reaching the workspace:** PSC endpoint or private `run.app` DNS
    zone is missing; re-run Step 2.

## Gemini Enterprise (step 5)

-   **`404` from Discovery Engine:** Regional location used in the URL; Gemini
    Enterprise apps live in `locations/global` (`register` uses `global`).
-   **Colleagues cannot see the registered agent:** Scope was narrowed in the
    console; re-run `deploy_agent.py register` to patch `sharingConfig.scope`
    back to `ALL_USERS`.
-   **User cannot open the Gemini Enterprise app UI:** User lacks an assigned
    Gemini Enterprise seat license (not a deployment failure; assign a license
    in Console → Gemini Enterprise → Manage users).
