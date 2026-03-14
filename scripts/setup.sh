#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="platform-eng"
CROSSPLANE_NAMESPACE="crossplane-system"
ARGOCD_NAMESPACE="argocd"
GCP_CREDS_FILE="${GCP_CREDS_FILE:-$HOME/k-ops-sandbox-66681f699c2c.json}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-k-ops-sandbox}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

check_prerequisites() {
    log "Checking prerequisites..."
    local missing=()
    for cmd in kind kubectl helm; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Missing tools: ${missing[*]}. Install them first."
    fi
    if [[ ! -f "$GCP_CREDS_FILE" ]]; then
        err "GCP credentials file not found: $GCP_CREDS_FILE"
    fi
    log "All prerequisites met."
}

create_kind_cluster() {
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        warn "Kind cluster '${CLUSTER_NAME}' already exists, skipping creation."
        kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null || err "Cluster exists but is unreachable."
        return
    fi
    log "Creating Kind cluster '${CLUSTER_NAME}'..."
    kind create cluster --name "$CLUSTER_NAME" --wait 60s
    log "Kind cluster created."
}

install_crossplane() {
    if helm list -n "$CROSSPLANE_NAMESPACE" 2>/dev/null | grep -q crossplane; then
        warn "Crossplane already installed, skipping."
        return
    fi
    log "Installing Crossplane..."
    helm repo add crossplane-stable https://charts.crossplane.io/stable 2>/dev/null || true
    helm repo update
    kubectl create namespace "$CROSSPLANE_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    helm install crossplane crossplane-stable/crossplane \
        --namespace "$CROSSPLANE_NAMESPACE" \
        --wait --timeout 120s
    log "Waiting for Crossplane pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=crossplane \
        -n "$CROSSPLANE_NAMESPACE" --timeout=120s
    log "Crossplane installed."
}

install_gcp_provider() {
    if kubectl get provider.pkg.crossplane.io upbound-provider-gcp-compute &>/dev/null 2>&1; then
        warn "GCP Compute provider already installed, skipping."
    else
        log "Installing Upbound GCP Compute provider..."
        kubectl apply -f "$(dirname "$0")/../crossplane/provider/provider-gcp-compute.yaml"
        log "Waiting for provider to become healthy..."
        kubectl wait --for=condition=healthy provider.pkg.crossplane.io/upbound-provider-gcp-compute \
            --timeout=180s || warn "Provider not yet healthy — it may need a few more minutes."
    fi

    log "Creating GCP credentials secret..."
    kubectl create secret generic gcp-creds \
        --from-file=credentials="$GCP_CREDS_FILE" \
        -n "$CROSSPLANE_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -

    log "Applying ProviderConfig..."
    kubectl apply -f "$(dirname "$0")/../crossplane/provider/provider-config.yaml"
    log "GCP provider configured."
}

install_crossplane_compositions() {
    log "Applying XRD and Composition..."
    kubectl apply -f "$(dirname "$0")/../crossplane/compositions/xrd-vm.yaml"
    kubectl apply -f "$(dirname "$0")/../crossplane/compositions/composition-vm.yaml"
    log "Crossplane compositions applied."
}

install_argocd() {
    if helm list -n "$ARGOCD_NAMESPACE" 2>/dev/null | grep -q argo-cd; then
        warn "ArgoCD already installed, skipping."
        return
    fi
    log "Installing ArgoCD..."
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo update
    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    helm install argo-cd argo/argo-cd \
        --namespace "$ARGOCD_NAMESPACE" \
        --set 'server.service.type=NodePort' \
        --set 'configs.params."server\.insecure"=true' \
        --wait --timeout 180s
    log "ArgoCD installed."
    log "ArgoCD initial admin password:"
    kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d
    echo ""
}

apply_argocd_application() {
    log "Applying ArgoCD Application for Crossplane claims..."
    kubectl apply -f "$(dirname "$0")/../argocd/application-claims.yaml"
    log "ArgoCD Application deployed."
}

main() {
    echo "========================================="
    echo " Platform Engineering Setup"
    echo "========================================="
    check_prerequisites
    create_kind_cluster
    install_crossplane
    install_gcp_provider
    install_crossplane_compositions
    install_argocd
    apply_argocd_application
    echo ""
    log "Setup complete!"
    log "ArgoCD UI: kubectl port-forward svc/argo-cd-argocd-server -n argocd 8080:80"
    log "Then open http://localhost:8080 (admin / <password above>)"
}

main "$@"
