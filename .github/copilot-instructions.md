# Copilot instructions

Start with `README.md` for the current walkthrough and `CLAUDE.md` for the short repo cheatsheet. Use `docs/archive/SPEC-2026-04.md` only for historical tradeoff context.

## Commands

| Purpose | Command |
|---|---|
| Full end-to-end POC verification | `./scripts/e2e-demo.sh` |
| Recreate the kind cluster | `./scripts/setup.sh` |
| Build and load all images into kind | `./scripts/build.sh` |
| Apply manifests and wait for readiness | `./scripts/deploy.sh` |
| Build all Java modules | `mvn -q -DskipTests package` |
| Run focused Java tests | `mvn -q -pl gateway,order-service test` |
| Build the UI | `cd ui && npm run build` |
| Tear down the cluster | `kind delete cluster --name sb3-demo` |

Gateway is on `http://localhost:31080` and the UI is on `http://localhost:31180`.

## Architecture

This repo is a **single e-commerce reference architecture** showing three feature-flag patterns on one stack:

1. **Backend-only**: gateway evaluates `ops-fulfillment-mode` and forwards it as `X-FF-Fulfillment-Mode`; downstream services consume the propagated snapshot only.
2. **Frontend-only**: React evaluates presentation-safe flags (`ui-homepage-banner`, `ui-member-perks`) via OpenFeature web SDK + same-origin OFREP through nginx.
3. **Full-stack**: gateway evaluates `order-tier` and `new-pricing-algo`, forwards them to backend services, and exposes `/experience/shared-flags` so the UI can render the same business semantics.

Separate from flags, `pricing-service` still demonstrates Spring config hot-reload through ConfigMap-as-configtree plus `/actuator/refresh`.

## Key conventions

- Keep OpenFeature Java centralized in `gateway/`. `order-service/` and `pricing-service/` are intentionally OpenFeature-free.
- Backend services read propagated flags through request-scoped `ScopedValue<FeatureFlags>`, not method parameters or direct SDK calls.
- Frontend-only flags may be evaluated in the browser only when they are presentation-safe. Do not move backend business decisions into OFREP-only client logic.
- Read `PricingConfig` through getters every request; `spring-cloud-context` mutates that bean in place during refresh.
- Build service images with the shared root `Dockerfile`. Do not switch to Jib.
- Keep kind and Service ports aligned at `31080` for gateway and `31180` for UI.
- Preserve flagd ports `8013`, `8014`, and `8016`; `/ofrep/*` depends on `8016`.
- Gateway provider startup is intentionally non-blocking; keep `setProvider(...)` semantics.
- Re-run `./scripts/e2e-demo.sh` after any change to flag evaluation, ConfigMaps, versions, or request propagation.
