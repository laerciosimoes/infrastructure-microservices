# infrastructure-microservices

## Purpose

This repository provides the shared infrastructure needed to run and test microservices locally, so individual service repos don't each need to reinvent routing, TLS, observability, or a database. Point your microservices at this environment to get, on your own machine:

- A reverse proxy (Traefik) that routes requests to services by hostname, the same way a production gateway would
- HTTPS locally, via a local TLS certificate, so services can be exercised over `https://` without extra setup
- Centralized metrics, logs, and traces (Prometheus, Loki, Tempo, Grafana) to observe how services behave under test, not just whether they pass
- A local Postgres instance to develop against without depending on a shared/remote database

The goal is a local environment that mirrors how services will actually be deployed and observed, so integration issues surface before code reaches a shared environment.

Shared infrastructure for a microservices environment: reverse proxy / TLS termination, an observability stack (metrics, logs, traces, dashboards), and a development Postgres database. Each concern lives in its own directory with its own `docker-compose` file so stacks can be started independently.

All stacks communicate over a single external Docker network named `proxy`, which must be created once before starting any of them:

```bash
docker network create proxy
```

## Layout

```
.
├── traefik/          # Reverse proxy, TLS termination, Let's Encrypt / local certs
├── observability/     # Prometheus, Loki, Alloy, Tempo, Grafana
└── postgres/          # Local/dev Postgres database
```

## Traefik (reverse proxy)

`traefik/docker-compose.yaml` runs [Traefik](https://doc.traefik.io/traefik/) v3 as the entrypoint for all HTTP(S) traffic.

- Entrypoints: `web` (`:80`) and `websecure` (`:443`)
- Docker provider enabled, but **services are not exposed by default** — a service must opt in with `traefik.enable=true` labels to be routed
- File provider watches `traefik/dynamic/` for dynamic config (currently a local TLS certificate pair for `.localhost`/local development, in `traefik/dynamic/tls.yml`)
- Let's Encrypt HTTP challenge is configured for real domains in production (`traefik/letsencrypt/acme.json` stores issued certificates — keep this file private, it contains account keys and certs)
- Dashboard is disabled (`--api.dashboard=false`)

Start it:

```bash
cd traefik
docker compose up -d
```

Any other service that should be reachable through Traefik needs to join the `proxy` network and carry Traefik routing labels, e.g.:

```yaml
services:
  my-service:
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.http.routers.my-service.rule=Host(`my-service.localhost`)
      - traefik.http.routers.my-service.entrypoints=websecure
      - traefik.http.routers.my-service.tls=true
networks:
  proxy:
    external: true
```

## Observability

`observability/docker-compose.yml` runs the Grafana stack for metrics, logs, and traces.

| Service | Image | Port(s) | Purpose |
|---|---|---|---|
| Prometheus | `prom/prometheus` | `9090` | Metrics scraping/storage (`observability/prometheus/prometheus.yml`) |
| Loki | `grafana/loki:3.0.0` | `3300` → `3100` | Log storage (`observability/loki/config.yml`) |
| Alloy | `grafana/alloy` | `12345` | Collects Docker container logs and ships them to Loki (`observability/alloy/config.alloy`) |
| Tempo | `grafana/tempo` | `4317` (gRPC OTLP), `4318` (HTTP OTLP), `3200` | Distributed trace storage (`observability/tempo/tempo.yml`) |
| Grafana | `grafana/grafana` | `3001` → `3000` | Dashboards, default login `admin` / `admin` |

Start it:

```bash
cd observability
docker compose up -d
```

Notes:

- **Prometheus scrape targets** (`observability/prometheus/prometheus.yml`) currently point at Traefik and a fixed list of application services (e.g. `socialdatatools-leads`, `socialdatatools-crm`, `socialdatatools-whatsapp`, `hotels`, `bookings`, `notifications`, `payments`). Those services must be on the same `proxy` network and expose a metrics endpoint on the configured port — update this file as services are added or removed.
- **Alloy** discovers containers via the Docker socket and auto-labels logs with `container`, `service`, and `project` (derived from Docker Compose labels), then forwards them to Loki — no per-service log config needed.
- **Tempo** accepts traces over OTLP (gRPC `4317` / HTTP `4318`); point application tracing exporters at whichever port matches your OTLP client.
- Grafana provisioning (datasources/dashboards) is expected under `observability/grafana/provisioning`, mounted into the container — add datasource/dashboard YAML there to auto-provision Prometheus/Loki/Tempo on first boot.
- Default Grafana admin credentials (`admin`/`admin`) are for local/dev use only — override `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD` before running this anywhere reachable outside your machine.

## Postgres (development database)

`postgres/docker-compose.yml` runs a local Postgres 16 instance for development.

- Port: `5432`
- Credentials: `POSTGRES_USER=hpcbrasil`, `POSTGRES_PASSWORD=secret`, `POSTGRES_DB=hpcbrasil`
- Data persisted in the `pgdata` volume

Start it:

```bash
cd postgres
docker compose up -d
```

This is a development-only configuration — the hardcoded credentials should not be reused in any shared or production environment.

## Typical local setup

```bash
docker network create proxy   # once

cd traefik && docker compose up -d && cd ..
cd observability && docker compose up -d && cd ..
cd postgres && docker compose up -d && cd ..
```

Then point application services' `docker-compose.yml` at the external `proxy` network so they're reachable through Traefik and picked up by Prometheus/Alloy.

## Security notes

- `traefik/certs/local.key` and `traefik/letsencrypt/acme.json` contain private key material — do not commit real secrets here beyond local development certs, and treat `acme.json` as sensitive once populated in a real deployment.
- Default credentials in this repo (Grafana, Postgres) are placeholders for local development. Rotate/override them for any non-local use.
