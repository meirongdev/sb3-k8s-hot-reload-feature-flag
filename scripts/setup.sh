#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="sb3-demo"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[setup] kind cluster '${CLUSTER_NAME}' already exists"
else
  echo "[setup] creating kind cluster '${CLUSTER_NAME}'"
  kind create cluster --config k8s/kind-cluster.yaml
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo "[setup] done"
