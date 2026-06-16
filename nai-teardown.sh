#!/bin/bash

# ==============================================================================
# Nutanix AI Enterprise (NAI) Teardown Script
# ==============================================================================

NAMESPACE="nai-system"
CLICKHOUSE_RESOURCE="clickhouseinstallation.clickhouse.altinity.com/nai-clickhouse-server"

echo "========================================"
echo " Starting Nutanix AI Teardown Sequence"
echo "========================================"

# ------------------------------------------------------------------------------
# STEP 1: Graceful Custom Resource Cleanup
# We delete the ClickHouse database first so the active operator can clean it up.
# ------------------------------------------------------------------------------
echo "[1/4] Requesting graceful deletion of ClickHouse server..."
kubectl delete ${CLICKHOUSE_RESOURCE} -n ${NAMESPACE} --ignore-not-found=true --wait=false

echo "[2/4] Waiting up to 120 seconds for ClickHouse to properly terminate..."
# If the wait succeeds, great. If it fails (times out), the '|| true' allows the script to continue.
kubectl wait --for=delete ${CLICKHOUSE_RESOURCE} -n ${NAMESPACE} --timeout=120s || true

# ------------------------------------------------------------------------------
# STEP 2: The "Nuclear" Fallback
# If ClickHouse is still hanging around after 2 minutes, we force-strip the finalizer.
# ------------------------------------------------------------------------------
if kubectl get ${CLICKHOUSE_RESOURCE} -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "  -> ClickHouse is stuck. Forcing finalizer removal to prevent namespace deadlock..."
    kubectl patch ${CLICKHOUSE_RESOURCE} -n ${NAMESPACE} -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    echo "  -> Finalizers stripped."
else
    echo "  -> ClickHouse cleaned up gracefully."
fi

# ------------------------------------------------------------------------------
# STEP 3: Core Platform Teardown
# Add your specific Helm uninstall commands or other operator teardowns here.
# ------------------------------------------------------------------------------
echo "[3/4] Removing core Nutanix AI components..."

# Example: If you deployed via Helm, uncomment and adjust the line below:
# helm uninstall nai-enterprise -n ${NAMESPACE} --ignore-not-found

# ------------------------------------------------------------------------------
# STEP 4: Namespace Deletion
# ------------------------------------------------------------------------------
echo "[4/4] Deleting the ${NAMESPACE} namespace..."
kubectl delete namespace ${NAMESPACE} --ignore-not-found=true --wait=false

echo "Waiting for namespace to fully terminate..."
while kubectl get ns ${NAMESPACE} >/dev/null 2>&1; do
    echo -n "."
    sleep 3
done

echo ""
echo "========================================"
echo " Teardown Complete! Namespace is gone."
echo "========================================"