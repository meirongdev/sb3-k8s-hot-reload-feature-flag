# E-commerce OpenFeature Scenarios Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the repo into a single e-commerce reference architecture that demonstrates backend-only, frontend-only, and full-stack feature-flag flows and verifies them with an automated end-to-end POC runner.

**Architecture:** Keep flagd as the single source of truth, keep OpenFeature Java centralized in the gateway for backend/shared business flags, and keep OpenFeature web SDK in the browser only for presentation-safe flags. Reuse the existing order-service, pricing-service, UI, and ConfigMap refresh path, but add a gateway snapshot endpoint, a backend-only propagated flag, and a scenario-first UI and README.

**Tech Stack:** Spring Boot 3.5, Spring Cloud Gateway MVC, Java 25, OpenFeature Java SDK, flagd, React 18, Vite, nginx, kind, shell-based E2E verification with curl/jq/kubectl.

---

## File map

- Modify: `gateway/src/main/java/demo/gateway/filter/FeatureFlagFilter.java` — inject the expanded evaluated snapshot into downstream requests.
- Create: `gateway/src/main/java/demo/gateway/flags/FeatureFlagSnapshot.java` — typed snapshot for all evaluated gateway flags.
- Create: `gateway/src/main/java/demo/gateway/flags/FeatureFlagSnapshotResolver.java` — builds evaluation context and resolves backend/shared/frontend flag values.
- Create: `gateway/src/main/java/demo/gateway/controller/FeatureFlagSnapshotController.java` — exposes shared snapshot JSON for the UI.
- Modify: `order-service/src/main/java/demo/order/flags/FeatureFlags.java` — add backend-only fulfillment flag.
- Modify: `order-service/src/main/java/demo/order/flags/FeatureFlagFilter.java` — read the new propagated header.
- Modify: `order-service/src/main/java/demo/order/service/OrderPipeline.java` — choose backend route using the new flag.
- Modify: `order-service/src/main/java/demo/order/controller/OrderController.java` — surface backend-only result fields.
- Modify: `pricing-service/src/main/java/demo/pricing/controller/PricingController.java` — keep full-stack semantics explicit in the response.
- Modify: `ui/src/App.tsx` — split the page into frontend-only, backend-only, and full-stack sections.
- Modify: `ui/src/api.ts` — add calls for the shared snapshot endpoint and tenant-aware requests.
- Modify: `ui/src/openfeature.ts` — keep OFREP for frontend-only presentation flags.
- Modify: `k8s/flagd/configmap.yaml` — define backend-only, frontend-only, and shared flags.
- Modify: `README.md` — reframe docs around the three-scenario architecture.
- Modify: `scripts/e2e-demo.sh` — convert output-only walkthrough into an assertion-based scenario verifier.

### Task 1: Gateway snapshot resolver and shared snapshot endpoint

**Files:**
- Create: `gateway/src/main/java/demo/gateway/flags/FeatureFlagSnapshot.java`
- Create: `gateway/src/main/java/demo/gateway/flags/FeatureFlagSnapshotResolver.java`
- Create: `gateway/src/main/java/demo/gateway/controller/FeatureFlagSnapshotController.java`
- Modify: `gateway/src/main/java/demo/gateway/filter/FeatureFlagFilter.java`

- [ ] **Step 1: Add the failing E2E assertion for the shared snapshot endpoint**

```bash
# scripts/e2e-demo.sh
shared=$(curl -s -H 'X-User-Id: u-vip-001' -H 'X-Tenant-Id: premium' \
  "${GW_URL}/experience/shared-flags")
[[ "$(echo "$shared" | jq -r '.orderTier')" == "premium" ]] || {
  echo "expected shared snapshot orderTier=premium"; exit 1;
}
[[ "$(echo "$shared" | jq -r '.newPricing')" == "true" ]] || {
  echo "expected shared snapshot newPricing=true"; exit 1;
}
```

- [ ] **Step 2: Run the E2E flow to confirm the new check fails**

Run: `./scripts/e2e-demo.sh`  
Expected: FAIL because `/experience/shared-flags` does not exist yet or returns a non-matching payload.

- [ ] **Step 3: Add the minimal gateway snapshot implementation**

```java
// gateway/src/main/java/demo/gateway/flags/FeatureFlagSnapshot.java
package demo.gateway.flags;

public record FeatureFlagSnapshot(
        String orderTier,
        boolean newPricing,
        String fulfillmentMode,
        String homepageBanner,
        boolean memberPerks) {
}
```

```java
// gateway/src/main/java/demo/gateway/flags/FeatureFlagSnapshotResolver.java
package demo.gateway.flags;

import dev.openfeature.sdk.Client;
import dev.openfeature.sdk.MutableContext;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.function.ServerRequest;

import java.util.Optional;

@Component
public class FeatureFlagSnapshotResolver {
    private final Client client;

    public FeatureFlagSnapshotResolver(Client client) {
        this.client = client;
    }

    public FeatureFlagSnapshot resolve(ServerRequest request) {
        MutableContext ctx = new MutableContext();
        Optional.ofNullable(request.headers().firstHeader("X-User-Id")).ifPresent(ctx::setTargetingKey);
        Optional.ofNullable(request.headers().firstHeader("X-Tenant-Id")).ifPresent(v -> ctx.add("tenant", v));
        return new FeatureFlagSnapshot(
                client.getStringValue("order-tier", "standard", ctx),
                client.getBooleanValue("new-pricing-algo", false, ctx),
                client.getStringValue("ops-fulfillment-mode", "standard", ctx),
                client.getStringValue("ui-homepage-banner", "control", ctx),
                client.getBooleanValue("ui-member-perks", false, ctx)
        );
    }
}
```

```java
// gateway/src/main/java/demo/gateway/controller/FeatureFlagSnapshotController.java
package demo.gateway.controller;

import demo.gateway.flags.FeatureFlagSnapshot;
import demo.gateway.flags.FeatureFlagSnapshotResolver;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.function.ServerRequest;

@RestController
public class FeatureFlagSnapshotController {
    private final FeatureFlagSnapshotResolver resolver;

    public FeatureFlagSnapshotController(FeatureFlagSnapshotResolver resolver) {
        this.resolver = resolver;
    }

    @GetMapping("/experience/shared-flags")
    public FeatureFlagSnapshot sharedFlags(ServerRequest request) {
        return resolver.resolve(request);
    }
}
```

- [ ] **Step 4: Wire the filter to reuse the same resolver**

```java
// gateway/src/main/java/demo/gateway/filter/FeatureFlagFilter.java
FeatureFlagSnapshot snapshot = resolver.resolve(request);
return ServerRequest.from(request)
        .header("X-FF-New-Pricing", Boolean.toString(snapshot.newPricing()))
        .header("X-FF-Order-Tier", snapshot.orderTier())
        .header("X-FF-Fulfillment-Mode", snapshot.fulfillmentMode())
        .build();
```

- [ ] **Step 5: Re-run the gateway-specific scenario**

Run: `./scripts/e2e-demo.sh`  
Expected: the shared snapshot check passes, even if later scenario checks still fail.

### Task 2: Backend-only fulfillment flag propagation

**Files:**
- Modify: `order-service/src/main/java/demo/order/flags/FeatureFlags.java`
- Modify: `order-service/src/main/java/demo/order/flags/FeatureFlagFilter.java`
- Modify: `order-service/src/main/java/demo/order/service/OrderPipeline.java`
- Modify: `order-service/src/main/java/demo/order/controller/OrderController.java`

- [ ] **Step 1: Add the failing backend-only E2E assertion**

```bash
backend_only=$(curl -s -H 'X-Tenant-Id: premium' "${GW_URL}/orders/o-201")
[[ "$(echo "$backend_only" | jq -r '.fulfillmentMode')" == "express" ]] || {
  echo "expected backend-only fulfillmentMode=express"; exit 1;
}
[[ "$(echo "$backend_only" | jq -r '.handler')" == "express-order-pipeline" ]] || {
  echo "expected backend-only express handler"; exit 1;
}
```

- [ ] **Step 2: Run the E2E flow to confirm the backend-only assertions fail**

Run: `./scripts/e2e-demo.sh`  
Expected: FAIL because `X-FF-Fulfillment-Mode` is not yet parsed or surfaced by order-service.

- [ ] **Step 3: Extend the request-scoped snapshot**

```java
// order-service/src/main/java/demo/order/flags/FeatureFlags.java
public record FeatureFlags(String orderTier, boolean newPricing, String fulfillmentMode) {
    public static final FeatureFlags DEFAULTS =
            new FeatureFlags("standard", false, "standard");
}
```

```java
// order-service/src/main/java/demo/order/flags/FeatureFlagFilter.java
static final String H_FULFILLMENT_MODE = "X-FF-Fulfillment-Mode";

private static FeatureFlags parse(HttpServletRequest req) {
    String tier = req.getHeader(H_TIER);
    String np = req.getHeader(H_NEW_PRICING);
    String mode = req.getHeader(H_FULFILLMENT_MODE);
    return new FeatureFlags(
            tier != null ? tier : FeatureFlags.DEFAULTS.orderTier(),
            "true".equalsIgnoreCase(np),
            mode != null ? mode : FeatureFlags.DEFAULTS.fulfillmentMode());
}
```

- [ ] **Step 4: Make the backend-only decision visible**

```java
// order-service/src/main/java/demo/order/service/OrderPipeline.java
return switch (ff.fulfillmentMode()) {
    case "express" -> "express-order-pipeline";
    default -> switch (ff.orderTier()) {
        case "premium" -> "premium-order-pipeline";
        default -> "standard-order-pipeline";
    };
};
```

```java
// order-service/src/main/java/demo/order/controller/OrderController.java
body.put("fulfillmentMode", ff.fulfillmentMode());
```

- [ ] **Step 5: Re-run the backend-only scenario**

Run: `./scripts/e2e-demo.sh`  
Expected: backend-only assertions pass and later checks move forward.

### Task 3: Frontend-only and full-stack UI scenarios

**Files:**
- Modify: `ui/src/App.tsx`
- Modify: `ui/src/api.ts`
- Modify: `ui/src/openfeature.ts`
- Modify: `k8s/flagd/configmap.yaml`

- [ ] **Step 1: Add the failing frontend-only assertions**

```bash
banner=$(curl -s -X POST "${UI_URL}/ofrep/v1/evaluate/flags/ui-homepage-banner" \
  -H 'Content-Type: application/json' \
  -d '{"context":{"targetingKey":"u-vip-001"}}')
[[ "$(echo "$banner" | jq -r '.value')" == "spring-sale" ]] || {
  echo "expected ui-homepage-banner=spring-sale"; exit 1;
}

perks=$(curl -s -X POST "${UI_URL}/ofrep/v1/evaluate/flags/ui-member-perks" \
  -H 'Content-Type: application/json' \
  -d '{"context":{"targetingKey":"u-normal-001"}}')
[[ "$(echo "$perks" | jq -r '.value')" == "false" ]] || {
  echo "expected ui-member-perks=false for regular user"; exit 1;
}
```

- [ ] **Step 2: Extend flagd config with explicit scenario flags**

```json
"ops-fulfillment-mode": {
  "state": "ENABLED",
  "variants": { "standard": "standard", "express": "express" },
  "defaultVariant": "standard",
  "targeting": { "if": [ { "==": [ { "var": "tenant" }, "premium" ] }, "express", null ] }
},
"ui-homepage-banner": {
  "state": "ENABLED",
  "variants": { "control": "control", "spring-sale": "spring-sale" },
  "defaultVariant": "control",
  "targeting": { "if": [ { "starts_with": [ { "var": "targetingKey" }, "u-vip-" ] }, "spring-sale", null ] }
},
"ui-member-perks": {
  "state": "ENABLED",
  "variants": { "on": true, "off": false },
  "defaultVariant": "off",
  "targeting": { "if": [ { "starts_with": [ { "var": "targetingKey" }, "u-vip-" ] }, "on", null ] }
}
```

- [ ] **Step 3: Add shared snapshot and tenant-aware UI API calls**

```ts
// ui/src/api.ts
export type SharedFlagsResponse = {
  orderTier: string
  newPricing: boolean
  fulfillmentMode: string
}

export async function fetchSharedFlags(userId: string | null, tenantId: string | null) {
  const r = await fetch('/api/experience/shared-flags', {
    headers: headers(userId, tenantId),
  })
  if (!r.ok) throw new Error(`shared flags request failed: ${r.status}`)
  return r.json() as Promise<SharedFlagsResponse>
}
```

- [ ] **Step 4: Rework the page into three scenario sections**

```tsx
// ui/src/App.tsx
<section>
  <h2>Frontend-only flags</h2>
  <div>Banner variant: <code>{homepageBanner}</code></div>
  <div>Member perks: <code>{String(memberPerks)}</code></div>
</section>

<section>
  <h2>Backend-only flag</h2>
  <div>Fulfillment mode from backend: <code>{order?.fulfillmentMode}</code></div>
</section>

<section>
  <h2>Full-stack flags</h2>
  <div>Gateway shared snapshot: <code>{shared?.orderTier}</code></div>
  <div>Backend pricing response: <code>{pricing?.algorithm}</code></div>
</section>
```

- [ ] **Step 5: Build the UI and re-run the flow**

Run: `cd ui && npm run build && cd .. && ./scripts/e2e-demo.sh`  
Expected: frontend-only OFREP assertions pass, the UI still builds, and the full-stack flow continues to later checks.

### Task 4: README rewrite and strict end-to-end verification

**Files:**
- Modify: `README.md`
- Modify: `scripts/e2e-demo.sh`

- [ ] **Step 1: Turn `e2e-demo.sh` into an assertion runner**

```bash
assert_eq() {
  local actual="$1" expected="$2" message="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "ASSERT FAIL: ${message} (expected=${expected}, actual=${actual})"
    exit 1
  }
}
```

```bash
assert_eq "$(echo "$backend_only" | jq -r '.fulfillmentMode')" "express" \
  "premium tenant should use express fulfillment"
assert_eq "$(echo "$shared" | jq -r '.orderTier')" "premium" \
  "vip user should get premium shared tier"
```

- [ ] **Step 2: Keep hot-reload verification as part of the same run**

```bash
assert_eq "$(curl -s "${GW_URL}/pricing/sku-X" | jq -r '.algorithm')" "v2-segmented" \
  "flag hot-reload should flip pricing algorithm"
assert_eq "$(curl -s "${GW_URL}/pricing/sku-A" | jq -r '.discountPercent')" "25" \
  "config refresh should rebind pricing discount"
```

- [ ] **Step 3: Rewrite the README around the three scenarios**

```md
## What this project demonstrates

1. Backend-only flags — gateway evaluates operational flags and propagates a snapshot to services
2. Frontend-only flags — browser evaluates presentation-safe flags through OpenFeature web SDK + OFREP
3. Full-stack flags — gateway and UI present the same business semantics while downstream services remain OpenFeature-free
```

- [ ] **Step 4: Run the full repo verification**

Run:

```bash
mvn -q -DskipTests package
cd ui && npm run build && cd ..
./scripts/e2e-demo.sh
```

Expected:
- Maven build succeeds
- UI build succeeds
- E2E script exits `0`
- Output proves backend-only, frontend-only, full-stack, hot-reload, and config-refresh scenarios

- [ ] **Step 5: Commit**

```bash
git add README.md scripts/e2e-demo.sh gateway order-service pricing-service ui k8s docs/superpowers/specs docs/superpowers/plans
git commit -m "feat: redesign demo around flag scenarios"
```

## Self-review

- **Spec coverage:** backend-only, frontend-only, full-stack, docs, and automated verification all map to Tasks 1-4.
- **Placeholder scan:** no TBD/TODO markers remain; every task names exact files and concrete commands.
- **Type consistency:** the plan consistently uses `FeatureFlagSnapshot`, `fulfillmentMode`, `/experience/shared-flags`, `ui-homepage-banner`, and `ui-member-perks`.
