#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="sb3-demo"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[setup] recreating kind cluster '${CLUSTER_NAME}' to apply tracked port mappings"
  kind delete cluster --name "${CLUSTER_NAME}"
fi

echo "[setup] creating kind cluster '${CLUSTER_NAME}'"
kind create cluster --config k8s/kind-cluster.yaml

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo "[setup] done"
