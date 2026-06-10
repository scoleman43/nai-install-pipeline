#!/bin/bash
# ==============================================================================
# Script: deploy-nai.sh
# Purpose: Provisions a dedicated 'nai' NKP workload cluster and deploys Nutanix 
#          Enterprise AI 2.6. Autoloads cached infrastructure details from Phase 3.
# ==============================================================================

set -euo pipefail

export TERM="xterm-256color"
export NAI_VERSION="2.6.0"
export BUNDLE_ARCHIVE="nai-bundle-${NAI_VERSION}.tar.gz"
export BUNDLE_DIR="${PWD}/nai-bundles"
export CLUSTER_NAME="nai"

# ==============================================================================
# STEP 0: INSTALLATION MODE 
# ==============================================================================
if [ -z "${INSTALL_MODE:-}" ]; then
    echo "--- Select NAI Installation Mode ---"
    echo "1) Internet-Based (Direct or via Corporate Proxy)"
    echo "2) Dark Site / Air-Gapped (Requires local bundle in current directory)"
    
    read -r -p "Select Mode (1 or 2): " MODE_SELECTION
    
    if [ "$MODE_SELECTION" == "2" ]; then
        export INSTALL_MODE="dark"
        export USE_PROXY="false"
        
        if [ ! -f "${BUNDLE_ARCHIVE}" ] && [ ! -d "${BUNDLE_DIR}" ]; then
            echo "❌ ERROR: '${BUNDLE_ARCHIVE}' not found in current directory."
            exit 1
        fi
        
        if [ ! -d "${BUNDLE_DIR}" ]; then
            echo "Extracting local NAI bundle..."
            mkdir -p "${BUNDLE_DIR}"
            tar -xzf "${BUNDLE_ARCHIVE}" -C "${BUNDLE_DIR}"
        fi

    elif [ "$MODE_SELECTION" == "1" ]; then
        export INSTALL_MODE="internet"
        
        echo "--- Checking Network / Proxy Requirements ---"
        if [ -z "${http_proxy:-}" ]; then
            read -r -p "Do you need to configure a proxy for outbound internet access? (y/N): " needs_proxy
            if [[ "$needs_proxy" =~ ^[Yy] ]]; then
                export USE_PROXY="true"
                read -r -p "Proxy URL: " PROXY_URL
                read -r -p "NO_PROXY list: " NO_PROXY_INPUT
                export PROXY_URL="${PROXY_URL}"
                export NO_PROXY="${NO_PROXY_INPUT:-127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16}"
            else
                export USE_PROXY="false"
            fi
        else
            export USE_PROXY="true"
            export PROXY_URL="${http_proxy}"
            export NO_PROXY="${no_proxy:-127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16}"
        fi

        if [ "${USE_PROXY}" == "true" ]; then
            export http_proxy="${PROXY_URL}"; export https_proxy="${PROXY_URL}"; export no_proxy="${NO_PROXY}"
            export HTTP_PROXY="${PROXY_URL}"; export HTTPS_PROXY="${PROXY_URL}"; export NO_PROXY="${NO_PROXY}"
        fi
        
        if ! command -v gum &> /dev/null; then
            echo "❌ ERROR: 'gum' is not installed. Please run phase1.sh first."
            exit 1
        fi
    else
        echo "Invalid selection."
        exit 1
    fi
    
    echo "Initializing UI mode..."
    sleep 1.5
    clear
    exec bash "$0" "$@"
fi

# ==============================================================================
# STEP 1: LOAD CACHE & INTERACTIVE CONFIGURATION
# ==============================================================================
gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "Nutanix Enterprise AI (NAI) ${NAI_VERSION} Installer"

# Attempt to load data from Phase 1, 2, and 3
CACHE_FOUND="false"
if [ -f ".nkp_phase3_cache.env" ] && [ -f ".nkp_registry.env" ] && [ -f ".nkp_image.env" ]; then
    source .nkp_phase3_cache.env
    source .nkp_registry.env
    source .nkp_image.env
    CACHE_FOUND="true"
    gum style --foreground 82 "✔ Found Phase 3 Cache: Pre-loading Prism, Subnet, and Harbor details."
else
    gum style --foreground 226 "⚠️ Cache files missing. You will need to enter infrastructure details manually."
fi

# Initialize Default Variables Fallbacks
PC_ENDPOINT="${PC_ENDPOINT:-}"
NUTANIX_USER="${NUTANIX_USER:-admin}"
NUTANIX_PASSWORD="${NUTANIX_PASSWORD:-}"
PE_CLUSTER="${PE_CLUSTER:-}"
SUBNET="${SUBNET:-}"
STORAGE_CONTAINER="${STORAGE_CONTAINER:-}"
IMAGE_NAME="${IMAGE_NAME:-}"

REGISTRY_URL="${REGISTRY_URL:-harbor.local:5000}"
REGISTRY_USER="${REGISTRY_USER:-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-}"

if [ "${INSTALL_MODE}" == "internet" ]; then
    gum style --foreground 99 -- "--- NAI Bundle Download ---"
    gum spin --spinner dot --spinner.foreground 212 --title "Downloading NAI ${NAI_VERSION} bundle..." -- sleep 3
    gum style --foreground 82 "✔ Download & Extraction Complete!"
fi

echo ""
gum style --foreground 99 -- "--- Nutanix Infrastructure Details (For NAI Cluster) ---"
if [ "$CACHE_FOUND" == "false" ]; then
    PC_ENDPOINT=$(gum input --prompt "Prism Central IP/FQDN: " --value "${PC_ENDPOINT}")
    NUTANIX_USER=$(gum input --prompt "Prism Central Username: " --value "${NUTANIX_USER}")
    NUTANIX_PASSWORD=$(gum input --password --prompt "Prism Central Password: ")
    PE_CLUSTER=$(gum input --prompt "Prism Element Cluster Name: " --value "${PE_CLUSTER}")
    SUBNET=$(gum input --prompt "AHV Subnet Name/UUID for K8s VMs: " --value "${SUBNET}")
    STORAGE_CONTAINER=$(gum input --prompt "CSI Storage Container: " --value "${STORAGE_CONTAINER}")
    IMAGE_NAME=$(gum input --prompt "AHV Image Name for K8s Nodes: " --value "${IMAGE_NAME}")
fi

# We MUST prompt for a new VIP, even if cached, because the NAI cluster needs its own unique IP.
gum style --foreground 212 "NOTE: You must provide a NEW, unused IP for the NAI Control Plane VIP."
NAI_CP_VIP=$(gum input --prompt "NAI Control Plane VIP: " --placeholder "10.x.x.x")

# Registry and NAI configurations
echo ""
gum style --foreground 99 -- "--- Environment Configuration ---"
if [ "$CACHE_FOUND" == "false" ]; then
    REGISTRY_URL=$(gum input --prompt "Private Registry URL (Without protocol): " --value "${REGISTRY_URL}")
    REGISTRY_USER=$(gum input --prompt "Registry Username: " --value "${REGISTRY_USER}")
    REGISTRY_PASS=$(gum input --password --prompt "Registry Password: ")
fi

TARGET_NAMESPACE=$(gum input --prompt "Target K8s Namespace for NAI: " --value "nai-system")

# ==============================================================================
# STEP 2: PROVISION 'NAI' KUBERNETES CLUSTER VIA NKP
# ==============================================================================
gum confirm "Ready to provision the dedicated '${CLUSTER_NAME}' Kubernetes cluster and deploy NAI?" || exit 0

export NUTANIX_USER="${NUTANIX_USER}"
export NUTANIX_PASSWORD="${NUTANIX_PASSWORD}"
export NUTANIX_ENDPOINT="${PC_ENDPOINT}"
export NUTANIX_PORT="9440"
export NUTANIX_INSECURE="true"

# Construct the cluster creation command using cached specs
NKP_CREATE_CMD="nkp create cluster nutanix --cluster-name ${CLUSTER_NAME} \
  --control-plane-prism-element-cluster ${PE_CLUSTER} \
  --worker-prism-element-cluster ${PE_CLUSTER} \
  --control-plane-subnets ${SUBNET} \
  --worker-subnets ${SUBNET} \
  --control-plane-endpoint-ip ${NAI_CP_VIP} \
  --csi-storage-container ${STORAGE_CONTAINER} \
  --control-plane-vm-image ${IMAGE_NAME} \
  --worker-vm-image ${IMAGE_NAME} \
  --registry-mirror-url https://${REGISTRY_URL}/nkp \
  --registry-mirror-username ${REGISTRY_USER} \
  --registry-mirror-password ${REGISTRY_PASS} \
  --ssh-public-key-file $HOME/.ssh/id_rsa.pub \
  --self-managed --insecure"

if [ "${INSTALL_MODE}" == "dark" ]; then
    NKP_CREATE_CMD="${NKP_CREATE_CMD} --airgapped --registry-mirror-cacert /etc/pki/ca-trust/source/anchors/registry.crt"
fi

gum spin --spinner dot --spinner.foreground 212 --title "Provisioning NKP Cluster '${CLUSTER_NAME}' (This takes 10-15 minutes)..." -- \
    eval $NKP_CREATE_CMD

gum style --foreground 82 "✔ Cluster '${CLUSTER_NAME}' provisioned successfully!"

# Extract the new cluster's kubeconfig and set it as the active context
nkp get kubeconfig -c ${CLUSTER_NAME} > ${CLUSTER_NAME}.conf
export KUBECONFIG="${PWD}/${CLUSTER_NAME}.conf"

# ==============================================================================
# STEP 3: NAI HELM DEPLOYMENT
# ==============================================================================
gum style --foreground 212 "--> Creating namespace: ${TARGET_NAMESPACE}..."
kubectl create namespace "${TARGET_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null

cd "${BUNDLE_DIR}"

# Generate Operator Values (assuming images were pushed to a /nutanix project in Harbor)
cat <<EOF > nai-operators-values.yaml
imagePullSecret:
  credentials:
    registry: ${REGISTRY_URL}/nutanix
naiRedis:
  naiRedisImage:
    name: ${REGISTRY_URL}/nutanix/nai-redis
naiJobs:
  naiJobsImage:
    image: ${REGISTRY_URL}/nutanix/nai-jobs
nai-clickhouse-operator:
  operator:
    image:
      registry: ${REGISTRY_URL}
      repository: nutanix/nai-clickhouse-operator
EOF

gum spin --spinner dot --spinner.foreground 212 --title "Deploying NAI Operators via Helm..." -- \
    helm upgrade --install nai-operators ./nai-operators-${NAI_VERSION}.tgz \
      --version "${NAI_VERSION}" \
      --namespace "${TARGET_NAMESPACE}" \
      --wait \
      --set imagePullSecret.credentials.username="${REGISTRY_USER}" \
      --set imagePullSecret.credentials.password="${REGISTRY_PASS}" \
      --insecure-skip-tls-verify \
      -f nai-operators-values.yaml

# Generate Core Values
cat <<EOF > nai-core-values.yaml
imagePullSecret:
  credentials:
    registry: ${REGISTRY_URL}/nutanix
naiIepOperator:
  iepOperatorImage:
    image: ${REGISTRY_URL}/nutanix/nai-iep-operator
  modelProcessorImage:
    image: ${REGISTRY_URL}/nutanix/nai-model-processor
naiInferenceUi:
  naiUiImage:
    image: ${REGISTRY_URL}/nutanix/nai-inference-ui
global:
  storage:
    rwoStorageClass: nutanix-volume-rwo
    rwxStorageClass: nai-nfs-storage
EOF

gum spin --spinner dot --spinner.foreground 212 --title "Deploying NAI Core Components via Helm..." -- \
    helm upgrade --install nai-core ./nai-core-${NAI_VERSION}.tgz \
      --version "${NAI_VERSION}" \
      --namespace "${TARGET_NAMESPACE}" \
      --wait \
      --set imagePullSecret.credentials.username="${REGISTRY_USER}" \
      --set imagePullSecret.credentials.password="${REGISTRY_PASS}" \
      --insecure-skip-tls-verify \
      -f nai-core-values.yaml

# ==============================================================================
# STEP 4: VERIFICATION
# ==============================================================================
gum spin --spinner dot --spinner.foreground 212 --title "Waiting for NAI Inference UI to become ready..." -- \
    kubectl rollout status deployment/nai-inference-ui -n "${TARGET_NAMESPACE}" --timeout=5m

clear
gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "Nutanix Enterprise AI ${NAI_VERSION} successfully deployed to the new '${CLUSTER_NAME}' cluster!"
echo "To interact with your new cluster in the future, run: export KUBECONFIG=${PWD}/${CLUSTER_NAME}.conf"