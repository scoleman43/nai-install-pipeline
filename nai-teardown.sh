#!/bin/bash
# ==============================================================================
# Script: nai-teardown.sh
# Purpose: Completely eradicates the Nutanix Enterprise AI installation.
# Features: Bypasses stale finalizers, removes charts, wipes namespaces & storage.
# ==============================================================================

export TARGET_NAMESPACE="nai-system"

if ! command -v gum &> /dev/null; then
    echo "❌ ERROR: 'gum' is not installed."
    exit 1
fi

clear
gum style --border double --margin "1" --padding "1 2" --border-foreground 196 "Nutanix Enterprise AI (NAI) Teardown"
echo ""

if ! gum confirm "⚠️ WARNING: This will DESTROY all NAI data, models, and configurations. Proceed?"; then
    echo "Teardown aborted."
    exit 0
fi

echo ""
# ==============================================================================
# STEP 1: PROACTIVE LOCK REMOVAL (FINALIZER BYPASS)
# ==============================================================================
gum style --foreground 212 "🔓 Stripping finalizers from custom resources to prevent hanging..."
kubectl get clickhouseinstallation,inferenceservice,gateway,httproute -n "${TARGET_NAMESPACE}" -o name 2>/dev/null | xargs -I {} kubectl patch {} -n "${TARGET_NAMESPACE}" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true

# ==============================================================================
# STEP 2: HELM CHART ERADICATION
# ==============================================================================
gum style --foreground 212 "🗑️ Force-uninstalling NAI Helm releases..."
helm uninstall nai-core -n "${TARGET_NAMESPACE}" --no-hooks 2>/dev/null || true
helm uninstall nai-operators -n "${TARGET_NAMESPACE}" --no-hooks 2>/dev/null || true

gum style --foreground 212 "🗑️ Force-uninstalling foundational dependencies..."
helm uninstall kserve -n "${TARGET_NAMESPACE}" --no-hooks 2>/dev/null || true
helm uninstall kserve-crd -n "${TARGET_NAMESPACE}" --no-hooks 2>/dev/null || true
helm uninstall opentelemetry-operator -n "${TARGET_NAMESPACE}" --no-hooks 2>/dev/null || true
helm uninstall gateway-helm -n "${TARGET_NAMESPACE}" --no-hooks 2>/dev/null || true
helm uninstall gateway-crds -n "${TARGET_NAMESPACE}" --no-hooks 2>/dev/null || true

# ==============================================================================
# STEP 3: NAMESPACE & STORAGE PURGE
# ==============================================================================
gum style --foreground 212 "🧨 Purging NAI Namespaces (This destroys all PVCs, Pods, and Secrets)..."
kubectl delete namespace "${TARGET_NAMESPACE}" nai-admin --force --grace-period=0 2>/dev/null || true

gum style --foreground 212 "🧹 Cleaning up custom StorageClasses..."
kubectl delete storageclass nai-nfs-storage 2>/dev/null || true

# ==============================================================================
# STEP 4: CACHE CLEANUP
# ==============================================================================
gum style --foreground 212 "♻️ Flushing installer cache..."
rm -f .nai_cache.env

# ==============================================================================
# STEP 5: VERIFICATION LOOP
# ==============================================================================
echo ""
gum spin --spinner dot --spinner.foreground 196 --title "Waiting for Kubernetes to flush remaining namespace artifacts..." -- sleep 10

# Check if namespaces are truly gone
REMAINING_NS=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | grep -E 'nai-system|nai-admin' || true)

if [ -z "$REMAINING_NS" ]; then
    gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "✔ Teardown Complete: Cluster is a blank canvas."
else
    gum style --foreground 214 "⚠️ Teardown finished, but some resources are still terminating in the background."
    echo "Run 'kubectl get namespaces' in a few moments to confirm they disappear."
fi