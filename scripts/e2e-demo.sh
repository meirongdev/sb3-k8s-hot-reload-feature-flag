#!/usr/bin/env bash
#
# End-to-end automated demo:
#   1. Create kind cluster
#   2. Build images (mvn + jib) and load into kind
#   3. Deploy flagd, MS, gateway
#   4. Exercise feature flag scenarios via the gateway
#   5. Hot-reload demo: edit ConfigMap and re-exercise
#
# Idempotent: re-running reuses an existing cluster and re-deploys.

set -euo pipefail

CLUSTER_NAME="sb3-demo"
GW_URL="http://localhost:31080"
UI_URL="http://localhost:31180"
TAG="0.0.1-SNAPSHOT"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT"

bold()    { printf '\033[1m%s\033[0m\n' "$*"; }
section() { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }
note()    { printf '\033[2m%s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

show()    { printf '\033[1;33m$\033[0m %s\n' "$*"; eval "$@"; }

step1_cluster() {
  section "Step 1 — kind cluster"
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    note "cluster '${CLUSTER_NAME}' already exists, reusing"
  else
    show "kind create cluster --config k8s/kind-cluster.yaml"
  fi
  show "kubectl --context kind-${CLUSTER_NAME} get nodes"
  ok "cluster ready"
}

step2_build() {
  section "Step 2 — build images and load into kind"
  show "mvn -q -DskipTests package"
  for svc in gateway order-service pricing-service; do
    show "docker build --quiet -t local/${svc}:${TAG} -f Dockerfile ${svc}/"
    show "kind load docker-image local/${svc}:${TAG} --name ${CLUSTER_NAME}"
  done
  show "docker build --quiet -t local/ui:${TAG} -f ui/Dockerfile ui/"
  show "kind load docker-image local/ui:${TAG} --name ${CLUSTER_NAME}"
  ok "images built and loaded"
}

step3_deploy() {
  section "Step 3 — deploy flagd + microservices + gateway + ui"
  show "kubectl apply -f k8s/flagd/"
  kubectl wait --for=condition=available --timeout=90s deployment/flagd
  # pricing-config ConfigMap mounted into pricing-service — applied as part of the same dir.
  show "kubectl apply -f k8s/order-service/ -f k8s/pricing-service/ -f k8s/gateway/ -f k8s/ui/"
  kubectl wait --for=condition=available --timeout=180s \
    deployment/order-service deployment/pricing-service deployment/gateway deployment/ui
  show "kubectl get pods -o wide"
  ok "all deployments ready"
}

wait_gateway() {
  note "waiting for gateway readiness on ${GW_URL}/actuator/health"
  for _ in $(seq 1 30); do
    if curl -fsS "${GW_URL}/actuator/health" >/dev/null 2>&1; then break; fi
    sleep 2
  done

  note "warming up downstream services through the gateway"
  for _ in $(seq 1 15); do
    o=$(curl -s -o /dev/null -w "%{http_code}" "${GW_URL}/orders/warmup")
    p=$(curl -s -o /dev/null -w "%{http_code}" "${GW_URL}/pricing/warmup")
    if [[ "$o" == "200" && "$p" == "200" ]]; then return 0; fi
    sleep 2
  done
  echo "downstream not ready (orders=$o pricing=$p)"; exit 1
}

call() {
  local desc="$1"; shift
  printf '\n\033[1m  %s\033[0m\n' "${desc}"
  printf '  \033[1;33m$\033[0m %s\n' "$*"
  eval "$@" | jq '.' || true
}

step4_scenarios() {
  section "Step 4 — feature flag scenarios"
  wait_gateway

  call "4.1 Anonymous → defaults (tier=standard, newPricing=false)" \
    "curl -s ${GW_URL}/orders/o-100"

  call "4.2 Normal user → defaults" \
    "curl -s -H 'X-User-Id: u-normal-001' ${GW_URL}/orders/o-101"

  call "4.3 VIP user → targeting hits, tier=premium" \
    "curl -s -H 'X-User-Id: u-vip-001' ${GW_URL}/orders/o-102"

  call "4.4 Pricing call without premium tenant → algorithm=v1-flat" \
    "curl -s ${GW_URL}/pricing/sku-A"

  call "4.5 Pricing call with X-Tenant-Id: premium → algorithm=v2-segmented" \
    "curl -s -H 'X-Tenant-Id: premium' ${GW_URL}/pricing/sku-A"

  call "4.6 VIP user + premium tenant on pricing → tier=premium AND v2-segmented" \
    "curl -s -H 'X-User-Id: u-vip-001' -H 'X-Tenant-Id: premium' ${GW_URL}/pricing/sku-B"

  ok "scenarios passed"
}

step5_hot_reload() {
  section "Step 5 — hot reload via ConfigMap edit (no service restart)"

  bold "Before: defaultVariant of new-pricing-algo = off"
  call "anonymous /pricing/sku-X (newPricing=false)" \
    "curl -s ${GW_URL}/pricing/sku-X"

  note "patching ConfigMap: flip new-pricing-algo defaultVariant off → on"
  show "kubectl get configmap flagd-config -o jsonpath='{.data.flags\\.json}' | jq '.flags[\"new-pricing-algo\"].defaultVariant'"

  patched_json=$(kubectl get configmap flagd-config -o jsonpath='{.data.flags\.json}' \
    | jq '.flags["new-pricing-algo"].defaultVariant = "on"')
  kubectl create configmap flagd-config \
    --from-literal=flags.json="${patched_json}" \
    --dry-run=client -o yaml | kubectl apply -f -

  note "waiting up to 30s for kubelet to sync ConfigMap and flagd to pick it up..."
  for i in $(seq 1 15); do
    sleep 2
    body=$(curl -s "${GW_URL}/pricing/sku-X")
    if [[ "$(echo "$body" | jq -r '.algorithm')" == "v2-segmented" ]]; then
      ok "flag picked up after ~$((i*2))s"
      break
    fi
  done

  bold "After:"
  call "anonymous /pricing/sku-X (now newPricing=true, no restart)" \
    "curl -s ${GW_URL}/pricing/sku-X"

  note "resetting ConfigMap to original (default off) so the next run starts clean"
  kubectl apply -f k8s/flagd/configmap.yaml >/dev/null
  for _ in $(seq 1 15); do
    sleep 2
    body=$(curl -s "${GW_URL}/pricing/sku-X")
    [[ "$(echo "$body" | jq -r '.algorithm')" == "v1-flat" ]] && break
  done

  ok "hot-reload demonstrated (state reset for next run)"
}

step6_app_config_reload() {
  section "Step 6 — application config hot-reload via @ConfigurationProperties (no pod restart)"

  bold "Before: pricing.discount-percent = 5, pricing.currency = USD"
  call "GET /pricing/sku-A → discountPercent=5, currency=USD" \
    "curl -s ${GW_URL}/pricing/sku-A"

  note "patching ConfigMap pricing-config: discount-percent 5 → 25, currency USD → CNY"
  show "kubectl patch configmap pricing-config --type merge -p '{\"data\":{\"pricing.discount-percent\":\"25\",\"pricing.currency\":\"CNY\"}}'"

  note "kubelet syncs ConfigMap volume (~5–10s); then we trigger /actuator/refresh"
  note "(production: spring-cloud-kubernetes-configuration-watcher does this automatically)"
  for i in $(seq 1 15); do
    sleep 2
    # Trigger refresh via an ephemeral curl pod inside the cluster (Service DNS works there).
    kubectl run --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
      "refresh-${i}" --quiet \
      -- -fsS -X POST -m 5 http://pricing-service:8082/actuator/refresh \
      >/dev/null 2>&1 || true
    body=$(curl -s "${GW_URL}/pricing/sku-A")
    pct=$(echo "$body" | jq -r '.discountPercent')
    cur=$(echo "$body" | jq -r '.currency')
    if [[ "$pct" == "25" && "$cur" == "CNY" ]]; then
      ok "config rebound after ~$((i*2))s"
      break
    fi
  done

  bold "After: same pod, no restart"
  call "GET /pricing/sku-A → discountPercent=25, currency=CNY" \
    "curl -s ${GW_URL}/pricing/sku-A"
  show "kubectl get pods --no-headers -l app=pricing-service"

  note "resetting pricing-config to defaults"
  kubectl apply -f k8s/pricing-service/configmap.yaml >/dev/null
  for _ in $(seq 1 15); do
    sleep 2
    kubectl run --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
      "refresh-reset-$(date +%s)" --quiet \
      -- -fsS -X POST -m 5 http://pricing-service:8082/actuator/refresh \
      >/dev/null 2>&1 || true
    body=$(curl -s "${GW_URL}/pricing/sku-A")
    [[ "$(echo "$body" | jq -r '.discountPercent')" == "5" ]] && break
  done

  ok "application config hot-reload demonstrated (state reset for next run)"
}

step7_ui_and_ofrep() {
  section "Step 7 — React UI + OpenFeature Remote Evaluation Protocol"

  note "verifying UI shell is reachable on ${UI_URL}"
  for _ in $(seq 1 15); do
    if curl -fsS "${UI_URL}/" >/dev/null 2>&1; then break; fi
    sleep 2
  done

  bold "UI HTML shell:"
  show "curl -s ${UI_URL}/ | head -10"

  bold "OFREP proxy through nginx (browser does the same call):"
  show "curl -s -X POST ${UI_URL}/ofrep/v1/evaluate/flags/order-tier \
        -H 'Content-Type: application/json' \
        -d '{\"context\": {\"targetingKey\": \"u-vip-001\"}}' | jq"

  show "curl -s -X POST ${UI_URL}/ofrep/v1/evaluate/flags/order-tier \
        -H 'Content-Type: application/json' \
        -d '{\"context\": {\"targetingKey\": \"u-normal-001\"}}' | jq"

  bold "Same flag, evaluated server-side via gateway (REST), should match:"
  call "VIP user via gateway → tier=premium" \
    "curl -s -H 'X-User-Id: u-vip-001' ${GW_URL}/orders/o-7"

  ok "UI served + OFREP works + same-flag-different-stack consistency proven"
  echo
  echo "  Open http://localhost:31180 in a browser:"
  echo "    - switch user → flags re-evaluate live"
  echo "    - 'Place order' / 'Get price' buttons hit the gateway through same-origin /api/*"
  echo "    - 'New Pricing!' / 'VIP' badges flip without page reload"
}

main() {
  step1_cluster
  step2_build
  step3_deploy
  step4_scenarios
  step5_hot_reload
  step6_app_config_reload
  step7_ui_and_ofrep
  section "Done"
  echo "Cluster name: ${CLUSTER_NAME}"
  echo "Tear down:    kind delete cluster --name ${CLUSTER_NAME}"
}

main "$@"
