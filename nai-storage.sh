#!/bin/bash
# ==============================================================================
# Script: setup-nai-storage.sh
# Purpose: Handles end-to-end RWX storage configuration for NAI. Can dynamically 
#          provision a Nutanix File Server via v4 API if one does not exist, 
#          and wires up the K8s CSI Secret and StorageClass.
# ==============================================================================

set -euo pipefail

export TERM="xterm-256color"

# --- PRE-FLIGHT CHECKS ---
if ! command -v gum &> /dev/null; then
    echo "Error: 'gum' is not installed."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    gum style --foreground 196 "❌ ERROR: 'jq' is required to parse Nutanix APIs. Please install it."
    exit 1
fi

if [ -z "${KUBECONFIG:-}" ] && [ ! -f "$HOME/.kube/config" ]; then
    gum style --foreground 196 "❌ ERROR: KUBECONFIG is not set. Please target your NAI cluster first."
    exit 1
fi

if command -v uuidgen &> /dev/null; then
    GEN_UUID="uuidgen"
elif [ -f /proc/sys/kernel/random/uuid ]; then
    GEN_UUID="cat /proc/sys/kernel/random/uuid"
else
    gum style --foreground 196 "❌ ERROR: Cannot generate UUIDs natively for API Idempotency."
    exit 1
fi

gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "Nutanix Unified Storage (NUS) Configuration for NAI"

# --- LOAD CACHE ---
CACHE_FOUND="false"
if [ -f ".nkp_phase3_cache.env" ]; then
    source .nkp_phase3_cache.env
    CACHE_FOUND="true"
    gum style --foreground 82 "✔ Found Phase 3 Cache: Pre-loading Prism details."
fi

PC_ENDPOINT="${PC_ENDPOINT:-}"
NUTANIX_USER="${NUTANIX_USER:-admin}"
NUTANIX_PASSWORD="${NUTANIX_PASSWORD:-}"
PE_CLUSTER="${PE_CLUSTER:-}"
SUBNET="${SUBNET:-}"
TARGET_NAMESPACE="nai-system"
STORAGE_CLASS_NAME="nai-nfs-storage"

# --- DETERMINE DEPLOYMENT PATH ---
echo ""
gum style --foreground 99 -- "--- Storage Infrastructure Status ---"
echo "Does this Nutanix environment already have a Nutanix File Server deployed?"
DEPLOY_MODE=$(gum choose "Yes, configure StorageClass for an EXISTING File Server" "No, provision a NEW File Server from scratch")

# --- GATHER PRISM CREDENTIALS ---
echo ""
gum style --foreground 99 -- "--- Prism Central Authentication ---"
if [ "$CACHE_FOUND" == "false" ]; then
    PC_ENDPOINT=$(gum input --prompt "Prism Central IP/FQDN: ")
    NUTANIX_USER=$(gum input --prompt "Prism Central Username: " --value "admin")
    NUTANIX_PASSWORD=$(gum input --password --prompt "Prism Central Password: ")
fi

# ==============================================================================
# BRANCH A: PROVISION NEW FILE SERVER (v4 API)
# ==============================================================================
if [ "$DEPLOY_MODE" == "No, provision a NEW File Server from scratch" ]; then
    echo ""
    gum style --foreground 99 -- "--- New File Server Sizing & Networking ---"
    
    if [ "$CACHE_FOUND" == "false" ]; then
        PE_CLUSTER=$(gum input --prompt "Prism Element Target Cluster: ")
        SUBNET=$(gum input --prompt "AHV Subnet Name for Files: ")
    fi
    
    FILE_SERVER_NAME=$(gum input --prompt "New File Server Name: " --value "NAI-Files")
    FS_DOMAIN=$(gum input --prompt "Internal Domain Name (e.g., local): " --value "nai.local")
    FS_CAPACITY_GIB=$(gum input --prompt "Storage Capacity (in GiB): " --value "1024")
    DNS_IP=$(gum input --prompt "DNS Server IP: " --value "8.8.8.8")
    NTP_IP=$(gum input --prompt "NTP Server IP: " --value "pool.ntp.org")
    FS_NODES=$(gum choose --header "Number of File Server VMs (3 recommended for HA):" "1" "3" "5")

    gum confirm "Ready to provision '${FILE_SERVER_NAME}' on cluster '${PE_CLUSTER}' via v4 API?" || exit 0

    CAPACITY_BYTES=$(( FS_CAPACITY_GIB * 1024 * 1024 * 1024 ))

    gum style --foreground 212 "--> Querying Prism Central v4 APIs for Infrastructure extIds..."

    CLUSTER_EXTID=$(curl -k -s -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
      -H "Accept: application/json" \
      -X GET "https://${PC_ENDPOINT}:9440/api/clustermgmt/v4.0/config/clusters?\$filter=name%20eq%20'${PE_CLUSTER}'" | \
      jq -r '.data[0].extId')

    if [ "$CLUSTER_EXTID" == "null" ] || [ -z "$CLUSTER_EXTID" ]; then
        gum style --foreground 196 "❌ ERROR: Could not find extId for Cluster '${PE_CLUSTER}'."
        exit 1
    fi

    SUBNET_EXTID=$(curl -k -s -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
      -H "Accept: application/json" \
      -X GET "https://${PC_ENDPOINT}:9440/api/networking/v4.0/config/subnets?\$filter=name%20eq%20'${SUBNET}'" | \
      jq -r '.data[0].extId')

    if [ "$SUBNET_EXTID" == "null" ] || [ -z "$SUBNET_EXTID" ]; then
        gum style --foreground 196 "❌ ERROR: Could not find extId for Subnet '${SUBNET}'."
        exit 1
    fi

    cat <<EOF > create-files-v4-payload.json
{
  "name": "${FILE_SERVER_NAME}",
  "capacityBytes": ${CAPACITY_BYTES},
  "clusterExtId": "${CLUSTER_EXTID}",
  "domainName": "${FS_DOMAIN}",
  "numVms": ${FS_NODES},
  "clientNetwork": { "subnetExtId": "${SUBNET_EXTID}" },
  "storageNetwork": { "subnetExtId": "${SUBNET_EXTID}" },
  "dnsServerIpList": [ { "ipv4": { "value": "${DNS_IP}" } } ],
  "ntpServerIpList": [ { "ipv4": { "value": "${NTP_IP}" } } ]
}
EOF

    REQ_ID=$(eval "$GEN_UUID")

    gum spin --spinner dot --spinner.foreground 212 --title "Transmitting provisioning request to Prism Central..." -- \
        sleep 2

    RESPONSE=$(curl -k -s -w "\n%{http_code}" -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Ntnx-Request-Id: ${REQ_ID}" \
        -d @create-files-v4-payload.json \
        -X POST "https://${PC_ENDPOINT}:9440/api/files/v4.0/config/file-servers")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [[ "$HTTP_CODE" == 200 || "$HTTP_CODE" == 202 ]]; then
        TASK_EXTID=$(echo "$BODY" | jq -r '.data.extId')
        gum style --foreground 82 "✔ API Accepted: File Server deployment triggered! (Task extId: ${TASK_EXTID:-In Progress})"
    else
        gum style --foreground 196 "❌ ERROR: API rejected the request with HTTP $HTTP_CODE."
        echo "$BODY" | jq .
        exit 1
    fi
    rm -f create-files-v4-payload.json

# ==============================================================================
# BRANCH B: USE EXISTING FILE SERVER
# ==============================================================================
else
    echo ""
    gum style --foreground 99 -- "--- Existing File Server Details ---"
    FILE_SERVER_NAME=$(gum input --prompt "Existing File Server Name: " --placeholder "e.g., NAI-Files")
    
    gum confirm "Ready to map K8s StorageClass to '${FILE_SERVER_NAME}'?" || exit 0
fi

# ==============================================================================
# COMMON STEP: CONFIGURE KUBERNETES CSI & STORAGECLASS
# ==============================================================================
echo ""
gum style --foreground 212 "--> Ensuring namespace '${TARGET_NAMESPACE}' exists..."
kubectl create namespace "${TARGET_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null

gum spin --spinner dot --spinner.foreground 212 --title "Configuring Kubernetes CSI Secret & StorageClass..." -- sleep 2

cat <<EOF > ntnx-csi-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: ntnx-secret
  namespace: ${TARGET_NAMESPACE}
stringData:
  key: ${PC_ENDPOINT}:9440:${NUTANIX_USER}:${NUTANIX_PASSWORD}
EOF

cat <<EOF > nai-nfs-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: csi.nutanix.com
parameters:
  dynamicProv: "ENABLED"
  csi.storage.k8s.io/provisioner-secret-name: "ntnx-secret"
  csi.storage.k8s.io/provisioner-secret-namespace: "${TARGET_NAMESPACE}"
  csi.storage.k8s.io/node-publish-secret-name: "ntnx-secret"
  csi.storage.k8s.io/node-publish-secret-namespace: "${TARGET_NAMESPACE}"
  csi.storage.k8s.io/controller-expand-secret-name: "ntnx-secret"
  csi.storage.k8s.io/controller-expand-secret-namespace: "${TARGET_NAMESPACE}"
  nfsServerName: "${FILE_SERVER_NAME}"
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

kubectl apply -f ntnx-csi-secret.yaml > /dev/null
kubectl apply -f nai-nfs-storageclass.yaml > /dev/null
rm -f ntnx-csi-secret.yaml nai-nfs-storageclass.yaml

# ==============================================================================
# FINAL NOTIFICATIONS
# ==============================================================================
clear
if [ "$DEPLOY_MODE" == "No, provision a NEW File Server from scratch" ]; then
    gum style --border double --margin "1" --padding "1 2" --border-foreground 226 "⚠️ IMPORTANT: Nutanix Files Deployment is in Progress!"
    echo "The Kubernetes StorageClass '${STORAGE_CLASS_NAME}' has been created successfully,"
    echo "but the underlying Nutanix File Server VMs are still booting in AHV."
    echo ""
    echo "Please wait approximately 10-15 minutes for the File Server cluster to form"
    echo "before you run the NAI deployment script, otherwise the NAI pods will fail"
    echo "to bind to their persistent volumes."
else
    gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "✔ Storage Configuration Complete!"
    echo "The '${STORAGE_CLASS_NAME}' StorageClass is bound to ${FILE_SERVER_NAME}."
    echo "You are now ready to run the NAI 2.6 Deployment script."
fi