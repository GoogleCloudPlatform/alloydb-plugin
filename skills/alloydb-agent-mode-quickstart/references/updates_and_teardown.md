# Updating an Existing Deployment and Teardown

## Updating in place

Edit `<config_path>` (`./<name>.alloydb-agent.yaml`), validate with
`validate_config.py`, and re-run only the affected steps:

-   **Toggling `agent_engine.agent.workspace` (`false` ↔ `true`):** Re-run Step
    2 (`deploy_infra.py --config <config_path>`), Step 3 (`deploy_agent.py
    deploy --config <config_path>`), and Step 4 (`deploy_agent.py validate
    --config <config_path>`).
-   **Changing `model`, `agent_engine.agent.context` / `display_name`, or
    adding/updating `agent_engine.coordinator`:** Re-run Step 3
    (`deploy_agent.py deploy --config <config_path>`) and Step 4 (`validate`).
    Existing `<name>_agent` and `<name>_swarm_coordinator` engines are updated
    in place with the same resource names.
-   **Changing `gemini_enterprise` (`app_id` or `description`) or switching
    between single agent and coordinator:** Re-run Step 5 (`deploy_agent.py
    register --config <config_path>`).

## Teardown (reverse dependency order)

Before deleting anything, list the exact resources you will delete and wait for
the user's yes, even when the user asked for the teardown: end your turn with
the list. Afterwards, confirm that each one is gone (`TEARDOWN PASS` for step 1,
or a `describe` that returns `NOT_FOUND` for the resource itself) before
reporting the teardown as complete.

1.  **Per-deployment resources (`<name>`):** `deploy_agent.py teardown` finds
    and deletes everything Steps 2–5 created for `<name>`, in dependency order:
    Gemini Enterprise registrations (when `gemini_enterprise.app_id` is set),
    the Agent Engines (`force=True`, which releases the PSC network attachment),
    the per-deployment stack (the SA, its IAM bindings and, with
    `workspace: true`, the Cloud Run service and its secrets), and the AlloyDB
    IAM database user that Step 2 creates outside Terraform.

    First, run the dry-run preview (lists what exists for `<name>` and deletes
    nothing):

    ```bash
    .venv/bin/python "<skill>"/scripts/deploy_agent.py teardown --config <config_path>
    ```

    Show that list to the user and **end your turn** to wait for confirmation.
    Only after the user confirms the list, run the deletion and post-teardown
    verification:

    ```bash
    .venv/bin/python "<skill>"/scripts/deploy_agent.py teardown --config <config_path> --yes
    ```

    It finds the resources by `name`, so a partial deployment or an edited
    config still tears down cleanly, and it never touches the shared foundation,
    the network, the agent pool, or the AlloyDB cluster. It waits for each
    deletion before the next and prints `TEARDOWN PASS` only after checking that
    nothing is left. On `TEARDOWN FAIL`, fix the cause and re-run; finished
    steps are skipped.

2.  **Shared project foundation (`alloydb-agent-project<name_suffix>`, only
    after all per-deployment stacks and Agent Engines are removed):**

    ```bash
    gcloud infra-manager deployments delete \
        projects/<project_id>/locations/<region>/deployments/alloydb-agent-project<name_suffix> \
        --delete-policy=DELETE --quiet
    ```

    `--delete-policy=DELETE` removes **only** the foundation resources created
    by Step 2 while preserving pre-existing VPCs, subnets, buckets, Artifact
    Registry repos, and IAM bindings.

3.  **AlloyDB agent pool (`<pool>`, only if created by Step P):**
    Deleting `<pool>` removes only the `AGENT_POOL` instance (plus its PSC
    endpoint and private `alloydb.goog.` DNS zone) and leaves `<cluster>`,
    `<primary>`, and all user data untouched. **Never delete `<cluster>` or
    `<primary>` as part of agent or agent-pool teardown.**

    First, list the exact Step P resources you plan to delete in your reply and
    **end your turn** to wait for the user's confirmation before running any
    delete command. Once confirmed, run **after** `alloydb-agent-project` is
    deleted:

    ```bash
    gcloud beta alloydb instances delete <pool> \
        --project=<project_id> --region=<region> --cluster=<cluster> --quiet
    ```

    If `<cluster>` is being kept (the normal case), confirm `<pool>` is gone
    (`NOT_FOUND`):

    ```bash
    gcloud beta alloydb instances describe <pool> \
        --project=<project_id> --region=<region> --cluster=<cluster>
    ```

    Deleting a pool blocks creating a new pool on the same cluster until backend
    cleanup completes.

4.  **Optional — Newly created test AlloyDB cluster (`<cluster>`, destructive;
    separate explicit request and confirmation required):**

    > **Warning: permanent data loss.** Deleting `<primary>` and `<cluster>`
    > permanently destroys the primary instance, the cluster, all databases,
    > data, and database users.

    -   **Never touch an existing cluster:** If `<cluster>` already existed
        before Step P (i.e., P.2b was used), **skip this step completely** and
        never propose or run `clusters delete`, even if the user asks to tear
        down everything created by this skill. Leave `<cluster>` and `<primary>`
        untouched and confirm to the user that their cluster was preserved.
    -   **Strict gating for newly created test clusters:** Include this step
        **only** when `<cluster>` was newly created in Step P for a trial
        **and** the user explicitly asks to delete the cluster itself (or to
        delete everything created during that scratch trial). Before running the
        commands, warn the user clearly about permanent data loss on `<cluster>`
        and `<primary>`, name `<primary>` and `<cluster>` explicitly in your
        confirmation list, and **end your turn** to wait for user approval (the
        user can also run the commands without `--quiet` in their own terminal
        if they prefer an interactive prompt).
    -   Once approved, run **after** `<pool>` is deleted (Step 3) and **before**
        deleting `<subnet>` and `<vpc>` (Step 5). Delete `<primary>` first, then
        delete `<cluster>` without `--force` (so cluster deletion fails safely
        if any other instance still exists in `<cluster>`), and verify
        `NOT_FOUND`:

    ```bash
    gcloud beta alloydb instances delete <primary> \
        --project=<project_id> --region=<region> --cluster=<cluster> --quiet

    gcloud beta alloydb clusters delete <cluster> \
        --project=<project_id> --region=<region> --quiet

    gcloud beta alloydb clusters describe <cluster> \
        --project=<project_id> --region=<region>
    ```

5.  **Optional — Dedicated Step P network (`alloydb-agents-<vpc>`, `<subnet>`,
    `<vpc>`, only if created by Step P and nothing else uses `<vpc>`):**
    Once `<pool>` is deleted (so its PSC forwarding rule on `<vpc>` is gone) and
    no other cluster or workload uses `<vpc>`, delete the service connection
    policy, subnet, and VPC, then verify each `describe` returns `NOT_FOUND`:

    ```bash
    # Confirm no PSC forwarding rules remain on <vpc> (prints nothing)
    gcloud compute forwarding-rules list --project=<project_id> \
        --filter='network~/<vpc>$' --format='value(name)'

    gcloud network-connectivity service-connection-policies delete alloydb-agents-<vpc> \
        --project=<project_id> --region=<region> --quiet
    gcloud compute networks subnets delete <subnet> \
        --project=<project_id> --region=<region> --quiet
    gcloud compute networks delete <vpc> \
        --project=<project_id> --quiet

    # Verify NOT_FOUND for each deleted network resource
    gcloud network-connectivity service-connection-policies describe alloydb-agents-<vpc> \
        --project=<project_id> --region=<region>
    gcloud compute networks subnets describe <subnet> \
        --project=<project_id> --region=<region>
    gcloud compute networks describe <vpc> --project=<project_id>
    ```

    -   If deleting the VPC fails because firewall rules still use it, delete
        all of its rules in one command and delete the VPC right after: an
        organization policy may re-create the rules within a minute. Anchor the
        filter (`/<vpc>$`) so it can't match another network:

        ```bash
        gcloud compute firewall-rules delete --project=<project_id> --quiet \
            $(gcloud compute firewall-rules list --project=<project_id> \
              --filter='network~/<vpc>$' --format='value(name)')
        gcloud compute networks delete <vpc> --project=<project_id> --quiet
        ```
