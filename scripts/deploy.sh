#!/usr/bin/env bash
#
# Deploy rust-app to the k3s cluster with Helm.
# Safe to run again and again: on a brand-new instance it sets everything up,
# on an existing one it only updates what changed.
#
# Usage (from anywhere in the repo, on the k3s server):
#   ./scripts/deploy.sh              # deploy the newest tagged image in ECR
#   ./scripts/deploy.sh <image-tag>  # deploy a specific image (e.g. for a rollback)

set -euo pipefail

REGION="eu-central-1"
REPO="rust-devops-app"
NAMESPACE="rust-app"
RELEASE="rust-app"
CHART_DIR="charts/rust-app"

# Always run from the repository root, wherever the script is called from
cd "$(dirname "$0")/.."

# Helm needs to know where the k3s cluster config is
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# --- Check required tools -----------------------------------------------------
for cmd in aws kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed." >&2
    exit 1
  fi
done

# --- Work out which image to deploy ----------------------------------------
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

IMAGE_TAG="${1:-$(aws ecr describe-images \
  --repository-name "$REPO" \
  --region "$REGION" \
  --query 'sort_by(imageDetails[?imageTags], &imagePushedAt)[-1].imageTags[0]' \
  --output text)}"

if [[ -z "$IMAGE_TAG" || "$IMAGE_TAG" == "None" ]]; then
  echo "Error: no tagged image found in ECR repository '$REPO'." >&2
  exit 1
fi

echo "==> Deploying ${REPO}:${IMAGE_TAG} to namespace '${NAMESPACE}'"

# --- Namespace (create if missing) -----------------------------------------
echo "==> Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- ECR pull secret (refreshed on every run: tokens expire after 12 hours) -
echo "==> ECR pull secret"
kubectl create secret docker-registry ecr-credentials \
  --namespace "$NAMESPACE" \
  --docker-server="$REGISTRY" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region "$REGION")" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- PostgreSQL (learning database inside the cluster) ---------------------
echo "==> PostgreSQL"
kubectl apply -f k8s/postgres.yaml
kubectl rollout status deployment/postgres --namespace "$NAMESPACE" --timeout=180s

# --- Check the chart before deploying --------------------------------------
echo "==> Helm lint"
helm lint "$CHART_DIR" \
  --set image.repository="${REGISTRY}/${REPO}" \
  --set image.tag="$IMAGE_TAG"

# --- Deploy with Helm ------------------------------------------------------
echo "==> Helm upgrade"
if ! helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set image.repository="${REGISTRY}/${REPO}" \
  --set image.tag="$IMAGE_TAG" \
  --wait \
  --timeout 5m; then
  echo >&2
  echo "Deployment failed. Pod status and recent events:" >&2
  kubectl get pods --namespace "$NAMESPACE" >&2
  kubectl describe pods --namespace "$NAMESPACE" -l "app=${RELEASE}" | tail -25 >&2
  exit 1
fi

# --- Summary ---------------------------------------------------------------
echo
echo "==> Done. Recent releases:"
helm history "$RELEASE" --namespace "$NAMESPACE" --max 5
echo
kubectl get pods,svc,ingress --namespace "$NAMESPACE"