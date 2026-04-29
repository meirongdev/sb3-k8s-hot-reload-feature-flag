# CLAUDE.md

Repository guidance for AI-assisted work in this project.

## What this repo is

This is a **single e-commerce OpenFeature reference architecture** on Spring Boot 3.5 + Java 25 + kind. It demonstrates three feature-flag usage patterns on one platform:

1. **Backend-only** — gateway evaluates `ops-fulfillment-mode`, downstream services consume `X-FF-*`
2. **Frontend-only** — React uses OpenFeature web SDK + OFREP for `ui-homepage-banner` and `ui-member-perks`
3. **Full-stack** — gateway evaluates `order-tier` and `new-pricing-algo`, exposes `/experience/shared-flags`, and propagates the same semantics to backend services

The old tradeoff history and conference notes live in `docs/archive/SPEC-2026-04.md`.

## Common commands

| Goal | Command |
|---|---|
| Full POC verification | `./scripts/e2e-demo.sh` |
| Recreate kind cluster | `./scripts/setup.sh` |
| Build images and load into kind | `./scripts/build.sh` |
| Apply manifests and wait | `./scripts/deploy.sh` |
| Build all Java modules | `mvn -q -DskipTests package` |
| Run focused Java tests | `mvn -q -pl gateway,order-service test` |
| Build the UI | `cd ui && npm run build` |
| Tear down | `kind delete cluster --name sb3-demo` |

Gateway is on `http://localhost:31080`, UI on `http://localhost:31180`.

## Most important architecture rule

There are **three distinct flag paths** and they should stay distinct:

1. **Backend-only flags**  
   Gateway evaluates once, forwards the result as headers, backend services consume the propagated snapshot. No downstream OpenFeature SDKs.

2. **Frontend-only flags**  
   UI evaluates presentation-safe flags through same-origin OFREP. These should not decide backend business behavior.

3. **Full-stack flags**  
   Gateway is still the server-side authority. It forwards `X-FF-*` headers to backend services and exposes `/experience/shared-flags` so the UI can render the same business semantics for the same user/tenant context.

## Cross-service request-context pattern

- Backend services read propagated flags through `ScopedValue<FeatureFlags>`, not through method parameters.
- `order-service` and `pricing-service` remain OpenFeature-free by design.
- The filter in each service also mirrors values into MDC so logs carry flag context automatically.
- If you add `@Async` or arbitrary thread forks, `ScopedValue` does not auto-propagate; rebind it explicitly.

## Dynamic config refresh

`pricing-service` still demonstrates Spring config refresh separately from feature flags:

- ConfigMap mounted as `configtree:/etc/pricing-config/`
- `/actuator/refresh`
- in-place `@ConfigurationProperties` rebind
- same pod, no restart

Controllers must read `PricingConfig` through getters on every request.

## Constraints

- **Excluded**: Spring Cloud Config Server, Netflix stack
- **Allowed**: `spring-cloud-context` and related refresh support already used in `pricing-service`
- **Do not move OpenFeature Java into downstream services**
- **Do not use Jib**; build images with the root `Dockerfile`

## Gotchas

- `scripts/e2e-demo.sh` recreates the kind cluster on each run so NodePort mappings and in-cluster state stay deterministic.
- kind NodePorts are `31080` for gateway and `31180` for UI; keep `k8s/kind-cluster.yaml`, `k8s/gateway/deployment.yaml`, and `k8s/ui/deployment.yaml` aligned.
- flagd `8016` is load-bearing because nginx proxies `/ofrep/*` to it.
- Gateway OpenFeature provider startup is intentionally non-blocking (`setProvider`, not `setProviderAndWait`).
- Pinned versions in `pom.xml`, `ui/package.json`, and `k8s/flagd/deployment.yaml` are load-bearing; rerun the full POC after any upgrade.

## Where things live

- Gateway evaluation and propagation: `gateway/src/main/java/demo/gateway/`
- Gateway shared snapshot endpoint: `gateway/src/main/java/demo/gateway/controller/FeatureFlagSnapshotController.java`
- Backend request-scoped flag holders: `<service>/src/main/java/demo/<service>/flags/`
- Pricing hot-reload config bean: `pricing-service/src/main/java/demo/pricing/config/PricingConfig.java`
- Flag definitions: `k8s/flagd/configmap.yaml`
- Config refresh source: `k8s/pricing-service/configmap.yaml`
- React UI and OFREP usage: `ui/`
