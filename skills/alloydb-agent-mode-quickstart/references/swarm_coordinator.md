# Gemini Enterprise Registration and Swarm Chat Test Flow

## Gemini Enterprise prerequisites and registration (Step 5)

```bash
.venv/bin/python "<skill>"/scripts/deploy_agent.py register --config <config_path>
```

When `gemini_enterprise.app_id` is set, `register` discovers the deployment's
entry-point engine (`<name>_swarm_coordinator` when `coordinator` is configured,
otherwise `<name>_agent`) and creates or patches its `adkAgentDefinition` in
Discovery Engine (`v1alpha`) with `sharingConfig.scope: ALL_USERS`.

### Prerequisites (verify only — do not provision or modify)

Treat the items below as pre-existing environment prerequisites. Only check
whether they are met and report any missing prerequisite to the user—do **not**
attempt to activate subscriptions, modify organization Identity Provider
(`AclConfig`) settings, or assign user seat licenses on the user's behalf:

-   **Subscription:** Active Gemini Enterprise subscription or 30-day free trial
    on the billing account.
-   **Global app location:** The target Gemini Enterprise app must be in the
    `global` location (`us`/`eu` apps reject regional Agent Engine resources).
-   **Caller IAM roles:** Gemini Enterprise Admin and Discovery Engine Admin
    (`agents.manage`), with `discoveryengine.googleapis.com` enabled.
-   **End-user license:** Each user opening the Gemini Enterprise chat UI needs
    an assigned seat license (Console → Gemini Enterprise → Manage users).
-   **Projects outside a GCP Organization:** Cannot complete Identity Provider
    (`AclConfig`) setup, which gates the Console's *Integration* tab, but the
    chat app still works via the Console **Preview** button or
    `https://vertexaisearch.cloud.google.com/home/cid/<app-uuid>`.

**Chat test flow (swarm):**

1.  `"Investigate <problem> with 3 agents"` → returns `run_id` immediately.
2.  `"status"` → polls `swarm_status` until all child sessions complete.
3.  `"collect the report"` → calls `collect_findings` and synthesizes the final
    report.
