# E-commerce OpenFeature Reference Architecture

Spring Boot 3.5 + Java 25 + React + kind + flagd, packaged as a single POC that demonstrates **three different feature-flag usage patterns on the same technical platform**:

1. **Backend-only flags** — the gateway evaluates an operational flag and propagates the result to downstream services
2. **Frontend-only flags** — the browser evaluates presentation-safe flags through OpenFeature web SDK + OFREP
3. **Full-stack flags** — frontend and backend expose the same business semantics while downstream services stay OpenFeature-free

The original tradeoff notes and 2024–2026 conference references are archived in [`docs/archive/SPEC-2026-04.md`](docs/archive/SPEC-2026-04.md).

## What this project demonstrates

### Backend-only flow

- Flag: `ops-fulfillment-mode`
- Evaluation point: `gateway`
- Propagation: `X-FF-Fulfillment-Mode`
- Consumer: `order-service`
- Business effect: premium tenant traffic routes to the express fulfillment pipeline

### Frontend-only flow

- Flags: `ui-homepage-banner`, `ui-member-perks`
- Evaluation point: `ui` via OpenFeature web SDK + same-origin OFREP
- Consumer: React UI only
- Business effect: VIP users see a sale banner and perks card without affecting backend logic

### Full-stack flow

- Flags: `order-tier`, `new-pricing-algo`
- Evaluation point: `gateway` for API requests
- Propagation: `X-FF-Order-Tier`, `X-FF-New-Pricing`
- Consumers: `order-service`, `pricing-service`, and the UI through `/experience/shared-flags`
- Business effect: VIP users and premium tenants see consistent membership/pricing semantics across UI and backend responses

### Dynamic config refresh

This repo also keeps the original Spring-side config refresh path:

- ConfigMap mounted as configtree into `pricing-service`
- `POST /actuator/refresh`
- `@ConfigurationProperties` rebound in place
- same pod, no restart

That flow complements feature flags; it is not a fourth flag architecture.

## Architecture

```text
Browser ──► nginx :31180 ─── /        → React static files
             │           ─── /api/*   → gateway:8080
             │           ─── /ofrep/* → flagd:8016
             │
             ├─ frontend-only flags evaluated in browser via OFREP
             └─ shared snapshot fetched from gateway

curl ─────► gateway :31080 ──► order-service   :8081
                        └──► pricing-service :8082
             │
             ├─ OpenFeature Java SDK → flagd gRPC :8013
             ├─ injects X-FF-* headers into downstream calls
             └─ exposes /experience/shared-flags for UI read models

pricing-service ──► configtree:/etc/pricing-config/ + /actuator/refresh
flagd           ──► watches k8s/flagd/configmap.yaml via fsnotify
```

## Key architectural rules

- **OpenFeature Java stays at the gateway** for backend/shared business flags.
- **Downstream services do not talk to flagd**; they consume propagated `X-FF-*` snapshots through `ScopedValue<FeatureFlags>`.
- **Frontend-only flags may use OFREP directly** only when they are presentation-safe.
- **Shared business flags are not re-evaluated in downstream services**.
- **Dynamic config refresh is separate from feature flags** and uses `spring-cloud-context`, not Config Server.

## Repository layout

```text
gateway/          Spring Cloud Gateway MVC + OpenFeature Java SDK
order-service/    Backend-only consumer of propagated fulfillment and tier flags
pricing-service/  Shared pricing semantics + @ConfigurationProperties refresh
ui/               React + Vite + OpenFeature web SDK + OFREP
k8s/              kind config, deployments, services, ConfigMaps
scripts/          setup, build, deploy, full E2E verification
docs/superpowers/ design doc and implementation plan for this redesign
```

## Prerequisites

| Tool | Version used |
|---|---|
| JDK | 25 |
| Maven | 3.9+ |
| Docker | 28.x |
| kind | 0.31+ |
| kubectl | 1.32+ |
| jq | any |
| npm | recent Node 22-compatible version |

## Commands

| Goal | Command |
|---|---|
| Create a clean kind cluster | `./scripts/setup.sh` |
| Build Java services and UI images | `./scripts/build.sh` |
| Apply manifests and wait for ready | `./scripts/deploy.sh` |
| Run the full POC verification | `./scripts/e2e-demo.sh` |
| Build Java only | `mvn -q -DskipTests package` |
| Run focused Java tests | `mvn -q -pl gateway,order-service test` |
| Build the UI only | `cd ui && npm run build` |
| Tear down | `kind delete cluster --name sb3-demo` |

After deploy:

- Gateway: `http://localhost:31080`
- UI: `http://localhost:31180`

## Fastest way to validate the POC

```bash
./scripts/e2e-demo.sh
```

The script:

1. recreates the kind cluster for a clean run
2. builds all images
3. deploys flagd, gateway, backend services, and UI
4. verifies backend-only, frontend-only, and full-stack flag flows
5. verifies flag hot-reload without pod restarts
6. verifies `pricing-service` config refresh without pod replacement

It exits non-zero on the first failed assertion.

## Manual exploration

### Backend-only

```bash
curl -s -H 'X-Tenant-Id: premium' http://localhost:31080/orders/o-201 | jq
```

Expected highlights:

- `fulfillmentMode: "express"`
- `handler: "express-order-pipeline"`
- `tier: "standard"`

### Frontend-only

```bash
curl -s -X POST http://localhost:31180/ofrep/v1/evaluate/flags/ui-homepage-banner \
  -H 'Content-Type: application/json' \
  -d '{"context":{"targetingKey":"u-vip-001"}}' | jq
```

Expected:

- VIP user → `spring-sale`
- regular user → `control`

### Full-stack

```bash
curl -s -H 'X-User-Id: u-vip-001' -H 'X-Tenant-Id: premium' \
  http://localhost:31080/experience/shared-flags | jq

curl -s -H 'X-User-Id: u-vip-001' -H 'X-Tenant-Id: premium' \
  http://localhost:31080/pricing/sku-B | jq
```

Expected:

- shared snapshot shows `orderTier: "premium"` and `newPricing: true`
- pricing response shows `tier: "premium"` and `algorithm: "v2-segmented"`

### Flag hot-reload

Edit `k8s/flagd/configmap.yaml` or patch the ConfigMap in-cluster and watch `new-pricing-algo` flip behavior without restarting pods.

### Config refresh

Patch `pricing-config`, then trigger:

```bash
kubectl run --rm -i --restart=Never --image=curlimages/curl:8.10.1 trigger-refresh \
  -- -fsS -X POST http://pricing-service:8082/actuator/refresh
```

`pricing-service` should reflect the new values while keeping the same pod name.

## Important constraints

- **Do not add Spring Cloud Config Server or Netflix stack components.**
- **Do not move OpenFeature Java into downstream services.**
- **Build images with the shared root `Dockerfile`, not Jib.**
- **Preserve flagd ports `8013`, `8014`, and `8016`.**
- **Read `PricingConfig` through getters every request; do not cache its fields.**

## Design and planning artifacts

- Design spec: `docs/superpowers/specs/2026-04-29-ecommerce-openfeature-scenarios-design.md`
- Implementation plan: `docs/superpowers/plans/2026-04-29-ecommerce-openfeature-scenarios.md`
