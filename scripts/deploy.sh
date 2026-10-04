#!/usr/bin/env bash
#
# Deploy rust-app to the k3s cluster with Helm.
# Safe to run again and again (idempotent).
#
# Database: uses the RDS instance if it exists, otherwise falls back to
# the in-cluster PostgreSQL from k8s/postgres.yaml.
#
# Usage (on the k3s server, from anywhere in the repo):
#   ./scripts/deploy.sh              # deploy the newest tagged image in ECR
#   ./scripts/deploy.sh <image-tag>  # deploy a specific image (e.g. for a rollback)

set -euo pipefail

REGION="eu-central-1"
REPO="rust-devops-app"
NAMESPACE="rust-app"
RELEASE="rust-app"
CHART_DIR="charts/rust-app"
DB_INSTANCE_ID="rust-devops-db"
DB_SECRET_NAME="${RELEASE}-db"

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

for cmd in aws kubectl helm python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed." >&2
    exit 1
  fi
done

# --- Which image to deploy ------------------------------------------------
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

# --- Namespace -----------------------------------------------------------
echo "==> Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- ECR pull secret (refreshed every run: tokens expire after 12 hours) -
echo "==> ECR pull secret"
kubectl create secret docker-registry ecr-credentials \
  --namespace "$NAMESPACE" \
  --docker-server="$REGISTRY" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region "$REGION")" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- Database: RDS if it exists, otherwise in-cluster PostgreSQL --------
RDS_ERR=$(mktemp)
trap 'rm -f "$RDS_ERR"' EXIT

if RDS_INFO=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --region "$REGION" \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address,Endpoint.Port,DBName,MasterUserSecret.SecretArn]' \
  --output text 2>"$RDS_ERR"); then

  read -r DB_STATUS DB_HOST DB_PORT DB_NAME SECRET_ARN <<<"$RDS_INFO"
  if [[ "$DB_STATUS" != "available" ]]; then
    echo "Error: RDS instance is '$DB_STATUS'. Wait until it is 'available'." >&2
    exit 1
  fi
  echo "==> Database: RDS ($DB_HOST)"

  # Read username/password from Secrets Manager (never printed)
  SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ARN" --region "$REGION" \
    --query SecretString --output text)

  # Build the URL in Python so special characters in the password are URL-encoded.
  # sslmode=require: RDS for PostgreSQL 15+ only accepts encrypted connections.
  DATABASE_URL=$(SECRET_JSON="$SECRET_JSON" DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_NAME="$DB_NAME" python3 -c '
import json, os
from urllib.parse import quote
s = json.loads(os.environ["SECRET_JSON"])
print("postgres://{}:{}@{}:{}/{}?sslmode=require".format(
    quote(s["username"], safe=""), quote(s["password"], safe=""),
    os.environ["DB_HOST"], os.environ["DB_PORT"], os.environ["DB_NAME"]))
')
  unset SECRET_JSON

  # The in-cluster database is not needed when RDS is used
  kubectl delete -f k8s/postgres.yaml --ignore-not-found

elif grep -q "DBInstanceNotFound" "$RDS_ERR"; then
  echo "==> Database: in-cluster PostgreSQL (no RDS instance found)"
  kubectl apply -f k8s/postgres.yaml
  kubectl rollout status deployment/postgres --namespace "$NAMESPACE" --timeout=180s
  DATABASE_URL="postgres://app:app@postgres:5432/app"

else
  echo "Error: could not check for the RDS instance:" >&2
  cat "$RDS_ERR" >&2
  exit 1
fi

# Store the connection string in a Kubernetes Secret (created outside Helm)
echo "==> Database secret"
kubectl create secret generic "$DB_SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

# Fingerprint of the config: when it changes, Helm restarts the pods
CONFIG_CHECKSUM=$(printf '%s' "$DATABASE_URL" | sha256sum | cut -d' ' -f1)
unset DATABASE_URL

# --- Lint and deploy -----------------------------------------------------
HELM_ARGS=(
  --set image.repository="${REGISTRY}/${REPO}"
  --set image.tag="$IMAGE_TAG"
  --set existingSecret="$DB_SECRET_NAME"
  --set configChecksum="$CONFIG_CHECKSUM"
)

echo "==> Helm lint"
helm lint "$CHART_DIR" "${HELM_ARGS[@]}"

echo "==> Helm upgrade"
if ! helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  "${HELM_ARGS[@]}" \
  --wait \
  --timeout 5m; then
  echo >&2
  echo "Deployment failed. Pod status, recent events and logs:" >&2
  kubectl get pods --namespace "$NAMESPACE" >&2
  kubectl describe pods --namespace "$NAMESPACE" -l "app=${RELEASE}" | tail -25 >&2
  kubectl logs --namespace "$NAMESPACE" -l "app=${RELEASE}" --tail=10 >&2 || true
  exit 1
fi

# --- Summary -------------------------------------------------------------
echo
echo "==> Done. Recent releases:"
helm history "$RELEASE" --namespace "$NAMESPACE" --max 5
echo
kubectl get pods,svc,ingress --namespace "$NAMESPACE"