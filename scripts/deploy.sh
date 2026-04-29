#!/usr/bin/env bash
set -euo pipefail

echo "[deploy] applying flagd"
kubectl apply -f k8s/flagd/

echo "[deploy] waiting flagd"
kubectl wait --for=condition=available --timeout=60s deployment/flagd

echo "[deploy] applying services"
kubectl apply -f k8s/order-service/
kubectl apply -f k8s/pricing-service/
kubectl apply -f k8s/gateway/
kubectl apply -f k8s/ui/

echo "[deploy] waiting all deployments"
kubectl wait --for=condition=available --timeout=120s \
  deployment/order-service deployment/pricing-service deployment/gateway deployment/ui

echo "[deploy] gateway available at http://localhost:31080"
echo "[deploy] ui available at http://localhost:31180"
echo
echo "Try:"
echo "  curl -s -H 'X-User-Id: u-normal-001' http://localhost:31080/orders/123 | jq"
echo "  curl -s -H 'X-User-Id: u-vip-001'    http://localhost:31080/orders/123 | jq"
echo "  curl -s -H 'X-Tenant-Id: premium'    http://localhost:31080/pricing/sku-1 | jq"
echo "  curl -s http://localhost:31080/experience/shared-flags | jq"
