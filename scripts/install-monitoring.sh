#!/usr/bin/env bash
#
# Install or update the monitoring stack (Prometheus, Grafana, Alertmanager)
# on the k3s cluster. Safe to run again: it only changes what is different.
#
# Usage (on the k3s server, from anywhere in the repo):
#   ./scripts/install-monitoring.sh

set -euo pipefail

NAMESPACE="monitoring"
RELEASE="kube-prometheus-stack"
CHART="prometheus-community/kube-prometheus-stack"
VALUES_FILE="monitoring/kube-prometheus-stack-values.yaml"

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

for cmd in kubectl helm curl openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed." >&2
    exit 1
  fi
done

# --- Helm chart repository ---------------------------------------------------
echo "==> Helm repository"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update prometheus-community

# --- Namespace -----------------------------------------------------------------
echo "==> Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- Grafana admin password (created once, never overwritten) -------------------
echo "==> Grafana admin secret"
if kubectl get secret grafana-admin --namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "secret/grafana-admin already exists, keeping it"
else
  kubectl create secret generic grafana-admin --namespace "$NAMESPACE" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 18)"
fi

# --- Public IP for the nip.io host names --------------------------------------
IP=$(curl -fsS https://checkip.amazonaws.com)
echo "==> Public IP: $IP"

# --- Install or upgrade the stack ------------------------------------------------
echo "==> Installing $RELEASE (this can take several minutes)"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --set "grafana.ingress.hosts[0]=grafana.${IP}.nip.io" \
  --set "prometheus.ingress.hosts[0]=prometheus.${IP}.nip.io" \
  --wait \
  --timeout 10m

# --- Summary -----------------------------------------------------------------------
echo
kubectl get pods --namespace "$NAMESPACE"
echo
echo "Grafana:    http://grafana.${IP}.nip.io   (user: admin)"
echo "Prometheus: http://prometheus.${IP}.nip.io"
echo
echo "Grafana password:"
echo "  kubectl get secret grafana-admin -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo
echo "Next: run ./scripts/deploy.sh so the app's ServiceMonitor is created."