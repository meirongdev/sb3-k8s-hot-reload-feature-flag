#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="sb3-demo"
TAG="0.0.1-SNAPSHOT"

echo "[build] mvn package"
mvn -q -DskipTests package

echo "[build] docker build + kind load (Spring services)"
for svc in gateway order-service pricing-service; do
  docker build --quiet -t "local/${svc}:${TAG}" -f Dockerfile "${svc}/"
  kind load docker-image "local/${svc}:${TAG}" --name "${CLUSTER_NAME}"
done

echo "[build] docker build + kind load (UI — multi-stage Node→nginx)"
docker build --quiet -t "local/ui:${TAG}" -f ui/Dockerfile ui/
kind load docker-image "local/ui:${TAG}" --name "${CLUSTER_NAME}"

echo "[build] done"
