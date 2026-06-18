#!/bin/bash
# ==============================================================================
# Script: nai-teardown.sh
# Purpose: Brutally and completely uninstalls NAI and clears stuck namespaces
# Architecture: Updated to handle split-brain Envoy namespaces
# ==============================================================================

set -uo pipefail

clear
export TERM="xterm-256color"

# ==============================================================================
# PREREQUISITES
# ==============================================================================
if ! command -v gum &> /dev/null; then
    echo "❌ ERROR: 'gum' is not installed."
    exit 1
fi

gum style --border double --margin "1" --padding "1 2" --border-foreground 196 "Nutanix Enterprise AI (NAI) - Total Teardown"

if ! gum confirm "⚠️ WARNING: This will completely destroy NAI, all models, and force-delete the namespaces. Continue?"; then
    echo "Aborted."
    exit 0
fi

TARGET_NAMESPACE="${TARGET_NAMESPACE:-nai-system}"
ADMIN_NAMESPACE="nai-admin"
ENVOY_NAMESPACE="envoy-gateway-system"

# ==============================================================================
# STEP 1: GRACEFUL HELM REMOVAL (Best Effort)
# ==============================================================================
gum style --foreground 212 "🧹 Attempting graceful Helm uninstallation..."

# 1. Uninstall Envoy Gateway from its dedicated namespace
if helm status "gateway-helm" -n "$ENVOY_NAMESPACE" >/dev/null 2>&1; then
    gum style --foreground 240 "   -> Uninstalling gateway-helm from $ENVOY_NAMESPACE..."
    helm uninstall "gateway-helm" -n "$ENVOY_NAMESPACE" --wait >/dev/null 2>&1 || true
fi

# 2. Uninstall remaining NAI Core components from the target namespace
HELM_RELEASES=("nai-core" "nai-operators" "kserve" "opentelemetry-operator" "gateway-crds" "kserve-crd")

for release in "${HELM_RELEASES[@]}"; do
    if helm status "$release" -n "$TARGET_NAMESPACE" >/dev/null 2>&1; then
        gum style --foreground 240 "   -> Uninstalling $release from $TARGET_NAMESPACE..."
        helm uninstall "$release" -n "$TARGET_NAMESPACE" --wait >/dev/null 2>&1 || true
    fi
done

# ==============================================================================
# STEP 2: STUCK NAMESPACE NUKE (The Brute Force Fix)
# ==============================================================================
nuke_namespace() {
    local NS=$1
    if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
        return 0
    fi

    gum style --foreground 214 "🧨 Initiating aggressive teardown for namespace: ${NS}..."
    
    # Issue delete command but do not wait
    kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true

    # Strip finalizers from standard K8s resources
    gum style --foreground 240 "   -> Stripping finalizers from standard resources..."
    kubectl get all,pvc,configmap,secret,rolebinding,serviceaccount -n "$NS" -o name 2>/dev/null | while read -r resource; do
        kubectl patch "$resource" -n "$NS" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    done

    # Strip finalizers from all Custom Resources (Envoy, KServe, etc.)
    gum style --foreground 240 "   -> Stripping finalizers from custom API resources..."
    kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | while read -r api; do
        kubectl get "$api" -n "$NS" -o name 2>/dev/null | while read -r cr; do
            kubectl patch "$cr" -n "$NS" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        done
    done

    # Force the Kubernetes API to finalize the namespace itself
    gum style --foreground 196 "   💥 Force-closing the ${NS} namespace..."
    kubectl get namespace "$NS" -o json 2>/dev/null | tr -d "\n" | sed 's/"finalizers": \[[^]]\+\]/"finalizers": []/' | kubectl replace --raw /api/v1/namespaces/"$NS"/finalize -f - >/dev/null 2>&1 || true
}

# Execute the nuke on all relevant namespaces
nuke_namespace "$TARGET_NAMESPACE"
nuke_namespace "$ADMIN_NAMESPACE"
nuke_namespace "$ENVOY_NAMESPACE"

# ==============================================================================
# STEP 3: CLUSTER-SCOPED LEFTOVERS
# ==============================================================================
gum style --foreground 212 "🧹 Sweeping up cluster-scoped leftovers..."

gum style --foreground 240 "   -> Deleting GatewayClasses..."
kubectl delete gatewayclass traefik envoy-gateway-gatewayclass --ignore-not-found >/dev/null 2>&1 || true

gum style --foreground 240 "   -> Deleting StorageClasses..."
kubectl delete storageclass nai-nfs-storage --ignore-not-found >/dev/null 2>&1 || true

# Explicitly clean up Gateway Helm cluster permissions to prevent collision on reinstall
gum style --foreground 240 "   -> Exorcising ghost Envoy ClusterRoles..."
kubectl delete clusterrole gateway-helm-envoy-gateway-role --ignore-not-found >/dev/null 2>&1 || true
kubectl delete clusterrolebinding gateway-helm-envoy-gateway-rolebinding --ignore-not-found >/dev/null 2>&1 || true

# Strip finalizers from stuck CRDs globally (Envoy & KServe)
gum style --foreground 240 "   -> Purging finalizers from stuck Envoy/KServe CRDs..."
STUCK_CRDS=$(kubectl get crd -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E 'envoyproxy.io|kserve.io' || true)
for crd in $STUCK_CRDS; do
    kubectl patch crd "$crd" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
done

# ==============================================================================
# STEP 4: CACHE PURGE
# ==============================================================================
echo ""
if [ -f ".nai_cache.env" ]; then
    if gum confirm "🗑️ Do you want to delete the local password cache (.nai_cache.env)? (Recommended to clear bad formatting)"; then
        rm -f .nai_cache.env
        gum style --foreground 82 "✔ Cache deleted."
    fi
fi

echo ""
gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "✔ Teardown Complete! The cluster is clean and ready for reinstall."