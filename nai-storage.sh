#!/bin/bash
# ==============================================================================
# Script: nai-storage.sh
# Purpose: Handles end-to-end RWX storage configuration for NAI.
#          Provisions a Nutanix File Server via forward-compatible v4 APIs.
#          Includes a schema bypass for the v4.0.a6 DNS parsing bug.
# ==============================================================================

set -euo pipefail

export TERM="xterm-256color"

# --- PRE-FLIGHT CHECKS ---
if ! command -v gum &> /dev/null; then
    echo "Error: 'gum' is not installed."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    gum style --foreground 196 -- "❌ ERROR: 'jq' is required to parse Nutanix APIs. Please install it."
    exit 1
fi

if [ -z "${KUBECONFIG:-}" ] && [ ! -f "$HOME/.kube/config" ]; then
    gum style --foreground 196 -- "❌ ERROR: KUBECONFIG is not set. Please target your NAI cluster first."
    exit 1
fi

if command -v uuidgen &> /dev/null; then
    GEN_UUID="uuidgen"
elif [ -f /proc/sys/kernel/random/uuid ]; then
    GEN_UUID="cat /proc/sys/kernel/random/uuid"
else
    gum style --foreground 196 -- "❌ ERROR: Cannot generate UUIDs natively for API Idempotency."
    exit 1
fi

# --- STEP 1: INITIAL UI RESET ---
clear
gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "Nutanix Unified Storage (NUS) Configuration for NAI"

# --- STEP 2: MULTI-LAYERED CACHE RECOVERY ---
if [ -f ".nkp_phase3_cache.env" ]; then
    # shellcheck source=/dev/null
    source .nkp_phase3_cache.env
    gum style --foreground 82 -- "✔ Loaded Infrastructure Foundation from Global Phase 3 Cache."
fi

if [ -f ".nai_storage_cache.env" ]; then
    # shellcheck source=/dev/null
    source .nai_storage_cache.env
    gum style --foreground 82 -- "✔ Loaded Storage Parameters from Local Script Cache."
fi

# Initialize fallbacks to prevent unbound variable crashes
PC_ENDPOINT="${PC_ENDPOINT:-}"
NUTANIX_USER="${NUTANIX_USER:-admin}"
NUTANIX_PASSWORD="${NUTANIX_PASSWORD:-}"
PE_CLUSTER="${PE_CLUSTER:-}"
SUBNET="${SUBNET:-}"
FILE_SERVER_NAME="${FILE_SERVER_NAME:-NAI-Files}"
FILES_VERSION="${FILES_VERSION:-}"
FS_DOMAIN="${FS_DOMAIN:-nutanix.local}"
FS_CAPACITY_GIB="${FS_CAPACITY_GIB:-1024}"
CLIENT_IPS="${CLIENT_IPS:-}"
CLIENT_NETMASK="${CLIENT_NETMASK:-255.255.255.0}"
CLIENT_GATEWAY="${CLIENT_GATEWAY:-}"
STORAGE_IPS="${STORAGE_IPS:-}"
STORAGE_NETMASK="${STORAGE_NETMASK:-255.255.255.0}"
STORAGE_GATEWAY="${STORAGE_GATEWAY:-}"
TARGET_NAMESPACE="nai-system"
STORAGE_CLASS_NAME="nai-nfs-storage"

# --- DETERMINE DEPLOYMENT PATH ---
echo ""
gum style --foreground 99 -- "--- Storage Infrastructure Status ---"
echo "Does this Nutanix environment already have a Nutanix File Server deployed?"
DEPLOY_MODE=$(gum choose "Yes, configure StorageClass for an EXISTING File Server" "No, provision a NEW File Server from scratch")

# --- GATHER/REVIEW FOUNDATIONAL PRISM CREDENTIALS ---
echo ""
gum style --foreground 99 -- "--- Prism Central Authentication ---"
PC_ENDPOINT=$(gum input --prompt "Prism Central IP/FQDN: " --value "${PC_ENDPOINT}")
NUTANIX_USER=$(gum input --prompt "Prism Central Username: " --value "${NUTANIX_USER}")

if [ -n "${NUTANIX_PASSWORD}" ]; then
    gum style --foreground 240 -- "(Press Enter to keep cached password, or type a new one to override)"
    NEW_PASS=$(gum input --password --prompt "Prism Central Password: ")
    if [ -n "$NEW_PASS" ]; then NUTANIX_PASSWORD="$NEW_PASS"; fi
else
    while [[ -z "${NUTANIX_PASSWORD}" ]]; do NUTANIX_PASSWORD=$(gum input --password --prompt "Prism Central Password: "); done
fi

# ==============================================================================
# BRANCH A: PROVISION NEW FILE SERVER (PC 7.5 COMPLIANT v4 API)
# ==============================================================================
if [ "$DEPLOY_MODE" == "No, provision a NEW File Server from scratch" ]; then
    echo ""
    gum style --foreground 99 -- "--- New File Server Sizing & Networking ---"
    
    PE_CLUSTER=$(gum input --prompt "Prism Element Target Cluster Name: " --value "${PE_CLUSTER}")
    SUBNET=$(gum input --prompt "AHV Subnet Name for Files Network: " --value "${SUBNET}")
    
    FILE_SERVER_NAME=$(gum input --prompt "New File Server Name: " --value "${FILE_SERVER_NAME}")
    
    FILES_VERSION=$(gum input --prompt "Nutanix Files Version (e.g., 4.4.0.2 or 5.0.0.1): " --value "${FILES_VERSION}")
    while [[ -z "$FILES_VERSION" ]]; do FILES_VERSION=$(gum input --prompt "Nutanix Files Version is required: "); done

    FS_DOMAIN=$(gum input --prompt "Internal Domain Name (e.g., local): " --value "${FS_DOMAIN}")
    FS_CAPACITY_GIB=$(gum input --prompt "Storage Capacity (in GiB): " --value "${FS_CAPACITY_GIB}")

    FS_NODES=$(gum choose --header "Number of File Server VMs (3 recommended for HA):" "1" "3" "5")

    echo ""
    gum style --foreground 99 -- "--- IP Address Management (IPAM) ---"
    echo "Is the AHV subnet configured with an IPAM pool?"
    IPAM_CHOICE=$(gum choose "No, explicitly assign Static IPs (Unmanaged Subnet)" "Yes, rely on AHV IPAM (Automated / Managed Subnet)")

    if [[ "$IPAM_CHOICE" == *"No, explicitly assign Static IPs"* ]]; then
        
        if [ "$FS_NODES" -eq 1 ]; then
            REQUIRED_IPS=1
            gum style --foreground 214 -- "⚠️ Note: A 1-node File Server requires exactly 1 IP per network (No HA VIP)."
        else
            REQUIRED_IPS=$((FS_NODES + 1))
            gum style --foreground 214 -- "⚠️ Note: A ${FS_NODES}-node File Server requires exactly ${REQUIRED_IPS} IPs per network (${FS_NODES} nodes + 1 VIP)."
        fi
        
        echo ""
        gum style --foreground 111 -- ">> Client Network Routing"
        
        while true; do
            CLIENT_IPS=$(gum input --prompt "Client Static IPs (${REQUIRED_IPS} required): " --value "${CLIENT_IPS}")
            if [ -z "$CLIENT_IPS" ]; then continue; fi
            IP_COUNT=$(echo "$CLIENT_IPS" | awk -F',' '{print NF}')
            if [ "$IP_COUNT" -eq "$REQUIRED_IPS" ]; then break; fi
            gum style --foreground 196 "❌ Error: You provided ${IP_COUNT} IP(s). Exactly ${REQUIRED_IPS} are required."
            CLIENT_IPS=""
        done
        
        CLIENT_NETMASK=$(gum input --prompt "Client Subnet Mask: " --value "${CLIENT_NETMASK}")
        while [[ -z "$CLIENT_NETMASK" ]]; do CLIENT_NETMASK=$(gum input --prompt "Client Subnet Mask is required: "); done
        
        CLIENT_GATEWAY=$(gum input --prompt "Client Default Gateway: " --value "${CLIENT_GATEWAY}")
        while [[ -z "$CLIENT_GATEWAY" ]]; do CLIENT_GATEWAY=$(gum input --prompt "Client Default Gateway is required: "); done

        echo ""
        gum style --foreground 111 -- ">> Storage Network Routing"
        
        while true; do
            STORAGE_IPS=$(gum input --prompt "Storage Static IPs (${REQUIRED_IPS} required): " --value "${STORAGE_IPS}")
            if [ -z "$STORAGE_IPS" ]; then continue; fi
            IP_COUNT=$(echo "$STORAGE_IPS" | awk -F',' '{print NF}')
            if [ "$IP_COUNT" -eq "$REQUIRED_IPS" ]; then break; fi
            gum style --foreground 196 "❌ Error: You provided ${IP_COUNT} IP(s). Exactly ${REQUIRED_IPS} are required."
            STORAGE_IPS=""
        done
        
        STORAGE_NETMASK=$(gum input --prompt "Storage Subnet Mask: " --value "${STORAGE_NETMASK}")
        while [[ -z "$STORAGE_NETMASK" ]]; do STORAGE_NETMASK=$(gum input --prompt "Storage Subnet Mask is required: "); done
        
        STORAGE_GATEWAY=$(gum input --prompt "Storage Default Gateway: " --value "${STORAGE_GATEWAY}")
        while [[ -z "$STORAGE_GATEWAY" ]]; do STORAGE_GATEWAY=$(gum input --prompt "Storage Default Gateway is required: "); done
    else
        CLIENT_IPS=""
        CLIENT_NETMASK=""
        CLIENT_GATEWAY=""
        STORAGE_IPS=""
        STORAGE_NETMASK=""
        STORAGE_GATEWAY=""
    fi

    {
        echo "export FILE_SERVER_NAME=\"${FILE_SERVER_NAME}\""
        echo "export FILES_VERSION=\"${FILES_VERSION}\""
        echo "export FS_DOMAIN=\"${FS_DOMAIN}\""
        echo "export FS_CAPACITY_GIB=\"${FS_CAPACITY_GIB}\""
        echo "export PE_CLUSTER=\"${PE_CLUSTER}\""
        echo "export SUBNET=\"${SUBNET}\""
        echo "export CLIENT_IPS=\"${CLIENT_IPS}\""
        echo "export CLIENT_NETMASK=\"${CLIENT_NETMASK}\""
        echo "export CLIENT_GATEWAY=\"${CLIENT_GATEWAY}\""
        echo "export STORAGE_IPS=\"${STORAGE_IPS}\""
        echo "export STORAGE_NETMASK=\"${STORAGE_NETMASK}\""
        echo "export STORAGE_GATEWAY=\"${STORAGE_GATEWAY}\""
    } > .nai_storage_cache.env
    chmod 600 .nai_storage_cache.env

    gum confirm "Ready to provision '${FILE_SERVER_NAME}' via PC 7.5 validated v4 API?" || exit 0

    gum style --foreground 212 -- "--> Querying Prism Central v4 APIs for Cluster & Subnet extIds..."

    CLUSTER_EXTID=$(curl -k -s -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
      -H "Accept: application/json" \
      --get "https://${PC_ENDPOINT}:9440/api/clustermgmt/v4.0/config/clusters" \
      --data-urlencode "\$filter=name eq '${PE_CLUSTER}'" | \
      jq -r '.data[0].extId')

    if [ "$CLUSTER_EXTID" == "null" ] || [ -z "$CLUSTER_EXTID" ]; then
        gum style --foreground 196 -- "❌ ERROR: Could not find v4 extId for Cluster '${PE_CLUSTER}'."
        exit 1
    fi

    SUBNET_EXTID=$(curl -k -s -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
      -H "Accept: application/json" \
      --get "https://${PC_ENDPOINT}:9440/api/networking/v4.0/config/subnets" \
      --data-urlencode "\$filter=name eq '${SUBNET}'" | \
      jq -r '.data[0].extId')

    if [ "$SUBNET_EXTID" == "null" ] || [ -z "$SUBNET_EXTID" ]; then
        gum style --foreground 196 -- "❌ ERROR: Could not find v4 extId for Subnet '${SUBNET}'."
        exit 1
    fi

    # Clean string inputs to prevent schema injection failures
    FILE_SERVER_NAME_CLEAN=$(echo "$FILE_SERVER_NAME" | tr -d '\r\n\t ')
    FILES_VERSION_CLEAN=$(echo "$FILES_VERSION" | tr -d '\r\n\t ')
    FS_DOMAIN_CLEAN=$(echo "$FS_DOMAIN" | tr -d '\r\n\t ')
    FS_CAPACITY_GIB_CLEAN=$(echo "$FS_CAPACITY_GIB" | tr -d '\r\n\t ')
    CLIENT_GATEWAY_CLEAN=$(echo "$CLIENT_GATEWAY" | tr -d '\r\n\t ')
    CLIENT_NETMASK_CLEAN=$(echo "$CLIENT_NETMASK" | tr -d '\r\n\t ')
    STORAGE_GATEWAY_CLEAN=$(echo "$STORAGE_GATEWAY" | tr -d '\r\n\t ')
    STORAGE_NETMASK_CLEAN=$(echo "$STORAGE_NETMASK" | tr -d '\r\n\t ')

    if [ -n "$CLIENT_IPS" ]; then
        CLIENT_IP_JSON=$(echo "$CLIENT_IPS" | tr -d '\r\n\t ' | tr ',' '\n' | awk '{print "{\"ipv4\": {\"value\": \""$1"\"}}"}' | paste -sd, -)
        EXTERNAL_NETWORKS_PAYLOAD="[ { \"networkExtId\": \"${SUBNET_EXTID}\", \"isManaged\": false, \"defaultGateway\": { \"ipv4\": { \"value\": \"${CLIENT_GATEWAY_CLEAN}\" } }, \"subnetMask\": { \"ipv4\": { \"value\": \"${CLIENT_NETMASK_CLEAN}\" } }, \"staticIpList\": [ ${CLIENT_IP_JSON} ] } ]"
    else
        EXTERNAL_NETWORKS_PAYLOAD="[ { \"networkExtId\": \"${SUBNET_EXTID}\", \"isManaged\": true } ]"
    fi

    if [ -n "$STORAGE_IPS" ]; then
        STORAGE_IP_JSON=$(echo "$STORAGE_IPS" | tr -d '\r\n\t ' | tr ',' '\n' | awk '{print "{\"ipv4\": {\"value\": \""$1"\"}}"}' | paste -sd, -)
        INTERNAL_NETWORKS_PAYLOAD="[ { \"networkExtId\": \"${SUBNET_EXTID}\", \"isManaged\": false, \"defaultGateway\": { \"ipv4\": { \"value\": \"${STORAGE_GATEWAY_CLEAN}\" } }, \"subnetMask\": { \"ipv4\": { \"value\": \"${STORAGE_NETMASK_CLEAN}\" } }, \"staticIpList\": [ ${STORAGE_IP_JSON} ] } ]"
    else
        INTERNAL_NETWORKS_PAYLOAD="[ { \"networkExtId\": \"${SUBNET_EXTID}\", \"isManaged\": true } ]"
    fi

    # --- DETECT AVAILABLE API REVISION ---
    echo ""
    gum style --foreground 212 -- "--> Probing for supported Files API revision..."
    
    SUPPORTED_API=""
    for revision in "v4.0.b1" "v4.0.a6" "v4.0.a2"; do
        PROBE=$(curl -k -s -o /dev/null -w "%{http_code}" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Accept: application/json" \
            "https://${PC_ENDPOINT}:9440/api/files/${revision}/config/file-servers")
        
        if [[ "$PROBE" == "200" || "$PROBE" == "204" ]]; then
            SUPPORTED_API="$revision"
            gum style --foreground 82 -- "✔ Detected supported API revision: ${SUPPORTED_API}"
            break
        fi
    done

    if [ -z "$SUPPORTED_API" ]; then
        gum style --foreground 196 -- "❌ ERROR: Could not detect a supported Files v4 API revision."
        exit 1
    fi

    # THE SKELETON KEY BYPASS: 
    # Passing empty arrays satisfies the Gateway's strict property check, 
    # but skips the buggy Java microservice parsing logic entirely!
    cat <<EOF > create-files-v4-payload.json
{
  "name": "${FILE_SERVER_NAME_CLEAN}",
  "version": "${FILES_VERSION_CLEAN}",
  "sizeInGib": ${FS_CAPACITY_GIB_CLEAN},
  "clusterExtId": "${CLUSTER_EXTID}",
  "dnsDomainName": "${FS_DOMAIN_CLEAN}",
  "nvmsCount": ${FS_NODES},
  "externalNetworks": ${EXTERNAL_NETWORKS_PAYLOAD},
  "internalNetworks": ${INTERNAL_NETWORKS_PAYLOAD},
  "dnsServers": [],
  "ntpServers": []
}
EOF

    REQ_ID=$(eval "$GEN_UUID")

    gum spin --spinner dot --spinner.foreground 212 --title "Transmitting v4 provisioning payload to Prism Central..." -- sleep 2

    RESPONSE=$(curl -k -s -w "\n%{http_code}" -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Ntnx-Request-Id: ${REQ_ID}" \
        -d @create-files-v4-payload.json \
        -X POST "https://${PC_ENDPOINT}:9440/api/files/${SUPPORTED_API}/config/file-servers")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [[ "$HTTP_CODE" == 200 || "$HTTP_CODE" == 202 ]]; then
        TASK_EXTID=$(echo "$BODY" | jq -r '.data.extId // "Success"')
        gum style --foreground 82 -- "✔ Success: v4 File Server deployment accepted! (Task: ${TASK_EXTID})"
    else
        gum style --foreground 196 -- "❌ ERROR: API rejected the payload with HTTP $HTTP_CODE."
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
    FILE_SERVER_NAME=$(gum input --prompt "Existing File Server Name: " --value "${FILE_SERVER_NAME}")
    
    {
        echo "export FILE_SERVER_NAME=\"${FILE_SERVER_NAME}\""
    } > .nai_storage_cache.env
    chmod 600 .nai_storage_cache.env

    gum confirm "Ready to map K8s StorageClass to '${FILE_SERVER_NAME}'?" || exit 0
fi

# ==============================================================================
# COMMON STEP: CONFIGURE KUBERNETES CSI & STORAGECLASS
# ==============================================================================
echo ""
gum style --foreground 212 -- "--> Ensuring namespace '${TARGET_NAMESPACE}' exists..."
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
    echo "You are now ready to run the NAI deployment script."
fi