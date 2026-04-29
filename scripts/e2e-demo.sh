#!/usr/bin/env bash

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

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "ASSERT FAIL: ${message} (expected=${expected}, actual=${actual})"
    exit 1
  fi
}

assert_non_empty() {
  local actual="$1" message="$2"
  if [[ -z "$actual" ]]; then
    echo "ASSERT FAIL: ${message}"
    exit 1
  fi
}

print_json() {
  local title="$1" body="$2"
  bold "${title}"
  echo "$body" | jq '.'
}

step1_cluster() {
  section "Step 1 — kind cluster"
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    note "recreating cluster '${CLUSTER_NAME}' for a clean POC run"
    show "kind delete cluster --name ${CLUSTER_NAME}"
  fi
  show "kind create cluster --config k8s/kind-cluster.yaml"
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
  section "Step 3 — deploy all components"
  show "kubectl apply -f k8s/flagd/"
  kubectl wait --for=condition=available --timeout=90s deployment/flagd >/dev/null
  show "kubectl apply -f k8s/order-service/ -f k8s/pricing-service/ -f k8s/gateway/ -f k8s/ui/"
  kubectl wait --for=condition=available --timeout=180s \
    deployment/order-service deployment/pricing-service deployment/gateway deployment/ui >/dev/null
  show "kubectl get pods -o wide"
  ok "all deployments ready"
}

wait_gateway() {
  note "waiting for gateway readiness on ${GW_URL}/actuator/health"
  for _ in $(seq 1 30); do
    if curl -fsS "${GW_URL}/actuator/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "gateway did not become ready"
  exit 1
}

wait_ui() {
  note "waiting for UI readiness on ${UI_URL}/"
  for _ in $(seq 1 30); do
    if curl -fsS "${UI_URL}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "UI did not become ready"
  exit 1
}

curl_json() {
  curl -fsS "$@"
}

curl_ofrep() {
  local flag="$1" context_json="$2"
  curl -fsS -X POST "${UI_URL}/ofrep/v1/evaluate/flags/${flag}" \
    -H 'Content-Type: application/json' \
    -d "${context_json}"
}

step4_backend_only() {
  section "Step 4 — backend-only flag flow"
  wait_gateway

  local backend_only
  backend_only=$(curl_json -H 'X-Tenant-Id: premium' "${GW_URL}/orders/o-201")
  print_json "premium tenant order response" "$backend_only"

  assert_eq "$(echo "$backend_only" | jq -r '.fulfillmentMode')" "express" \
    "premium tenant should get express fulfillment mode"
  assert_eq "$(echo "$backend_only" | jq -r '.handler')" "express-order-pipeline" \
    "backend-only flag should switch the order handler"
  assert_eq "$(echo "$backend_only" | jq -r '.tier')" "standard" \
    "backend-only scenario should remain separate from VIP tier targeting"
  ok "backend-only flow verified"
}

step5_frontend_only() {
  section "Step 5 — frontend-only flag flow"
  wait_ui

  local vip_banner regular_banner vip_perks regular_perks shell
  shell=$(curl -fsS "${UI_URL}/")
  assert_non_empty "$shell" "UI shell should be reachable"

  vip_banner=$(curl_ofrep "ui-homepage-banner" '{"context":{"targetingKey":"u-vip-001"}}')
  regular_banner=$(curl_ofrep "ui-homepage-banner" '{"context":{"targetingKey":"u-normal-001"}}')
  vip_perks=$(curl_ofrep "ui-member-perks" '{"context":{"targetingKey":"u-vip-001"}}')
  regular_perks=$(curl_ofrep "ui-member-perks" '{"context":{"targetingKey":"u-normal-001"}}')

  print_json "frontend-only vip banner" "$vip_banner"
  print_json "frontend-only regular banner" "$regular_banner"

  assert_eq "$(echo "$vip_banner" | jq -r '.value')" "spring-sale" \
    "vip user should see the spring-sale banner"
  assert_eq "$(echo "$regular_banner" | jq -r '.value')" "control" \
    "regular user should stay on the control banner"
  assert_eq "$(echo "$vip_perks" | jq -r '.value')" "true" \
    "vip user should see the member perks card"
  assert_eq "$(echo "$regular_perks" | jq -r '.value')" "false" \
    "regular user should not see the member perks card"
  ok "frontend-only flow verified"
}

step6_full_stack() {
  section "Step 6 — full-stack shared flag flow"

  local shared pricing order
  shared=$(curl_json -H 'X-User-Id: u-vip-001' -H 'X-Tenant-Id: premium' \
    "${GW_URL}/experience/shared-flags")
  pricing=$(curl_json -H 'X-User-Id: u-vip-001' -H 'X-Tenant-Id: premium' \
    "${GW_URL}/pricing/sku-B")
  order=$(curl_json -H 'X-User-Id: u-vip-001' "${GW_URL}/orders/o-301")

  print_json "gateway shared snapshot" "$shared"
  print_json "pricing response for vip + premium tenant" "$pricing"

  assert_eq "$(echo "$shared" | jq -r '.orderTier')" "premium" \
    "shared snapshot should expose premium order tier"
  assert_eq "$(echo "$shared" | jq -r '.newPricing')" "true" \
    "shared snapshot should expose new pricing flag"
  assert_eq "$(echo "$pricing" | jq -r '.tier')" "premium" \
    "pricing response should match shared order tier"
  assert_eq "$(echo "$pricing" | jq -r '.algorithm')" "v2-segmented" \
    "pricing response should match shared pricing algorithm"
  assert_eq "$(echo "$order" | jq -r '.tier')" "premium" \
    "order response should preserve premium shared semantics"
  ok "full-stack flow verified"
}

step7_hot_reload() {
  section "Step 7 — flag hot reload"

  local before after patched_json pods_before pods_after
  before=$(curl_json "${GW_URL}/pricing/sku-X")
  print_json "before flag hot reload" "$before"
  assert_eq "$(echo "$before" | jq -r '.algorithm')" "v1-flat" \
    "default pricing algorithm should start at v1-flat"

  pods_before=$(kubectl get pods --no-headers | awk '{print $1 ":" $4}' | tr '\n' ' ')

  patched_json=$(kubectl get configmap flagd-config -o jsonpath='{.data.flags\.json}' \
    | jq '.flags["new-pricing-algo"].defaultVariant = "on"')
  kubectl create configmap flagd-config \
    --from-literal=flags.json="${patched_json}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  note "waiting for kubelet sync + flagd fsnotify"
  for _ in $(seq 1 15); do
    sleep 2
    after=$(curl_json "${GW_URL}/pricing/sku-X")
    if [[ "$(echo "$after" | jq -r '.algorithm')" == "v2-segmented" ]]; then
      break
    fi
  done

  print_json "after flag hot reload" "$after"
  assert_eq "$(echo "$after" | jq -r '.algorithm')" "v2-segmented" \
    "flag hot reload should flip the pricing algorithm"

  pods_after=$(kubectl get pods --no-headers | awk '{print $1 ":" $4}' | tr '\n' ' ')
  assert_eq "$pods_after" "$pods_before" "flag hot reload must not restart pods"

  kubectl apply -f k8s/flagd/configmap.yaml >/dev/null
  for _ in $(seq 1 15); do
    sleep 2
    after=$(curl_json "${GW_URL}/pricing/sku-X")
    [[ "$(echo "$after" | jq -r '.algorithm')" == "v1-flat" ]] && break
  done
  ok "flag hot reload verified and reset"
}

step8_config_refresh() {
  section "Step 8 — pricing config refresh"

  local before after pod_before pod_after
  before=$(curl_json "${GW_URL}/pricing/sku-A")
  pod_before=$(kubectl get pods --no-headers -l app=pricing-service | awk 'NR==1{print $1}')
  print_json "before pricing config refresh" "$before"

  assert_eq "$(echo "$before" | jq -r '.discountPercent')" "5" \
    "pricing discount should start at 5"
  assert_eq "$(echo "$before" | jq -r '.currency')" "USD" \
    "pricing currency should start at USD"

  kubectl patch configmap pricing-config --type merge \
    -p '{"data":{"pricing.discount-percent":"25","pricing.currency":"CNY"}}' >/dev/null

  for i in $(seq 1 15); do
    sleep 2
    kubectl run --rm -i --restart=Never --image=curlimages/curl:8.10.1 "refresh-${i}" --quiet \
      -- -fsS -X POST -m 5 http://pricing-service:8082/actuator/refresh >/dev/null 2>&1 || true
    after=$(curl_json "${GW_URL}/pricing/sku-A")
    if [[ "$(echo "$after" | jq -r '.discountPercent')" == "25" ]]; then
      break
    fi
  done

  pod_after=$(kubectl get pods --no-headers -l app=pricing-service | awk 'NR==1{print $1}')
  print_json "after pricing config refresh" "$after"

  assert_eq "$(echo "$after" | jq -r '.discountPercent')" "25" \
    "pricing discount should rebind to 25"
  assert_eq "$(echo "$after" | jq -r '.currency')" "CNY" \
    "pricing currency should rebind to CNY"
  assert_eq "$pod_after" "$pod_before" "pricing refresh should keep the same pod"

  kubectl apply -f k8s/pricing-service/configmap.yaml >/dev/null
  for _ in $(seq 1 15); do
    sleep 2
    kubectl run --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
      "refresh-reset-$(date +%s)" --quiet \
      -- -fsS -X POST -m 5 http://pricing-service:8082/actuator/refresh >/dev/null 2>&1 || true
    after=$(curl_json "${GW_URL}/pricing/sku-A")
    [[ "$(echo "$after" | jq -r '.discountPercent')" == "5" ]] && break
  done
  ok "pricing config refresh verified and reset"
}

main() {
  step1_cluster
  step2_build
  step3_deploy
  step4_backend_only
  step5_frontend_only
  step6_full_stack
  step7_hot_reload
  step8_config_refresh
  section "Done"
  echo "Cluster name: ${CLUSTER_NAME}"
  echo "Tear down:    kind delete cluster --name ${CLUSTER_NAME}"
}

main "$@"
