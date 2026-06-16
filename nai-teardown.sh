#!/bin/bash
# ==============================================================================
# Script: nai-teardown.sh
# Purpose: Completely eradicates the Nutanix Enterprise AI installation.
# Architecture: "Scorched Earth" ordering to prevent Terminating namespace hangs.
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
# STEP 1: HELM CHART ERADICATION
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
# STEP 2: TRIGGER BACKGROUND NAMESPACE PURGE
# ==============================================================================
gum style --foreground 212 "🧨 Triggering Namespace deletion..."
# Notice --wait=false. This tells Kubernetes to start deleting, but gives control back to our script immediately.
kubectl delete namespace "${TARGET_NAMESPACE}" nai-admin --wait=false 2>/dev/null || true

# ==============================================================================
# STEP 3: SEARCH & DESTROY (FINALIZER BYPASS)
# ==============================================================================
gum style --foreground 212 "🔓 Hunting down orphaned resources and stripping finalizers..."

# Wait a few seconds to let Kubernetes naturally delete what it can
sleep 5

# Target specific known offenders that hang the NAI uninstall
kubectl get clickhouseinstallation,inferenceservice,gateway,httproute,pvc,secrets,configmaps -n "${TARGET_NAMESPACE}" -o name 2>/dev/null | xargs -I {} kubectl patch {} -n "${TARGET_NAMESPACE}" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true

# Target ALL remaining namespaced resources dynamically just to be safe
kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | xargs -n 1 -I {} kubectl get {} -n "${TARGET_NAMESPACE}" -o name 2>/dev/null | xargs -I {} kubectl patch {} -n "${TARGET_NAMESPACE}" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true

# Force-clear finalizers on the namespace itself if Kubernetes gets entirely stuck
kubectl get namespace "${TARGET_NAMESPACE}" -o json 2>/dev/null | tr -d "\n" | sed 's/"finalizers": \[[^]]\+\]/"finalizers": []/' | kubectl replace --raw /api/v1/namespaces/"${TARGET_NAMESPACE}"/finalize -f - >/dev/null 2>&1 || true

# ==============================================================================
# STEP 4: STORAGE & CACHE CLEANUP
# ==============================================================================
gum style --foreground 212 "🧹 Cleaning up custom StorageClasses..."
kubectl delete storageclass nai-nfs-storage 2>/dev/null || true

gum style --foreground 212 "♻️ Flushing installer cache..."
rm -f .nai_cache.env

# ==============================================================================
# STEP 5: VERIFICATION LOOP
# ==============================================================================
echo ""
gum spin --spinner dot --spinner.foreground 196 --title "Waiting for Kubernetes to flush remaining namespace artifacts..." -- sleep 10

REMAINING_NS=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | grep -E 'nai-system|nai-admin' || true)

if [ -z "$REMAINING_NS" ]; then
    gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "✔ Teardown Complete: Cluster is a blank canvas."
else
    gum style --foreground 214 "⚠️ Teardown finished, but some resources are still terminating."
    echo "Run 'kubectl get namespaces' to check status. They should vanish momentarily."
fi