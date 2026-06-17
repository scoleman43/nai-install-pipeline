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
# NUCLEAR NAMESPACE CLEANUP FUNCTION
# ==============================================================================
force_clear_namespace() {
    local TARGET_NS=$1
    
    if kubectl get ns "${TARGET_NS}" >/dev/null 2>&1; then
        gum style --foreground 214 "🧹 Monitoring deletion of namespace: ${TARGET_NS}..."
        
        # Trigger a normal delete in the background
        kubectl delete ns "${TARGET_NS}" --wait=false >/dev/null 2>&1
        
        # Wait up to 30 seconds for a graceful exit
        local TRIES=0
        while kubectl get ns "${TARGET_NS}" >/dev/null 2>&1; do
            sleep 2
            TRIES=$((TRIES + 1))
            if [ $TRIES -ge 15 ]; then
                gum style --foreground 196 "⚠️ Namespace ${TARGET_NS} is stuck. Forcing finalizer removal..."
                
                # Dump current namespace state
                kubectl get ns "${TARGET_NS}" -o json > "/tmp/stuck_${TARGET_NS}.json"
                
                # Strip finalizers safely using Python
                python3 -c "import json; data=json.load(open('/tmp/stuck_${TARGET_NS}.json')); data.setdefault('spec', {})['finalizers']=[]; open('/tmp/stuck_${TARGET_NS}.json', 'w').write(json.dumps(data))"
                
                # Push back directly to API (No proxy needed)
                kubectl replace --raw "/api/v1/namespaces/${TARGET_NS}/finalize" -f "/tmp/stuck_${TARGET_NS}.json" >/dev/null 2>&1
                
                # Cleanup temp file
                rm -f "/tmp/stuck_${TARGET_NS}.json"
                break
            fi
        done
        gum style --foreground 82 "✔ Namespace ${TARGET_NS} successfully obliterated."
    fi
}

# ==============================================================================
# STEP 1: HELM CHART ERADICATION
# ==============================================================================
gum style --foreground 212 "🗑️ Force-uninstalling NAI Helm releases..."
helm uninstall