# Rybbit Helm Chart

A Helm chart for deploying [Rybbit](https://github.com/rybbit-io/rybbit) self-hosted analytics platform on Kubernetes.

## Beware

This chart is tested only to a certain point, be sure to ALWAYS backup Postgres and Clickhouse (the external charts have options for that, look for the links below), if you got any issues please submit it, also PRs are welcome.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- PV provisioner support in the underlying infrastructure

## Installation

```bash
# Install with default values
helm install rybbit oci://harbor.lag0.com.br/library/rybbit

# Install with custom values
helm install rybbit oci://harbor.lag0.com.br/library/rybbit -f values.yaml
```

## Minimal Running Example

Below is a minimal configuration example for production usage, DB and Clickhouse secrets are managed by postgresql.auth and clickhouse.auth values:

```yaml
client:
  image:
    tag: sha-446bb2b
  env:
    NEXT_PUBLIC_BACKEND_URL: "https://rybbit.lag0.com.br"
    NEXT_PUBLIC_DISABLE_SIGNUP: "false"
backend:
  image:
    tag: sha-446bb2b
  env:
    BASE_URL: "https://rybbit.lag0.com.br"
    DISABLE_SIGNUP: "false"

ingress:
  # API Ingress (with regex)
  api:
    enabled: true
    className: "nginx"
    annotations:
      kubernetes.io/ingress.class: nginx
      cert-manager.io/cluster-issuer: letsencrypt-prod
      nginx.ingress.kubernetes.io/use-regex: "true"
      nginx.ingress.kubernetes.io/rewrite-target: /$2
    hosts:
    - host: rybbit.lag0.com.br
      paths:
      - path: /api(/|$)(.*)
        pathType: ImplementationSpecific
    tls:
    - secretName: lag0-rybbit-certificate
      hosts:
      - rybbit.lag0.com.br
  # Client Ingress (without regex)
  client:
    enabled: true
    className: "nginx"
    annotations:
      kubernetes.io/ingress.class: nginx
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
    - host: rybbit.lag0.com.br
      paths:
      - path: /
        pathType: Prefix
    tls:
    - secretName: lag0-rybbit-certificate
      hosts:
      - rybbit.lag0.com.br
```

## External Dependencies

This chart uses the following external dependencies:

### PostgreSQL (Bitnami)

The chart uses Bitnami's PostgreSQL chart as a dependency. For detailed configuration options, refer to:
[Bitnami PostgreSQL Parameters](https://github.com/bitnami/charts/tree/main/bitnami/postgresql#parameters)

### ClickHouse

The chart uses the ClickHouse Operator for ClickHouse deployment. For detailed configuration options, refer to:
[Bitnami Clickhouse Parameters](https://github.com/bitnami/charts/tree/main/bitnami/clickhouse)

## Configuration

The following table lists the configurable parameters of the Rybbit chart and their default values.

### Global parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.imagePullSecrets` | Global image pull secrets | `[]` |
| `global.podSecurityContext` | Global pod security context | See values.yaml |
| `global.containerSecurityContext` | Global container security context | See values.yaml |
| `global.podAntiAffinity` | Global pod anti-affinity | `"soft"` |

### Backend parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `backend.enabled` | Enable backend deployment | `true` |
| `backend.image.repository` | Backend image repository | `ghcr.io/rybbit-io/rybbit-backend` |
| `backend.image.tag` | Backend image tag | `latest` |
| `backend.replicaCount` | Number of backend replicas | `1` |
| `backend.resources` | Backend resource requests/limits | See values.yaml |
| `backend.env` | Backend environment variables | See values.yaml |
| `backend.betterSecret.secretName` | Name of the secret containing auth key | `""` |
| `backend.betterSecret.authKey` | Key in the secret containing auth value | `"better-auth-secret"` |
| `backend.betterSecret.authValue` | Value for the auth secret | `""` |

### Client parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `client.enabled` | Enable client deployment | `true` |
| `client.image.repository` | Client image repository | `ghcr.io/rybbit-io/rybbit-client` |
| `client.image.tag` | Client image tag | `latest` |
| `client.replicaCount` | Number of client replicas | `1` |
| `client.resources` | Client resource requests/limits | See values.yaml |
| `client.env` | Client environment variables | See values.yaml |

### PostgreSQL parameters

For all available PostgreSQL parameters, see [Bitnami PostgreSQL Parameters](https://github.com/bitnami/charts/tree/main/bitnami/postgresql#parameters)

### ClickHouse parameters

For all available ClickHouse parameters, see [ClickHouse Operator Configuration](https://clickhouse.com/docs/en/kubernetes/operator)

### Ingress parameters

| Parameter                | Description                                 | Default |
|-------------------------|---------------------------------------------|---------|
| `ingress.api.enabled`   | Enable API ingress (with regex)             | `false` |
| `ingress.api.className` | Ingress class name for API                  | `""`   |
| `ingress.api.annotations`| Annotations for API ingress                 | See values.yaml |
| `ingress.api.hosts`     | Hosts for API ingress                      | See values.yaml |
| `ingress.api.tls`       | TLS config for API ingress                 | See values.yaml |
| `ingress.client.enabled`| Enable client ingress (no regex)            | `false` |
| `ingress.client.className`| Ingress class name for client              | `""`   |
| `ingress.client.annotations`| Annotations for client ingress            | See values.yaml |
| `ingress.client.hosts`  | Hosts for client ingress                    | See values.yaml |
| `ingress.client.tls`    | TLS config for client ingress               | See values.yaml |

> See the Minimal Running Example above for a real-world configuration.

### Environment Variables

The backend and client applications can be configured through environment variables. You can provide custom environment variables in your `values.yaml`:

```yaml
backend:
  env:
    NODE_ENV: production
    # Add any custom environment variables here
    ### USE clickhouse.auth VALUES INSTEAD, ITS SAFER
    # CLICKHOUSE_USER: "rybbit"
    # CLICKHOUSE_PASSWORD: "rybbit"
    # CLICKHOUSE_HOST: "default-will-come-from-clickhouse-chart"

    ### USE postgres.auth INSTEAD, ITS SAFER
    # POSTGRES_HOST: postgresql-postgresql
    # POSTGRES_DB: analytics
    # POSTGRES_USER: postgres
    # POSTGRES_PASSWORD: "use-secret-instead"
    CUSTOM_VAR: value

client:
  env:
    NODE_ENV: production
    # Add any custom environment variables here
    CUSTOM_VAR: value
```

## Upgrading

```bash
helm upgrade rybbit oci://harbor.lag0.com.br/library/rybbit -f values.yaml
```

## Uninstalling

```bash
helm uninstall rybbit
```
