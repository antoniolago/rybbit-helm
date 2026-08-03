# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Docs
- Clarify that the chart provisions ClickHouse itself, with the Altinity ClickHouse Operator as an external prerequisite.

## [0.8.0-rc9] - 2026-08-03

### Fixed
- Remove duplicate `app.kubernetes.io/part-of` label in the PostgreSQL Cluster template that made Flux's strict YAML parser reject the release during post-render.

## [0.8.0-rc8] - 2026-08-03

### Fixed
- Align publish workflow with test workflow: install ClickHouse operator separately, wait for CRD registration before chart install, robust cleanup with timeouts.
- Poll `kubectl api-resources` for CRD registration instead of `kubectl wait --for=condition=established`, which could pass before the CRDs were actually usable.

## [0.8.0-rc7] - 2026-07-30

### Fixed
- Wait for ClickHouse CRDs to be established before installing the chart (operator `--wait` only waits for the pod, not CRD registration).

## [0.8.0-rc6] - 2026-07-30

### Fixed
- Restore CI cleanup step with timeouts and namespace finalizer stripping as a fallback.

## [0.8.0-rc5] - 2026-07-30

### Changed
- Simplify CI cleanup: no individual resource deletions (they trigger operator admission webhooks that can hang). `helm uninstall` + namespace deletion with short timeouts.

## [0.8.0-rc4] - 2026-07-30

### Fixed
- Use `clickhouse.altinity.com/chi` label for the ClickHouse service selector instead of `app.kubernetes.io/name` (the operator labels pods with the release name, not "clickhouse").

## [0.8.0-rc3] - 2026-07-30

### Changed
- **Breaking:** remove the Altinity ClickHouse operator from the chart. The operator is out of scope (cluster-wide component) and its CRDs made the chart too heavy. Install it separately:
  ```bash
  helm repo add altinity https://helm.altinity.com/
  helm install clickhouse-operator altinity/altinity-clickhouse-operator \
    --namespace clickhouse-system --create-namespace \
    --set 'watchNamespaces[0]=.*'
  ```
- Inline CNPG `Cluster`, `ClickHouseInstallation` and `ClickHouseKeeperInstallation` templates instead of using subcharts.
- Add `.helmignore` — the package previously included the whole `.git` directory (chart went from ~1.1MB to ~35KB, fixing the Kubernetes 1MB Secret size limit that broke `helm install`).

## [0.8.0-rc2] - 2026-07-28

### Changed
- Bump `cnpg/cluster` subchart `0.6.0` → `0.8.1`.
- Bump `altinity/clickhouse` subchart `0.3.9` → `0.3.13`.

## [0.8.0-rc1] - 2026-07-28

### Added
- Add Valkey as a dependency for session tracking and BullMQ queue persistence.

## [0.7.0-rc3] - 2026-07-28

### Changed
- Replace Bitnami Valkey subchart with the official `valkey-io/valkey-helm` subchart.

## [0.6.2] - 2026-07-26

### Changed
- Forward ClickHouse and PostgreSQL connection variables to the backend; add option to skip the ClickHouse wget readiness probe.

## [0.6.1] - 2026-07-24

### Fixed
- Upgrade `cluster` subchart to `0.6.0` to fix `externalClusters` null handling.
- Remove duplicate ServiceAccount in cleanup RBAC.

[Unreleased]: https://github.com/antoniolago/rybbit-helm/compare/v0.8.0-rc9...HEAD
[0.8.0-rc9]: https://github.com/antoniolago/rybbit-helm/compare/v0.8.0-rc8...v0.8.0-rc9
[0.8.0-rc8]: https://github.com/antoniolago/rybbit-helm/compare/v0.8.0-rc7...v0.8.0-rc8
[0.8.0-rc7]: https://github.com/antoniolago/rybbit-helm/compare/v0.8.0-rc6...v0.8.0-rc7
[0.8.0-rc6]: https://github.com/antoniolago/rybbit-helm/compare/v0.8.0-rc5...v0.8.0-rc6
[0.8.0-rc5]: https://github.com/antoniolago/rybbit-helm/compare/v0.8.0-rc4...v0.8.0-rc5
[0.8.0-rc4]: https://github.com/antoniolago/rybbit-helm/compare/v0.8.0-rc3...v0.8.0-rc4
[0.8.0-rc3]: https://github.com/antoniolago/rybbit-helm/compare/v0.8.0-rc2...v0.8.0-rc3
[0.8.0-rc2]: https://github.com/antoniolago/rybbit-helm/compare/v0.8.0-rc1...v0.8.0-rc2
[0.8.0-rc1]: https://github.com/antoniolago/rybbit-helm/compare/v0.7.0-rc3...v0.8.0-rc1
[0.7.0-rc3]: https://github.com/antoniolago/rybbit-helm/compare/v0.6.2...v0.7.0-rc3
[0.6.2]: https://github.com/antoniolago/rybbit-helm/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/antoniolago/rybbit-helm/releases/tag/v0.6.1
