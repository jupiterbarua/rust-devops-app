#!/usr/bin/env bash
#
# Install or update the monitoring stack (Prometheus, Grafana, Alertmanager).
# Safe to run again: it only changes what is different.
#
# Usage (on the admin host, from anywhere in the repo):
#   ./scripts/install-monitoring.sh                                  # k3s (default)
#   PLATFORM=eks ALLOW_CIDR=203.0.113.10/32 ./scripts/install-monitoring.sh
#
# On EKS, set KUBECONFIG to the EKS cluster first:
#   export KUBECONFIG=~/.kube/eks.yaml

set -euo pipefail

PLATFORM="${PLATFORM:-k3s}"
NAMESPACE="monitoring"
RELEASE="kube-prometheus-stack"
CHART="prometheus-community/kube-prometheus-stack"
VALUES_FILE="monitoring/kube-prometheus-stack-values.yaml"
EKS_VALUES_FILE="monitoring/kube-prometheus-stack-values-eks.yaml"

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

for cmd in kubectl helm curl openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed." >&2
    exit 1
  fi
done

echo "==> Platform: $PLATFORM (cluster: $(kubectl config current-context))"
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "Error: cannot reach a Kubernetes cluster. Check KUBECONFIG." >&2
  exit 1
fi

# --- Platform-specific Helm arguments --------------------------------------------
HELM_ARGS=(-f "$VALUES_FILE")

case "$PLATFORM" in
  k3s)
    # Traefik routes by host name; nip.io resolves <name>.<ip>.nip.io to <ip>
    IP=$(curl -fsS https://checkip.amazonaws.com)
    HELM_ARGS+=(
      --set "grafana.ingress.hosts[0]=grafana.${IP}.nip.io"
      --set "prometheus.ingress.hosts[0]=prometheus.${IP}.nip.io"
      --set "alertmanager.ingress.hosts[0]=alertmanager.${IP}.nip.io"
    )
    ;;
  eks)
    if [[ -z "${ALLOW_CIDR:-}" ]]; then
      echo "Error: on EKS, set ALLOW_CIDR to your IP, e.g. ALLOW_CIDR=203.0.113.10/32" >&2
      exit 1
    fi
    if [[ ! "$ALLOW_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
      echo "Error: ALLOW_CIDR '$ALLOW_CIDR' is not a valid IPv4 CIDR like 203.0.113.10/32" >&2
      exit 1
    fi
    HELM_ARGS+=(-f "$EKS_VALUES_FILE")
    for ui in grafana prometheus alertmanager; do
      HELM_ARGS+=(--set-string "${ui}.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/inbound-cidrs=${ALLOW_CIDR}")
    done
    ;;
  *)
    echo "Error: PLATFORM must be 'k3s' or 'eks', not '$PLATFORM'." >&2
    exit 1
    ;;
esac

# --- Helm chart repository ----------------------------------------------------------
echo "==> Helm repository"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update prometheus-community

# --- Namespace ----------------------------------------------------------------------
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

# --- Install or upgrade the stack ------------------------------------------------------
echo "==> Installing $RELEASE (this can take several minutes)"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  "${HELM_ARGS[@]}" \
  --wait \
  --timeout 10m

# --- Summary -----------------------------------------------------------------------------
echo
kubectl get pods --namespace "$NAMESPACE"
echo
if [[ "$PLATFORM" == "k3s" ]]; then
  echo "Grafana:      http://grafana.${IP}.nip.io   (user: admin)"
  echo "Prometheus:   http://prometheus.${IP}.nip.io"
  echo "Alertmanager: http://alertmanager.${IP}.nip.io"
else
  echo "Load balancers are being created (1-3 minutes). Their addresses:"
  echo "  kubectl get ingress -n $NAMESPACE"
  echo "Open http://<ADDRESS> for each. Grafana user: admin"
fi
echo
echo "Grafana password:"
echo "  kubectl get secret grafana-admin -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo
echo "Next: run ./scripts/deploy.sh so the app's ServiceMonitor, dashboard and alerts are created."