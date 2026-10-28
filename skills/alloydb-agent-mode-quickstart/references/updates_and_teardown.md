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

1.  **Per-deployment resources (`<name>`):** one command finds and deletes
    everything Steps 2-5 created for `<name>`, in dependency order: Gemini
    Enterprise registrations (when `gemini_enterprise.app_id` is set), the Agent
    Engines (`force=True`, which releases the PSC network attachment), the
    per-deployment stack (the SA, its IAM bindings and, with `workspace: true`,
    the Cloud Run service and its secrets), and the AlloyDB IAM database user
    that Step 2 creates outside Terraform:

    ```bash
    # Lists what exists for <name> and deletes nothing:
    .venv/bin/python "<skill>"/scripts/deploy_agent.py teardown --config <config_path>
    # Only after the user confirms that list: delete it, then verify
    .venv/bin/python "<skill>"/scripts/deploy_agent.py teardown --config <config_path> --yes
    ```

    It finds the resources by `name`, so a partial deployment or an edited
    config still tears down cleanly, and it never touches the shared foundation,
    the network, or the pool. It waits for each deletion before the next and
    prints `TEARDOWN PASS` only after checking that nothing is left. On
    `TEARDOWN FAIL`, fix the cause and re-run; finished steps are skipped.

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

3.  **AlloyDB agent pool and cluster (Step P, only if created by this skill):**
    First, list the exact Step P resources to be deleted (`<pool>`,
    `alloydb-agents-<vpc>`, `<cluster>`, `<subnet>`, `<vpc>`) in your reply and
    **end your turn** to wait for the user's confirmation before running any
    delete command. Once confirmed, run **after** `alloydb-agent-project` is
    deleted:

    ```bash
    # 1. Agent pool (also removes its PSC endpoint and private alloydb.goog. DNS zone)
    gcloud beta alloydb instances delete <pool> \
        --project=<project_id> --region=<region> --cluster=<cluster> --quiet

    # 2. Service connection policy, once the pool's PSC endpoint is gone (this
    #    list prints nothing)
    gcloud compute forwarding-rules list --project=<project_id> \
        --filter='network~/<vpc>$' --format='value(name)'
    gcloud network-connectivity service-connection-policies delete alloydb-agents-<vpc> \
        --project=<project_id> --region=<region> --quiet

    # 3. Optional: AlloyDB cluster (deletes primary instance and database users)
    gcloud beta alloydb clusters delete <cluster> \
        --project=<project_id> --region=<region> --force --quiet

    # 4. Optional: Step P subnet and VPC
    gcloud compute networks subnets delete <subnet> \
        --project=<project_id> --region=<region> --quiet
    gcloud compute networks delete <vpc> \
        --project=<project_id> --quiet
    ```

    Then run the verification checks below and confirm each `describe` returns
    `NOT_FOUND` before reporting teardown complete:

    ```bash
    gcloud beta alloydb clusters describe <cluster> \
        --project=<project_id> --region=<region>
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
    -   Deleting a pool blocks creating a new pool on the same cluster until
        backend cleanup completes.
