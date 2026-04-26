# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Spring Boot 3.5 + Java 25 + kind, validating ConfigMap-driven hot-reload **without Spring Cloud Config Server and without the Netflix stack**. Three Java services (gateway, order-service, pricing-service) + a React UI + flagd, all on a local kind cluster.

`README.md` is the long-form walkthrough — read it for behavioural detail. The original tradeoff analysis (rejected alternatives, KubeCon 2024–2026 notes, ADR-style content) is **archived** at `docs/archive/SPEC-2026-04.md`; not maintained, but cite it when explaining "why we don't use X." This file is the cheatsheet.

## Common commands

| Goal | Command |
|---|---|
| Full e2e from a clean machine | `./scripts/e2e-demo.sh` |
| Just the kind cluster | `./scripts/setup.sh` |
| Rebuild + reload images into kind | `./scripts/build.sh` |
| Apply manifests + wait for ready | `./scripts/deploy.sh` |
| Build all Java modules | `mvn -q -DskipTests package` |
| Build one module | `mvn -q -pl pricing-service -am -DskipTests package` |
| Run all tests for one module | `mvn -pl pricing-service -am test` |
| Run a single test | `mvn -pl pricing-service -Dtest=PricingControllerTest test` |
| Tear down | `kind delete cluster --name sb3-demo` |

After `deploy.sh`/`e2e-demo.sh`, the gateway is on `http://localhost:31080` and the UI on `http://localhost:31180` (NOT 30080/30180 — see gotchas).

## Architecture: two distinct hot-reload paths

This is the single most important thing to understand before editing — the demo proves *two different* mechanisms, and they live in different services:

1. **Feature flag hot-reload (Step 5)** — flagd watches its mounted ConfigMap via fsnotify. Edit `k8s/flagd/configmap.yaml` → next gateway evaluation sees the new value. **No Spring involvement.** Only the gateway has OpenFeature deps; order-service and pricing-service are deliberately OpenFeature-free and read flag results from `X-FF-*` request headers injected by `gateway/src/main/java/demo/gateway/filter/FeatureFlagFilter.java`.

2. **`@ConfigurationProperties` hot-reload (Step 6, method A in archived SPEC § 3)** — pricing-service mounts `pricing-config` ConfigMap as a configtree at `/etc/pricing-config/`, imported via `spring.config.import`. POSTing `/actuator/refresh` fires `EnvironmentChangeEvent`, and `spring-cloud-context`'s `ConfigurationPropertiesRebinder` mutates `PricingConfig` fields **in place** — no `@RefreshScope`, no proxy swap, same pod. Controllers MUST read via getters; snapshotting fields breaks this.

The demo triggers `/actuator/refresh` manually via an ephemeral `kubectl run --image=curlimages/curl` pod. Production replaces this with `spring-cloud-kubernetes-configuration-watcher` (not deployed here to keep YAML small).

## Cross-service request-context pattern

Microservices read flags from a `ScopedValue<FeatureFlags>` populated once at the request boundary (`<service>/flags/FeatureFlagFilter.java`), not from method parameters or `@RequestHeader`. This is `JEP 506` `ScopedValue` (finalised in JDK 25), chosen specifically over `ThreadLocal` for compatibility with virtual threads (which are enabled cluster-wide via `spring.threads.virtual.enabled: true`).

The same filter mirrors flag values into MDC so log lines automatically carry `[tier=…,np=…]` — the logback pattern in each service's `application.yml` reads `%X{ff.tier}` / `%X{ff.newPricing}`.

If you add `@Async` / `CompletableFuture.supplyAsync` paths, `ScopedValue` does **not** auto-propagate across that fork — wrap with `ScopedValue.where(...)` again or use `micrometer-context-propagation`. It *does* auto-propagate inside `StructuredTaskScope`.

## Project constraints (do not break)

- **Excluded**: Spring Cloud Config Server, Netflix stack (Eureka/Zuul/Ribbon/Hystrix).
- **Allowed**: `spring-cloud-context` (`@RefreshScope`, `EnvironmentChangeEvent`, `/actuator/refresh`), `spring-cloud-kubernetes-*`, `spring-cloud-bus`.
- The constraint excludes the **centralised git-backed config server**, not all of Spring Cloud. `spring-cloud-starter` (context only) in `pricing-service/pom.xml` is intentional.

## Non-obvious gotchas

- **Build with Dockerfile, not jib.** The shared root `Dockerfile` + `docker build` is used because jib-maven-plugin 3.4.4's bundled ASM rejects Java 25 class files (`Unsupported class file major version 69`). Don't reach for `mvn jib:dockerBuild`.
- **Host port 31080, not 30080.** Port 30080/30180 conflict with OrbStack on the canonical dev host; `k8s/kind-cluster.yaml` maps NodePorts to 31080/31180. `e2e-demo.sh` uses `GW_URL=http://localhost:31080`.
- **flagd v0.15+ requires explicit port flags.** The Deployment passes `--port 8013 --management-port 8014 --ofrep-port 8016` because v0.15 changed default behaviour. The Service MUST also expose 8016 (OFREP) — the React UI's nginx reverse-proxies `/ofrep/*` to it. Missing the OFREP port on the Service was a real debug cycle; preserve it.
- **OpenFeature init is non-blocking.** Gateway uses `setProvider`, not `setProviderAndWait`, so it starts even when flagd is briefly unreachable; evaluations return defaults until the provider transitions to READY.
- **`/actuator/refresh` rebinds in place.** Holders of `PricingConfig` keep working *only if they read via getters* every request. Don't cache field values into local state.
- **`@RefreshScope` is incompatible with GraalVM native image.** Native is out of scope here; don't add a native build profile expecting refresh to work. Smoke-test recommendation in archived SPEC § 4.4 TC-04.
- **CRaC is Linux-only.** Memory and archived SPEC § 12.1 note this as the 2026 alternative path; on macOS dev hosts fall back to plain JVM start.
- **Pinned versions are load-bearing.** SDK/provider/server versions in `pom.xml` and `k8s/flagd/deployment.yaml` were chosen after compatibility failures (older flagd 0.11.x missed `commons-lang3`; flagd server v0.11.x has no published image tag). Don't bump in isolation — re-run `e2e-demo.sh` after any version change.

## Where things live

- Gateway flag injection: `gateway/src/main/java/demo/gateway/filter/FeatureFlagFilter.java`
- Gateway routes (Spring Cloud Gateway **MVC**, not WebFlux): `gateway/src/main/java/demo/gateway/config/RoutesConfig.java`
- The hot-reloadable bean: `pricing-service/src/main/java/demo/pricing/config/PricingConfig.java`
- Per-service `ScopedValue` holder + filter: `<service>/src/main/java/demo/<service>/flags/`
- ConfigMap that drives flag hot-reload: `k8s/flagd/configmap.yaml`
- ConfigMap that drives `@ConfigurationProperties` hot-reload: `k8s/pricing-service/configmap.yaml`
- React UI + nginx (proxies `/api`→gateway, `/ofrep`→flagd): `ui/`
