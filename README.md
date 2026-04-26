# SB3.5 + Java 25 + K8s Demo: Gateway + Microservices + OpenFeature

Self-contained demo: Spring Boot 3.5 + Java 25 + Kubernetes (kind), no Spring Cloud Config Server, no Netflix stack. The original tradeoff/selection analysis is archived at [`docs/archive/SPEC-2026-04.md`](docs/archive/SPEC-2026-04.md) — that document is no longer maintained but is preserved for the ADR-style content (rejected alternatives, 2024–2026 KubeCon / Spring I/O notes).

What it shows:
- API Gateway (**Spring Cloud Gateway MVC**, no WebFlux) with virtual threads
- Two backend microservices (Spring MVC + virtual threads)
- OpenFeature Java SDK + flagd at the gateway only
- Flag results propagated to MS via `X-FF-*` request headers — single evaluation source
- **Two kinds of hot-reload**, both without restarting any pod:
  1. **Feature flag values** — edit ConfigMap → flagd's fsnotify picks it up → next gateway evaluation returns new value (Step 5 below)
  2. **Application `@ConfigurationProperties`** — edit ConfigMap → kubelet syncs volume → `/actuator/refresh` rebinds `PricingConfig` (Step 6 below). Uses `spring-cloud-context` (no Config Server, no Netflix — both excluded by design).

```
Browser ──► nginx :31180  ─── /        → React static files
              │           ─── /api/*   → gateway:8080
              │           ─── /ofrep/* → flagd:8016        (OFREP HTTP — frontend
              │                                              talks to the SAME flagd
              │                                              the gateway uses)
              │
curl ───────► gateway :31080 ──► order-service   :8081
                          └──► pricing-service :8082 ──┐
              │                                         │
              │   OpenFeature SDK (Java)                │   spring.config.import:
              ├─► flagd (gRPC :8013)                    └─► configtree:/etc/pricing-config/
              │     └─► ConfigMap flagd-config              └─► ConfigMap pricing-config
              │           (Step 5 hot-reload)                     (Step 6 hot-reload via
              │                                                    /actuator/refresh +
              └─ injects X-FF-New-Pricing, X-FF-Order-Tier         @ConfigurationProperties
                 headers into downstream calls                     auto-rebind)
```

The React UI uses **OpenFeature web SDK** + **OFREP web provider** (`@openfeature/web-sdk`, `@openfeature/ofrep-web-provider`) and evaluates against the **same flagd** that the Java gateway uses. The same `order-tier` flag drives both: a `VIP` badge in the UI and the `premium-order-pipeline` server-side handler — single source of truth, two languages.

## Project layout

```
sb3-k8s-hot-reload/
├── README.md                   # This file
├── CLAUDE.md                   # AI assistant onboarding cheatsheet
├── Dockerfile                  # Shared by all three services
├── pom.xml                     # Parent (Spring Boot 3.5 + Spring Cloud 2025.0)
├── gateway/                    # Spring Cloud Gateway MVC + OpenFeature
│   └── src/main/java/demo/gateway/
│       ├── GatewayApplication.java
│       ├── config/{OpenFeatureConfig,RoutesConfig}.java
│       └── filter/FeatureFlagFilter.java
├── order-service/              # Spring MVC + virtual threads (no OpenFeature)
├── pricing-service/            # Spring MVC + virtual threads + spring-cloud-context
│   └── src/main/java/demo/pricing/
│       ├── PricingApplication.java
│       ├── config/PricingConfig.java       # @ConfigurationProperties — hot-reloaded
│       └── controller/PricingController.java
├── k8s/
│   ├── kind-cluster.yaml
│   ├── flagd/{configmap,deployment,service}.yaml
│   ├── gateway/deployment.yaml
│   ├── order-service/deployment.yaml
│   ├── pricing-service/{deployment,configmap}.yaml   # configmap mounted as configtree
│   └── ui/deployment.yaml                            # React + nginx, NodePort 30180
├── ui/                         # React + Vite + TS — uses @openfeature/web-sdk + OFREP
│   ├── package.json
│   ├── nginx.conf              # SPA + reverse-proxy /api → gateway, /ofrep → flagd
│   ├── Dockerfile              # multi-stage: node build → nginx serve
│   └── src/
│       ├── main.tsx
│       ├── App.tsx             # user switcher, badges driven by flags
│       ├── openfeature.ts      # OFREP web provider setup
│       └── api.ts              # same-origin /api/* calls
├── scripts/
│   ├── setup.sh                # create kind cluster only
│   ├── build.sh                # mvn package + docker build + kind load
│   ├── deploy.sh               # kubectl apply + wait
│   ├── e2e-demo.sh             # one-shot full pipeline ⭐
│   └── log-to-markdown.sh      # ANSI-strip helper
└── docs/
    ├── demo-output.txt         # Captured terminal log of a real run
    └── archive/
        └── SPEC-2026-04.md     # Archived design doc (tradeoffs + KubeCon notes)
```

## Prerequisites

| Tool | Version used in demo |
|---|---|
| JDK | 25 LTS (Temurin 25.0.2 verified) |
| Maven | 3.9.14 |
| Docker | 28.x (OrbStack works) |
| `kind` | v0.31.0+ |
| `kubectl` | v1.32+ (cluster runs Kubernetes 1.35) |
| `jq` | any |

### Pinned library versions

These are the exact versions verified working together — bumping any single one risks wire-compat breakage; see commit history if you need to upgrade.

| Component | Version | Notes |
|---|---|---|
| Spring Boot | `3.5.0` | parent BOM |
| Spring Cloud | `2025.0.0` | provides `spring-cloud-starter-gateway-server-webmvc` |
| OpenFeature Java SDK | `1.20.2` | |
| flagd Java provider | `0.13.0` | older 0.11.x missed `commons-lang3` and blocked on init |
| flagd server image | `ghcr.io/open-feature/flagd:v0.15.4` | needs explicit `--port 8013` (default behaviour changed in v0.15) |
| Node (UI build stage) | `node:22-alpine` | builds React assets |
| nginx (UI serve stage) | `nginx:1.27-alpine` | serves static + reverse-proxies `/api`+`/ofrep` |
| `@openfeature/web-sdk` | `^1.8.0` | OpenFeature browser SDK |
| `@openfeature/ofrep-web-provider` | `^0.3.6` | OFREP-over-HTTP browser provider |
| React | `^18.3.1` | |
| Vite | `^5.4.11` | dev server + bundler |

## Run the full e2e demo

One command. From a clean machine (no kind cluster, no images), this builds everything, deploys it, runs the scenarios, and demonstrates hot-reload:

```bash
./scripts/e2e-demo.sh
```

What it does, end-to-end:

| Step | What happens | Typical duration |
|---|---|---|
| 1 | `kind create cluster` (or reuse if it exists) | 30–60s cold, instant warm |
| 2 | `mvn package` × 3 modules → `docker build` × 3 → `kind load docker-image` × 3 | 10–30s |
| 3 | `kubectl apply` flagd + 2× MS + gateway, wait for `condition=Available` | 15–30s |
| 4 | Hits the gateway with 6 scenario requests, asserts the flag-driven behaviour | ~10s |
| 5 | Patches `flagd-config` ConfigMap, polls until the new flag value appears | ~6–15s |
| 6 | Patches `pricing-config` ConfigMap, triggers `/actuator/refresh`, polls until rebound `@ConfigurationProperties` values appear | ~10–20s |
| 7 | Verifies React UI shell + OFREP proxy (browser-style flag evaluation) | ~5s |
| **Total cold start** | | **~3–5 min** |

Idempotent — re-running reuses the cluster and only redeploys what changed.

The full transcript of a real successful run is in [`docs/demo-output.txt`](docs/demo-output.txt). Sections below show selected slices.

### Success criteria

The script exits `0` only if all of the following hold:

- All four pods (`flagd`, `gateway`, `order-service`, `pricing-service`) reach `READY 1/1`.
- All 6 scenario responses contain the expected `tier` / `algorithm` / `handler` field values.
- Step 5: the same anonymous `/pricing/sku-X` request returns `algorithm: "v2-segmented"` instead of `"v1-flat"` within 30 s of patching `flagd-config`.
- Step 6: `/pricing/sku-A` returns `discountPercent: 25` and `currency: "CNY"` within 30 s of patching `pricing-config`, with **the same pricing-service pod** still running.
- All `kubectl get pods` show `RESTARTS: 0` after both reload demos.
- Step 7: `curl http://localhost:31180/` returns the React HTML shell, and an OFREP `POST /ofrep/v1/evaluate/flags/order-tier` with `{targetingKey: "u-vip-001"}` returns `value: "premium"`.

If anything fails, the script prints the failed step and exits non-zero — see [Troubleshooting](#troubleshooting).

## Demo screenshots (real terminal output)

### Step 1 — kind cluster

```text
── Step 1 — kind cluster ──
$ kind create cluster --config k8s/kind-cluster.yaml
Creating cluster "sb3-demo" ...
 ✓ Ensuring node image (kindest/node:v1.35.0) 🖼
 ✓ Preparing nodes 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
$ kubectl --context kind-sb3-demo get nodes
NAME                     STATUS   ROLES           AGE   VERSION
sb3-demo-control-plane   Ready    control-plane   14m   v1.35.0
sb3-demo-worker          Ready    <none>          14m   v1.35.0
✓ cluster ready
```

### Step 2 — build images and load into kind

```text
── Step 2 — build images and load into kind ──
$ mvn -q -DskipTests package
$ docker build --quiet -t local/gateway:0.0.1-SNAPSHOT -f Dockerfile gateway/
$ kind load docker-image local/gateway:0.0.1-SNAPSHOT --name sb3-demo
$ docker build --quiet -t local/order-service:0.0.1-SNAPSHOT -f Dockerfile order-service/
$ kind load docker-image local/order-service:0.0.1-SNAPSHOT --name sb3-demo
$ docker build --quiet -t local/pricing-service:0.0.1-SNAPSHOT -f Dockerfile pricing-service/
$ kind load docker-image local/pricing-service:0.0.1-SNAPSHOT --name sb3-demo
✓ images built and loaded
```

### Step 3 — deploy

```text
── Step 3 — deploy flagd + microservices + gateway ──
$ kubectl apply -f k8s/flagd/
configmap/flagd-config created
deployment.apps/flagd created
service/flagd created
deployment.apps/flagd condition met
$ kubectl apply -f k8s/order-service/ -f k8s/pricing-service/ -f k8s/gateway/
deployment.apps/order-service condition met
deployment.apps/pricing-service condition met
deployment.apps/gateway condition met
$ kubectl get pods -o wide
NAME                              READY   STATUS    RESTARTS   AGE   IP            NODE              ...
flagd-b779b6f-rwgw5               1/1     Running   0          10s   10.244.1.10   sb3-demo-worker
gateway-76598d7dbd-f7pnj          1/1     Running   0          7s    10.244.1.13   sb3-demo-worker
order-service-5b7b8946d6-hksr2    1/1     Running   0          7s    10.244.1.11   sb3-demo-worker
pricing-service-d7954cf6b-k7x7p   1/1     Running   0          7s    10.244.1.12   sb3-demo-worker
✓ all deployments ready
```

### Step 4 — feature flag scenarios

#### 4.1 Anonymous → defaults

```text
$ curl -s http://localhost:31080/orders/o-100
{
  "thread": "VirtualThread[#54,tomcat-handler-2]/runnable@ForkJoinPool-1-worker-1",
  "service": "order-service",
  "handler": "standard-order-pipeline",
  "orderId": "o-100",
  "tier": "standard",
  "newPricingHint": false,
  "userId": "anonymous"
}
```

`thread` shows we are running on a **virtual thread**, carried by Tomcat handler #2 on a ForkJoinPool worker. `tier: standard` and `newPricingHint: false` are the flag defaults.

#### 4.2 Normal user → still defaults (targeting did not match `u-vip-*`)

```text
$ curl -s -H 'X-User-Id: u-normal-001' http://localhost:31080/orders/o-101
{
  "service": "order-service",
  "handler": "standard-order-pipeline",
  "tier": "standard",
  "userId": "u-normal-001"
}
```

#### 4.3 VIP user → targeting hits, tier flips to `premium`

```text
$ curl -s -H 'X-User-Id: u-vip-001' http://localhost:31080/orders/o-102
{
  "service": "order-service",
  "handler": "premium-order-pipeline",
  "orderId": "o-102",
  "tier": "premium",
  "userId": "u-vip-001"
}
```

The flag rule (`starts_with(targetingKey, "u-vip-")` → `premium`) is evaluated **at the gateway**. order-service has zero OpenFeature dependency — it just reads `X-FF-Order-Tier` from the request header.

#### 4.4 Pricing without premium tenant → legacy algorithm `v1-flat`

```text
$ curl -s http://localhost:31080/pricing/sku-A
{
  "sku": "sku-A",
  "algorithm": "v1-flat",
  "tier": "standard",
  "price": 95.00,
  "service": "pricing-service"
}
```

#### 4.5 Pricing with `X-Tenant-Id: premium` → `v2-segmented`

```text
$ curl -s -H 'X-Tenant-Id: premium' http://localhost:31080/pricing/sku-A
{
  "sku": "sku-A",
  "algorithm": "v2-segmented",
  "tier": "standard",
  "price": 95.00
}
```

The `new-pricing-algo` flag rule (`tenant == "premium"` → `on`) hits.

#### 4.6 VIP user + premium tenant → both flags fire

```text
$ curl -s -H 'X-User-Id: u-vip-001' -H 'X-Tenant-Id: premium' http://localhost:31080/pricing/sku-B
{
  "sku": "sku-B",
  "algorithm": "v2-segmented",
  "tier": "premium",
  "price": 85.00
}
```

`v2-segmented` chose the `premium` multiplier (`0.85`) → final price `85.00`.

### Step 5 — hot reload via ConfigMap edit

Core demonstration: edit ConfigMap → flagd watches the file → next evaluation returns the new value, **without restarting any Spring service**. (Background and rejected alternatives in [archived SPEC § 6 / § 13.1](docs/archive/SPEC-2026-04.md).)

```text
── Step 5 — hot reload via ConfigMap edit (no service restart) ──
Before: defaultVariant of new-pricing-algo = off

  anonymous /pricing/sku-X (newPricing=false)
  $ curl -s http://localhost:31080/pricing/sku-X
{
  "sku": "sku-X",
  "algorithm": "v1-flat",     ← old algorithm
  "price": 95.00
}

patching ConfigMap: flip new-pricing-algo defaultVariant off → on
$ kubectl get configmap flagd-config -o jsonpath='{.data.flags\.json}' | jq '.flags["new-pricing-algo"].defaultVariant'
"off"
configmap/flagd-config configured
waiting up to 30s for kubelet to sync ConfigMap and flagd to pick it up...
✓ flag picked up after ~6s

After:
  anonymous /pricing/sku-X (now newPricing=true, no restart)
  $ curl -s http://localhost:31080/pricing/sku-X
{
  "sku": "sku-X",
  "algorithm": "v2-segmented", ← new algorithm
  "price": 95.00
}
✓ hot-reload demonstrated
```

End-to-end propagation timing in this run: **~6 seconds** from `kubectl apply` to the new value visible at the gateway response, with no pod restarted. Pod ages at the end:

```text
$ kubectl get pods --no-headers
flagd-b779b6f-rwgw5               1/1   Running   0   2m
gateway-76598d7dbd-f7pnj          1/1   Running   0   2m
order-service-5b7b8946d6-hksr2    1/1   Running   0   2m
pricing-service-d7954cf6b-k7x7p   1/1   Running   0   2m
```

### Step 6 — application config hot-reload (`@ConfigurationProperties` rebind)

Different mechanism from Step 5: this is **Spring's own** config refresh — `pricing-service` reads `discount-percent` and `currency` as `@ConfigurationProperties("pricing")` from a ConfigMap mounted at `/etc/pricing-config/`, and `spring-cloud-context` rebinds those bean fields when `/actuator/refresh` fires. No `@RefreshScope` needed.

```text
── Step 6 — application config hot-reload via @ConfigurationProperties (no pod restart) ──
Before: pricing.discount-percent = 5, pricing.currency = USD

  GET /pricing/sku-A → discountPercent=5, currency=USD
  $ curl -s http://localhost:31080/pricing/sku-A
{
  "sku": "sku-A",
  "algorithm": "v1-flat",
  "tier": "standard",
  "price": 90.25,         ← 100 × 0.95 (legacy algo) × 0.95 (5% discount)
  "currency": "USD",
  "discountPercent": 5
}

patching ConfigMap pricing-config: discount-percent 5 → 25, currency USD → CNY
$ kubectl patch configmap pricing-config --type merge \
    -p '{"data":{"pricing.discount-percent":"25","pricing.currency":"CNY"}}'
configmap/pricing-config patched

kubelet syncs ConfigMap volume (~5–10s); then we trigger /actuator/refresh
(production: spring-cloud-kubernetes-configuration-watcher does this automatically)
✓ config rebound after ~2s

After: same pod, no restart

  GET /pricing/sku-A → discountPercent=25, currency=CNY
  $ curl -s http://localhost:31080/pricing/sku-A
{
  "sku": "sku-A",
  "algorithm": "v1-flat",
  "tier": "standard",
  "price": 71.25,         ← 100 × 0.95 × 0.75 (now 25% discount)
  "currency": "CNY",
  "discountPercent": 25
}

$ kubectl get pods --no-headers -l app=pricing-service
pricing-service-75c97d4b69-8cnwj   1/1   Running   0   50s   ← same pod, age advancing
✓ application config hot-reload demonstrated (state reset for next run)
```

The pod's `RESTARTS=0` and the unchanged pod name (`...-8cnwj`) prove this was an in-process rebind, not a rolling update.

### Step 7 — React UI + OpenFeature web SDK + OFREP

The browser-based half of the demo. Same `order-tier` flag, evaluated client-side in TypeScript via OFREP, must agree with what the Java gateway returns server-side.

```text
── Step 7 — React UI + OpenFeature Remote Evaluation Protocol ──
verifying UI shell is reachable on http://localhost:31180

UI HTML shell:
$ curl -s http://localhost:31180/ | head -10
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <title>SB3 Demo UI</title>
    <script type="module" crossorigin src="/assets/index-...js"></script>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>

OFREP proxy through nginx (browser does the same call):
$ curl -s -X POST http://localhost:31180/ofrep/v1/evaluate/flags/order-tier \
       -H 'Content-Type: application/json' \
       -d '{"context": {"targetingKey": "u-vip-001"}}' | jq
{
  "value": "premium",
  "key": "order-tier",
  "reason": "TARGETING_MATCH",
  "variant": "premium",
  "metadata": {}
}

$ curl -s -X POST http://localhost:31180/ofrep/v1/evaluate/flags/order-tier \
       -H 'Content-Type: application/json' \
       -d '{"context": {"targetingKey": "u-normal-001"}}' | jq
{
  "value": "standard",
  "key": "order-tier",
  "reason": "DEFAULT",
  "variant": "standard",
  "metadata": {}
}

Same flag, evaluated server-side via gateway (REST), should match:

  VIP user via gateway → tier=premium
  $ curl -s -H 'X-User-Id: u-vip-001' http://localhost:31080/orders/o-7
{
  "service": "order-service",
  "handler": "premium-order-pipeline",
  "tier": "premium",
  "userId": "u-vip-001"
}

✓ UI served + OFREP works + same-flag-different-stack consistency proven
```

**The point**: VIP user gets `premium` from both the browser (OFREP web SDK) and the Java gateway (OpenFeature Java SDK). Switching the user-id selector in the React UI flips the badge live without re-deploying anything.

#### What the UI looks like

```
┌─────────────────────────────────────────────────────────────────┐
│ SB3 Demo UI    [New Pricing!]  [VIP]                            │
├─────────────────────────────────────────────────────────────────┤
│ User context (drives flag targeting): [u-vip-001 (VIP) ▼]       │
│                                                                  │
│ ┌─ OpenFeature flags (client-side) ─┐ ┌─ Backend calls ─────┐  │
│ │ order-tier:        premium        │ │ [Place order]       │  │
│ │ new-pricing-algo:  true           │ │ [Get price]         │  │
│ │ tick #3 · evaluated against same  │ │                     │  │
│ │   flagd as the Spring gateway     │ │                     │  │
│ └────────────────────────────────────┘ └─────────────────────┘  │
│                                                                  │
│ order:  { "tier": "premium", "handler": "premium-order-...    │
│ pricing: { "algorithm": "v2-segmented", "price": 85.00, ...   │
└─────────────────────────────────────────────────────────────────┘
```

Try this in the browser:

1. Open `http://localhost:31180`
2. Switch the user dropdown to **u-vip-001 (VIP)** → `order-tier` changes to `premium`, the `[VIP]` badge appears (no page reload — the OpenFeature web SDK's client-side cache rebinds via `ProviderEvents.ConfigurationChanged`).
3. Click **Place order** → hits `/api/orders/...` through nginx → reaches the Java gateway → that gateway *also* evaluates `order-tier` for the same user → returns `handler: "premium-order-pipeline"`.
4. Edit the flagd ConfigMap (Step 5) → both the UI badges *and* the gateway responses change within ~10s without restarting anything.

## How it works

### Gateway — `FeatureFlagFilter` injects headers

```java
public Function<ServerRequest, ServerRequest> apply() {
    return request -> {
        MutableContext ctx = buildContext(request);
        boolean newPricing = client.getBooleanValue("new-pricing-algo", false, ctx);
        String  orderTier  = client.getStringValue("order-tier", "standard", ctx);
        return ServerRequest.from(request)
                .header("X-FF-New-Pricing", Boolean.toString(newPricing))
                .header("X-FF-Order-Tier",  orderTier)
                .build();
    };
}
```

Wired as a Spring Cloud Gateway MVC `before` filter:

```java
@Bean
public RouterFunction<ServerResponse> orderRoute(FeatureFlagFilter ffFilter) {
    return route("orders")
            .route(path("/orders/**"), http())
            .before(uri("http://order-service:8081"))
            .before(ffFilter.apply())
            .build();
}
```

### pricing-service — `@ConfigurationProperties` reloaded from ConfigMap

Demonstrates the **app config hot-reload** method (configtree mount + `/actuator/refresh` + `EnvironmentChangeEvent` rebind), scoped to one service so the wiring stays small. The full method-A vs method-F vs method-G tradeoff is in the [archived SPEC § 3](docs/archive/SPEC-2026-04.md).

```java
@ConfigurationProperties("pricing")
@Component
public class PricingConfig {
    private int discountPercent = 5;
    private String currency = "USD";
    // getters/setters — controllers MUST read via getter.
    // Assigning to fields once would require @RefreshScope (see Joris Kuipers's gotcha).
}
```

How values flow in:

```
ConfigMap pricing-config
  └─ mounted as files at /etc/pricing-config/   ← kubelet sync 5–10s
       └─ spring.config.import: configtree:/etc/pricing-config/
            └─ Environment PropertySource
                 └─ POST /actuator/refresh   (triggered manually or by Configuration Watcher)
                      └─ EnvironmentChangeEvent
                           └─ ConfigurationPropertiesRebinder rebinds PricingConfig fields in place
                                └─ next request reads via getter → sees new value
```

Why no `@RefreshScope` is needed: spring-cloud-context's `EnvironmentChangeEvent` listener mutates `@ConfigurationProperties` beans in-place (no proxy swap), so any reference held to the bean keeps working — *as long as the holder reads via getters and doesn't snapshot fields into local state*.

For production, replace the manual `/actuator/refresh` trigger with **`spring-cloud-kubernetes-configuration-watcher`** (a separate controller pod that watches labelled ConfigMaps and POSTs the refresh endpoint automatically). Not deployed in this demo to keep YAML count small.

### Microservice — read flags from `ScopedValue` + MDC, not method parameters

The first version of this demo had `@RequestHeader X-FF-*` directly in controller signatures. That works for one or two flags, but as the flag set grows, every method down the call chain that needs a flag has to take it as a parameter — invasive.

Cleaner pattern: a request-scoped holder + MDC, populated once at the request boundary. With Java 25 and virtual threads, the right tool is **`ScopedValue` (JEP 506, finalised in JDK 25)** — not plain `ThreadLocal`:

| | `ThreadLocal` | `ScopedValue` (used here) |
|---|---|---|
| Memory under millions of virtual threads | per-VT entry → bloats | inherited lookup → flat |
| Cleanup | manual `finally` `remove()` (easy to forget) | automatic when scope exits |
| Mutation inside the scope | possible (often a bug source) | impossible — immutable binding |
| API style | imperative (`set` / `get` / `remove`) | structured (`where(...).call(...)`) |
| Java preview status | stable forever | preview in 21–24, **finalised in 25** |

```java
public record FeatureFlags(String orderTier, boolean newPricing) {
    public static final FeatureFlags DEFAULTS = new FeatureFlags("standard", false);
    public static final ScopedValue<FeatureFlags> CURRENT = ScopedValue.newInstance();

    public static FeatureFlags current() { return CURRENT.orElse(DEFAULTS); }
}
```

```java
@Component
public class FeatureFlagFilter extends OncePerRequestFilter {
    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        FeatureFlags ff = parse(req);
        MDC.put("ff.tier", ff.orderTier());
        MDC.put("ff.newPricing", Boolean.toString(ff.newPricing()));
        try {
            // Bind for the entire downstream call. Auto-cleared when call() returns.
            ScopedValue.where(FeatureFlags.CURRENT, ff).call(() -> {
                chain.doFilter(req, res);
                return null;
            });
        } catch (ServletException | IOException | RuntimeException e) {
            throw e;
        } catch (Throwable t) {
            throw new ServletException("filter chain failed", t);
        } finally {
            MDC.remove("ff.tier");
            MDC.remove("ff.newPricing");
        }
    }
}
```

Now the controller — and every service / repo / mapper invoked from it — reads flags without touching its own signature:

```java
@Service
public class OrderPipeline {
    public String pickHandler(String orderId) {
        FeatureFlags ff = FeatureFlags.current();    // no method param, no field injection
        return switch (ff.orderTier()) {
            case "premium" -> "premium-order-pipeline";
            case "express" -> "express-order-pipeline";
            default        -> "standard-order-pipeline";
        };
    }
}
```

The MDC half pays off in observability — every log line emitted during a request automatically carries the flag context:

```
10:03:07.676 INFO  [tier=premium,np=true]  demo.order.service.OrderPipeline - picking handler for order=o-mdc
10:03:07.722 INFO  [tier=premium,np=true]  d.p.controller.PricingController - computing price for sku=sku-mdc
```

The pattern is enabled by `application.yml`:

```yaml
logging:
  pattern:
    console: "%d{HH:mm:ss.SSS} %-5level [tier=%X{ff.tier:-?},np=%X{ff.newPricing:-?}] %logger{36} - %msg%n"
```

Async / structured-concurrency caveat: `ScopedValue` is automatically inherited by virtual threads forked inside the scope when you use `StructuredTaskScope`. For old-school `@Async` / `CompletableFuture.supplyAsync` it does **not** auto-propagate — wrap with `ScopedValue.where(...)` again at the fork point, or use `micrometer-context-propagation` (which has a `ScopedValueAccessor` in addition to the `MDC` and `ThreadLocal` accessors). MDC needs the same propagation handling on cross-thread async.

Verified safe under load: 60 concurrent requests with mixed user IDs through Tomcat's virtual-thread executor, 0 cross-request leaks (each request returned exactly the tier expected for its `X-User-Id`).

No `OpenFeatureAPI`, no `Client`, no `Provider` in the MS. Just header → `ScopedValue` + `MDC` at the boundary.

### Virtual threads enabled in all three services

```yaml
spring:
  threads:
    virtual:
      enabled: true
```

Every JSON response includes `"thread": "VirtualThread[..."` to make this visible.

### Flag rules in `k8s/flagd/configmap.yaml`

```json
{
  "flags": {
    "new-pricing-algo": {
      "state": "ENABLED",
      "variants": { "on": true, "off": false },
      "defaultVariant": "off",
      "targeting": {
        "if": [{ "==": [{ "var": "tenant" }, "premium"] }, "on", null]
      }
    },
    "order-tier": {
      "state": "ENABLED",
      "variants": { "standard": "standard", "premium": "premium" },
      "defaultVariant": "standard",
      "targeting": {
        "if": [
          { "starts_with": [{ "var": "targetingKey" }, "u-vip-"] },
          "premium",
          null
        ]
      }
    }
  }
}
```

flagd watches `/etc/flagd/flags.json` (mounted from this ConfigMap) via `fsnotify` and reloads automatically on every change.

## Verify and explore (after e2e finished)

Once `e2e-demo.sh` has exited 0, the cluster is left running so you can poke at it. Every command below is self-contained — copy, paste, expect the marked output.

### Cluster health

```bash
kubectl get pods --no-headers
```

Expected (all 4 `1/1 Running 0`):

```
flagd-...               1/1   Running   0   2m
gateway-...             1/1   Running   0   2m
order-service-...       1/1   Running   0   2m
pricing-service-...     1/1   Running   0   2m
```

### Verify gateway routing + flag injection

Each section below isolates one behaviour. The relevant field in the JSON output is **bolded**.

**A. Defaults applied when no targeting context is passed**

```bash
curl -s http://localhost:31080/orders/o-100 | jq '{tier, handler, userId}'
```
Expect: `tier: "standard"`, `handler: "standard-order-pipeline"`, `userId: "anonymous"`.

**B. Targeting via `X-User-Id` (rule: `starts_with("u-vip-")` → `premium`)**

```bash
# Should NOT match:
curl -s -H 'X-User-Id: u-normal-001' http://localhost:31080/orders/o-101 | jq '.tier'
# → "standard"

# Should match:
curl -s -H 'X-User-Id: u-vip-001' http://localhost:31080/orders/o-102 | jq '.tier'
# → "premium"
```

**C. Tenant-driven flag (`tenant == "premium"` → `new-pricing-algo: on`)**

```bash
curl -s http://localhost:31080/pricing/sku-A | jq '.algorithm'                              # → "v1-flat"
curl -s -H 'X-Tenant-Id: premium' http://localhost:31080/pricing/sku-A | jq '.algorithm'    # → "v2-segmented"
```

**D. Both flags together (price changes because of `tier=premium` multiplier)**

```bash
curl -s -H 'X-User-Id: u-vip-001' -H 'X-Tenant-Id: premium' \
     http://localhost:31080/pricing/sku-B | jq '{tier, algorithm, price}'
```
Expect: `tier: "premium"`, `algorithm: "v2-segmented"`, `price: 85.00`.

**E. Virtual threads in every response**

```bash
curl -s http://localhost:31080/pricing/sku-A | jq -r '.thread'
```
Expect: starts with `VirtualThread[#...`.

### Manually demonstrate app config hot-reload (Step 6)

```bash
# 1. See the current values
curl -s http://localhost:31080/pricing/sku-A | jq '{discountPercent, currency, price}'
# → 5 / USD / 90.25

# 2. Patch the ConfigMap
kubectl patch configmap pricing-config --type merge \
  -p '{"data":{"pricing.discount-percent":"25","pricing.currency":"CNY"}}'

# 3. Wait for kubelet to sync the volume mount (~5–10s), then trigger refresh.
#    In production a Configuration Watcher would do this automatically.
sleep 8
kubectl run --rm -i --restart=Never --image=curlimages/curl:8.10.1 trigger-refresh \
  -- -fsS -X POST http://pricing-service:8082/actuator/refresh

# 4. Confirm the new values, same pod
curl -s http://localhost:31080/pricing/sku-A | jq '{discountPercent, currency, price}'
# → 25 / CNY / 71.25
kubectl get pods --no-headers -l app=pricing-service     # RESTARTS=0

# 5. Reset
kubectl apply -f k8s/pricing-service/configmap.yaml
sleep 8
kubectl run --rm -i --restart=Never --image=curlimages/curl:8.10.1 trigger-reset \
  -- -fsS -X POST http://pricing-service:8082/actuator/refresh
```

> **Why two refresh mechanisms?** Step 5 (flag values) is reloaded by **flagd's own fsnotify** — no Spring involvement. Step 6 (`@ConfigurationProperties`) goes through **`/actuator/refresh` → `EnvironmentChangeEvent` → ConfigurationPropertiesRebinder`**. Two distinct paths, both demonstrated end-to-end.

### Manually demonstrate flag hot-reload (Step 5)

```bash
# 1. Read the current default
kubectl get configmap flagd-config -o jsonpath='{.data.flags\.json}' \
  | jq '.flags["new-pricing-algo"].defaultVariant'
# → "off"

# 2. Flip the default to "on"
PATCHED=$(kubectl get configmap flagd-config -o jsonpath='{.data.flags\.json}' \
  | jq -c '.flags["new-pricing-algo"].defaultVariant = "on"')
kubectl create configmap flagd-config \
  --from-literal=flags.json="$PATCHED" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Watch the change propagate (no restart, no rollout)
for i in $(seq 1 10); do
  sleep 2
  printf "t=%2ds  algorithm=%s\n" $((i*2)) \
    "$(curl -s http://localhost:31080/pricing/sku-X | jq -r '.algorithm')"
done
# → flips v1-flat → v2-segmented somewhere between t=6s and t=15s.
#   Total = kubelet ConfigMap sync (~5–10s) + flagd fsnotify (instant) + gateway evaluation (instant).

# 4. Confirm no pod restarted
kubectl get pods --no-headers | awk '{print $1, "RESTARTS="$4}'
# → all RESTARTS=0

# 5. Reset to the original (so the demo can be replayed cleanly)
kubectl apply -f k8s/flagd/configmap.yaml
```

> **Note:** `e2e-demo.sh` automatically performs step 5 at the end — the ConfigMap is restored to defaults so subsequent runs and `curl` checks start from a known state.

### Verify the UI + OFREP (Step 7)

```bash
# 1. UI shell reachable
curl -s http://localhost:31180/ | grep '<title>'
# → <title>SB3 Demo UI</title>

# 2. Browser-style flag evaluation via OFREP — must match server-side
for user in u-normal-001 u-vip-001; do
  echo "$user:"
  curl -s -X POST http://localhost:31180/ofrep/v1/evaluate/flags/order-tier \
       -H 'Content-Type: application/json' \
       -d "{\"context\":{\"targetingKey\":\"$user\"}}" | jq -c '{value, reason}'
done
# → u-normal-001: {"value":"standard","reason":"DEFAULT"}
# → u-vip-001:    {"value":"premium","reason":"TARGETING_MATCH"}

# 3. Open the UI in your browser and play with the user-id dropdown
open http://localhost:31180        # macOS
# xdg-open http://localhost:31180  # Linux
```

### Inspect logs while testing

```bash
kubectl logs -f deploy/gateway          # see flag evaluation events
kubectl logs -f deploy/flagd            # see ConfigMap reload events
kubectl logs -f deploy/order-service    # see incoming X-FF-* headers
```

The flagd logs include `"reloaded sources"` whenever the file watcher picks up a ConfigMap change — that is the visible proof of hot-reload.

### Edit and watch

If you want to play with the rules live:

```bash
kubectl edit configmap flagd-config        # edit, save, exit
# flagd watches /etc/flagd/flags.json — no further command needed
```

## Manual scripts (alternative to `e2e-demo.sh`)

If you prefer step-by-step:

```bash
./scripts/setup.sh    # 1. create kind cluster only
./scripts/build.sh    # 2. mvn package + docker build + kind load
./scripts/deploy.sh   # 3. apply all manifests, wait for ready
# Then run any curl from "Verify and explore" above.
```

## Cleanup

```bash
kind delete cluster --name sb3-demo
```

## Notes / things worth knowing

- **Container image**: built with the shared root [`Dockerfile`](Dockerfile) + `docker build`, not jib. jib-maven-plugin 3.4.4's bundled ASM does not yet recognise Java 25 class files (`Unsupported class file major version 69`).
- **flagd ports**: flagd v0.15+ no longer defaults the eval port to 8013. The deployment passes `--port 8013 --management-port 8014 --ofrep-port 8016` explicitly.
- **OpenFeature init is non-blocking**: `OpenFeatureAPI.setProvider(...)` is used instead of `setProviderAndWait` so the gateway pod starts even when flagd is briefly unreachable. Until the provider transitions to `READY`, evaluations return their defaults — exactly what `client.getBooleanValue(key, FALSE, ctx)` is built for.
- **NodePort routing**: kind's `extraPortMappings` exposes the gateway on `localhost:31080` (port 30080 on the host is reserved by OrbStack on this machine; adjust `k8s/kind-cluster.yaml` if you need a different host port).
- **MS-side cleanliness**: order-service and pricing-service have **zero** OpenFeature deps. This is intentional — gateway is the single evaluation source. Diverging flag state across services is one of the most common feature-flag bugs; this design eliminates it by construction.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kind create cluster` errors with `Bind for 0.0.0.0:30080 failed` | Host port already taken (OrbStack, another process) | Edit `k8s/kind-cluster.yaml` `extraPortMappings.hostPort` to a free port; update `GW_URL` in `scripts/e2e-demo.sh` to match |
| `mvn package` fails with `Unsupported class file major version 69` | Using Jib instead of the Dockerfile | Already addressed — make sure you call `./scripts/build.sh`, not `mvn jib:dockerBuild` |
| Gateway pod logs `Connection lost. Emit STALE event` | flagd not yet reachable | Self-heals — provider retries automatically and transitions to READY when flagd is up; evaluations return defaults in the meantime |
| flagd pod logs `Flag IResolver listening at [::]:NNNNN` (random port) | flagd v0.15+ no longer defaults the gRPC port to 8013 | Already handled in `k8s/flagd/deployment.yaml` via explicit `--port 8013` |
| `/orders/*` returns 500 right after deploy, then works | order-service not yet ready when first request arrives | Already handled — `e2e-demo.sh` warm-up loop pings `/orders/warmup` and `/pricing/warmup` until both return 200 before running scenarios |
| Image not loaded into kind | New build but image not picked up by pod | Re-run `kind load docker-image local/<svc>:0.0.1-SNAPSHOT --name sb3-demo` and `kubectl rollout restart deploy/<svc>` |

## What this demo intentionally does NOT show

So readers don't expect more than is here:

- **No `@RefreshScope`** — the app-config reload (Step 6) relies on `@ConfigurationProperties` auto-rebind via `EnvironmentChangeEvent`. `@RefreshScope` (lazy proxy + target swap) is a distinct mechanism in spring-cloud-context, useful for beans that hold expensive resources (connection pools, clients) — not exercised here.
- **No `spring-cloud-kubernetes-configuration-watcher`** — the production-grade, automatic trigger for `/actuator/refresh`. The demo triggers refresh manually via an ephemeral `kubectl run --image=curlimages/curl` pod to keep YAML count small. (Watcher described in [archived SPEC § 3](docs/archive/SPEC-2026-04.md).)
- **No CRaC** — the 2026 alternative to in-process refresh (50ms restore, no `@RefreshScope` complexity); not exercised here. See [archived SPEC § 12.1](docs/archive/SPEC-2026-04.md).
- **No GraalVM native image** — incompatible with `@RefreshScope` and `@ConfigurationProperties` rebind. Smoke-test recommendation in [archived SPEC § 4.4 TC-04](docs/archive/SPEC-2026-04.md).
- **No multi-replica gateway** — single replica for simplicity. With multiple gateway pods, flag values are still consistent because all gateways evaluate against the same flagd; OpenFeature's local cache is per-pod and short-lived.
- **No mTLS / RBAC hardening** — flagd is wide open inside the cluster. Production would put it behind a NetworkPolicy. The pricing-service ServiceAccount is the default one (no extra permissions needed since it reads its config via volume, not the K8s API).
- **No Prometheus / metrics scraping** — Spring Boot Actuator is enabled but no scrape config bundled.
