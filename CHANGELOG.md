# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The backend pod was reported Ready before it could serve.** The chart
  shipped the backend with all three probes disabled (`enabled: false`) and
  pointed at `/health` — a path the backend does not serve: it registers the
  health route under the `/api` prefix (`server.register(apiRoutes, { prefix:
  "/api" })`), so a probe on `/health` gets a 404 and never turns the pod
  Ready. Since the image entrypoint runs the Drizzle migrations *before* it
  starts the HTTP server, "Ready" meant "the entrypoint started", not "the app
  can answer": `helm --wait` returned with the schema still being migrated, an
  immediately-following e2e reported `Drizzle migrations applied — missing
  tables: user organization sites member account session`, and its first
  `GET /api/health` through the port-forward died with curl exit 52 (empty
  reply from server). The probe path is now `/api/health` and the readiness,
  startup and liveness (gated behind the startup probe) probes are enabled by
  default, so a backend pod is Ready only once it can serve, and `helm --wait`
  no longer returns before the migrations are applied.
- **The e2e test no longer races the deployment.** The run is now gated on the
  release's Deployments finishing their rollout (`kubectl rollout status`, with
  a state/log dump and a clear error on timeout) before any store check is
  made — waiting on pod readiness alone is not enough, because a *terminating*
  pod also reports Ready and would let the test through while its replacement
  is still migrating. That race is what produced the misleading "missing
  tables" failure. `psql` errors are printed instead of being swallowed by
  `2>/dev/null` (a failed query used to look like "every table is missing"),
  and a failed `curl` now reports HTTP 000 instead of aborting the whole
  script through `set -e` with curl's own exit status and no message.

## [1.1.0] - 2026-08-04

### Fixed
- **ClickHouse OOM crash loop:** `system.text_log` was enabled at `trace` level (ClickHouse default), persisting every debug message to disk. During merge-heavy periods this grew `system.text_log` to ~16 GiB with hundreds of unmerged parts, pinning the pod at its 1-core CPU limit and OOM-killing it every ~20 minutes (100+ restarts). The chart now overrides `text_log.level` to `error`.
- **E2E test ClickHouse table check:** the test expected `events` and `bot_events` tables at startup, but the backend creates them lazily on first use (`events` on first `/api/track`, `bot_events` on first bot event). The check now runs after the track round-trip, and `bot_events` is a non-blocking warning since the test generates no bot traffic.

### Changed
- Bump ClickHouse resource limits from `1000m/2Gi` to `2000m/4Gi` — the default was undersized for the merge machinery + internal log tables, leaving zero memory headroom (the server pinned its whole budget, and even `TRUNCATE` on system tables was rejected by the OvercommitTracker).

## [1.0.0] - 2026-08-03

### Added
- Valkey dependency for session tracking and BullMQ queue persistence.
- `.helmignore` — the package previously included the whole `.git` directory (chart went from ~1.1MB to ~35KB, fixing the Kubernetes 1MB Secret size limit that broke `helm install`).

### Changed
- Bump `cnpg/cluster` subchart `0.6.0` → `0.8.1`.
- Inline CNPG `Cluster`, `ClickHouseInstallation` and `ClickHouseKeeperInstallation` templates instead of using subcharts.
- Replace Bitnami Valkey subchart with the official `valkey-io/valkey-helm` subchart.
- **Breaking:** the Altinity ClickHouse operator is no longer bundled with the chart (out of scope, cluster-wide component; its CRDs made the chart too heavy). Install it separately:
  ```bash
  helm repo add altinity https://helm.altinity.com/
  helm install clickhouse-operator altinity/altinity-clickhouse-operator \
    --namespace clickhouse-system --create-namespace \
    --set 'watchNamespaces[0]=.*'
  ```

### Fixed
- Duplicate `app.kubernetes.io/part-of` label in the PostgreSQL Cluster template that made Flux's strict YAML parser reject the release during post-render.
- ClickHouse service selector: use `clickhouse.altinity.com/chi` label instead of `app.kubernetes.io/name`.
- CI: install ClickHouse operator separately, wait for CRD registration before chart install, robust cleanup with timeouts.
- CI: align publish workflow with test workflow.

## [0.6.2] - 2026-07-26

### Changed
- Forward ClickHouse and PostgreSQL connection variables to the backend; add option to skip the ClickHouse wget readiness probe.

## [0.6.1] - 2026-07-24

### Fixed
- Upgrade `cluster` subchart to `0.6.0` to fix `externalClusters` null handling.
- Remove duplicate ServiceAccount in cleanup RBAC.

[1.0.0]: https://github.com/antoniolago/rybbit-helm/compare/v0.6.2...v1.0.0
[0.6.2]: https://github.com/antoniolago/rybbit-helm/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/antoniolago/rybbit-helm/releases/tag/v0.6.1
