#!/bin/bash
# ==============================================================================
# Script: nkp-nai-lifecycle.sh
# Purpose: Gracefully suspends/drains or resumes/wakes NAI and NKP clusters
# Feature: Auto-discovers cluster namespaces via Management Kubeconfig
# ==============================================================================

set -euo pipefail

clear
export TERM="xterm-256color"

if ! command -v gum &> /dev/null; then
    echo "❌ ERROR: 'gum' is not installed. Please install gum to use this script."
    exit 1
fi

gum style --border double --margin "1" --padding "1 2" --border-foreground 214 "NKP & NAI - Lifecycle Management Protocol"
echo "Select the operation you want to perform on your cluster:"
echo ""

OPERATION=$(gum choose "Shut Down (Suspend & Drain)" "Wake Up (Resume & Uncordon)")

if ! gum confirm "⚠️ You selected: '${OPERATION}'. Proceed?"; then
    echo "Aborted."
    exit 0
fi

# ==============================================================================
# STEP 1: AUTO-DISCOVERY & KUBECONFIGS
# ==============================================================================
echo ""
gum style --foreground 212 "🔍 STEP 1: Locating the target cluster..."

# Ask for the Management Kubeconfig first so we can query it
DEFAULT_MGMT="$HOME/nkp-sc-10.conf"
if [ ! -f "$DEFAULT_MGMT" ]; then DEFAULT_MGMT="$HOME/.kube/config"; fi
MGMT_KUBECONFIG=$(gum input --prompt "Path to NKP Management Kubeconfig: " --value "$DEFAULT_MGMT")

gum style --foreground 240 "   -> Scanning Management Cluster for workload environments..."

# Query the management cluster for all Cluster API objects across all namespaces
if ! CLUSTER_LIST=$(kubectl get clusters -A --kubeconfig "${MGMT_KUBECONFIG}" --no-headers 2>/dev/null | awk '{print $1 " | " $2}'); then
    gum style --foreground 196 "❌ ERROR: Could not connect to the Management Cluster. Please check the kubeconfig path."
    exit 1
fi

if [ -z "$CLUSTER_LIST" ]; then
    gum style --foreground 196 "❌ ERROR: Connected, but no clusters found. Are you sure this is the Management cluster?"
    exit 1
fi

echo ""
echo "Select the NAI cluster you want to manage (Format: Namespace | ClusterName):"
# Present the discovered clusters in an interactive menu
SELECTED_CLUSTER=$(echo "$CLUSTER_LIST" | gum choose)

# Parse the selection back into variables
WORKSPACE_NAMESPACE=$(echo "$SELECTED_CLUSTER" | awk -F ' \\| ' '{print $1}')
NAI_CLUSTER_NAME=$(echo "$SELECTED_CLUSTER" | awk -F ' \\| ' '{print $2}')

gum style --foreground 82 "✔ Target locked: Cluster '${NAI_CLUSTER_NAME}' in workspace '${WORKSPACE_NAMESPACE}'."
echo ""

# Gather the remaining local variables
NAI_KUBECONFIG=$(gum input --prompt "Path to NAI Workload Kubeconfig: " --value "${PWD}/${NAI_CLUSTER_NAME}.conf")
TARGET_NAMESPACE=$(gum input --prompt "Enter the NAI Application Namespace: " --value "nai-system")
ENVOY_NAMESPACE="envoy-gateway-system"

# ==============================================================================
# OPERATION: SHUT DOWN
# ==============================================================================
if [ "$OPERATION" == "Shut Down (Suspend & Drain)" ]; then

    export KUBECONFIG="${NAI_KUBECONFIG}"

    gum style --foreground 212 "🛑 STEP 2: Scaling down Application Workloads..."
    
    gum style --foreground 240 "   -> Flushing connections and scaling down AI Models (if any exist)..."
    kubectl scale deployment -n "$TARGET_NAMESPACE" -l serving.kserve.io/inferenceservice --replicas=0 >/dev/null 2>&1 || true

    gum style --foreground 240 "   -> Scaling down Envoy Gateway traffic controllers..."
    kubectl scale deployment -n "$ENVOY_NAMESPACE" --all --replicas=0 >/dev/null 2>&1 || true

    gum style --foreground 240 "   -> Scaling down NAI Core operators and statefulsets..."
    kubectl scale deployment -n "$TARGET_NAMESPACE" --all --replicas=0 >/dev/null 2>&1 || true
    kubectl scale statefulset -n "$TARGET_NAMESPACE" --all --replicas=0 >/dev/null 2>&1 || true

    sleep 5

    gum style --foreground 212 "⏸️ STEP 3: Pausing NKP Cluster API Reconciliation..."
    export KUBECONFIG="${MGMT_KUBECONFIG}"
    if kubectl get cluster "$NAI_CLUSTER_NAME" -n "$WORKSPACE_NAMESPACE" >/dev/null 2>&1; then
        kubectl patch cluster "$NAI_CLUSTER_NAME" -n "$WORKSPACE_NAMESPACE" --type merge -p '{"spec":{"paused":true}}'
        gum style --foreground 82 "   ✔ NAI Cluster API successfully paused."
    else
        gum style --foreground 196 "   ❌ Could not find cluster $NAI_CLUSTER_NAME in namespace $WORKSPACE_NAMESPACE."
    fi

    gum style --foreground 212 "🧹 STEP 4: Cordoning and Draining Nodes..."
    export KUBECONFIG="${NAI_KUBECONFIG}"
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        gum style --foreground 240 "   -> Cordoning ${node}..."
        kubectl cordon "${node}" >/dev/null 2>&1 || true
    done

    WORKER_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker="" -o jsonpath='{.items[*].metadata.name}' || true)
    for node in $WORKER_NODES; do
        gum style --foreground 240 "   -> Draining Worker Node: ${node}..."
        kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout=90s >/dev/null 2>&1 || true
    done

    echo ""
    gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "✔ Shutdown Preparation Complete!"
    cat <<EOF
ACTION REQUIRED:
1. Log into Nutanix Prism Central.
2. Select your NAI Workload VMs and execute a "Guest Shutdown (ACPI)".
3. Select your NKP Management VMs and execute a "Guest Shutdown (ACPI)".
EOF

# ==============================================================================
# OPERATION: WAKE UP
# ==============================================================================
elif [ "$OPERATION" == "Wake Up (Resume & Uncordon)" ]; then
    
    gum style --foreground 214 "⚠️ PRE-FLIGHT CHECK: Ensure all VMs have been powered ON in Prism Central before continuing!"
    if ! gum confirm "Are the VMs powered on and booted?"; then
        echo "Please power on the VMs and try again."
        exit 0
    fi

    gum style --foreground 212 "▶️ STEP 2: Resuming NKP Cluster API Reconciliation..."
    export KUBECONFIG="${MGMT_KUBECONFIG}"
    if kubectl get cluster "$NAI_CLUSTER_NAME" -n "$WORKSPACE_NAMESPACE" >/dev/null 2>&1; then
        kubectl patch cluster "$NAI_CLUSTER_NAME" -n "$WORKSPACE_NAMESPACE" --type merge -p '{"spec":{"paused":false}}'
        gum style --foreground 82 "   ✔ NAI Cluster API successfully unpaused."
    else
        gum style --foreground 196 "   ❌ Could not find cluster $NAI_CLUSTER_NAME in namespace $WORKSPACE_NAMESPACE."
    fi

    sleep 5

    gum style --foreground 212 "🔓 STEP 3: Uncordoning Nodes..."
    export KUBECONFIG="${NAI_KUBECONFIG}"
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        gum style --foreground 240 "   -> Uncordoning ${node}..."
        kubectl uncordon "${node}" >/dev/null 2>&1 || true
    done

    gum style --foreground 212 "🚀 STEP 4: Scaling up NAI Application Workloads..."
    gum style --foreground 240 "   -> Waking up NAI Core operators and statefulsets..."
    kubectl scale deployment -n "$TARGET_NAMESPACE" --all --replicas=1 >/dev/null 2>&1 || true
    kubectl scale statefulset -n "$TARGET_NAMESPACE" --all --replicas=1 >/dev/null 2>&1 || true
    
    gum style --foreground 240 "   -> Waking up Envoy Gateway traffic controllers..."
    kubectl scale deployment -n "$ENVOY_NAMESPACE" --all --replicas=1 >/dev/null 2>&1 || true

    gum style --foreground 240 "   -> Waking up AI Models (if any exist)..."
    kubectl scale deployment -n "$TARGET_NAMESPACE" -l serving.kserve.io/inferenceservice --replicas=1 >/dev/null 2>&1 || true

    echo ""
    gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "✔ Wake Up Complete!"
    cat <<EOF
The Kubernetes environment is now fully unpaused, uncordoned, and workloads have been scaled back to 1 replica.
Please allow 3 to 5 minutes for the AI models and operators to pull their images and initialize.

You can monitor the startup progress by running:
kubectl get pods -n ${TARGET_NAMESPACE} -w
EOF

fi