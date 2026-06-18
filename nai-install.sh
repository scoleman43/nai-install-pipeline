#!/bin/bash
# ==============================================================================
# Script: nai-install.sh
# Purpose: Deploys Nutanix Enterprise AI (Production-Hardened)
# Architecture: Air-Gap + Split-Brain CSI + Version-Aware Envoy Gateway Patching
# ==============================================================================

set -euo pipefail

clear 
export TERM="xterm-256color"
export BUNDLE_DIR="${PWD}/nai-bundles"
export NAI_CLUSTER_NAME="nai"

# ==============================================================================
# HELPER FUNCTIONS: SAFE DEPLOYMENT CAPABILITIES
# ==============================================================================
version_le() {
    [ "$1" == "$(echo -e "$1\n$2" | sort -V | head -n1)" ]
}

deploy_chart() {
    local RELEASE_NAME=$1
    local CHART_DIR=$2
    shift 2
    
    if [ -z "$CHART_DIR" ] || [ ! -d "$CHART_DIR" ]; then
        gum style --foreground 214 "⚠️ Warning: Chart for ${RELEASE_NAME} not found. Skipping."
        return 0
    fi
    
    gum style --foreground 212 "⚙ Deploying ${RELEASE_NAME} via Helm..."
    
    if ! helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
        --namespace "${TARGET_NAMESPACE}" \
        --wait --insecure-skip-tls-verify "$@" > "/tmp/${RELEASE_NAME}_install.log" 2>&1; then
        
        gum style --border double --margin "1" --padding "1 2" --border-foreground 196 "❌ FATAL ERROR: Helm failed to deploy ${RELEASE_NAME}!"
        cat "/tmp/${RELEASE_NAME}_install.log"
        exit 1
    fi
}

deploy_crd_chart_directly() {
    local CHART_NAME=$1
    local CHART_DIR=$2
    if [ -n "$CHART_DIR" ] && [ -d "$CHART_DIR" ]; then
        gum style --foreground 212 "⚙ Deploying ${CHART_NAME} directly via API (Bypassing Helm 1MB limit)..."
        
        if [ -d "${CHART_DIR}/crds" ]; then
            kubectl apply --server-side --force-conflicts -f "${CHART_DIR}/crds/" >/dev/null 2>&1 || true
        fi
        if [ -d "${CHART_DIR}/templates" ]; then
            kubectl apply --server-side --force-conflicts -f "${CHART_DIR}/templates/" >/dev/null 2>&1 || true
        fi
    fi
}

# ==============================================================================
# STEP 0: DEPENDENCY PRE-FLIGHT
# ==============================================================================
if ! command -v gum &> /dev/null; then
    echo "❌ ERROR: 'gum' is not installed."
    exit 1
fi

gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "Nutanix Enterprise AI (NAI) Installer"

MISSING_TOOLS=""
for tool in kubectl nkp tar curl docker; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [ -n "$MISSING_TOOLS" ]; then
    gum style --foreground 196 "❌ FATAL ERROR: Missing required dependencies:$MISSING_TOOLS"
    exit 1
fi

# ==============================================================================
# STEP 1: INSTALLATION MODE & TARGETED EXTRACTION
# ==============================================================================
echo "Please select the installation network mode:"
MODE_SELECTION=$(gum choose "Dark Site / Air-Gapped (Local bundle)" "Internet-Based (Direct or Proxy)")

if [ "$MODE_SELECTION" == "Dark Site / Air-Gapped (Local bundle)" ]; then
    export INSTALL_MODE="dark"
    HELM_ARCHIVES=( *helm*.tar* *chart*.tar* )
    if [ ${#HELM_ARCHIVES[@]} -eq 0 ] || [ ! -e "${HELM_ARCHIVES[0]}" ]; then
        gum style --foreground 196 "❌ ERROR: No NAI Helm Charts bundle (*helm*.tar) found."
        exit 1
    fi
    HELM_ARCHIVE="${HELM_ARCHIVES[0]}"
    export NAI_VERSION=$(echo "${HELM_ARCHIVE}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | tr '\n' ' ' | awk '{print $1}' || echo "2.7.0")
    mkdir -p "${BUNDLE_DIR}/charts"
    tar -xf "${HELM_ARCHIVE}" -C "${BUNDLE_DIR}/charts"
else
    export INSTALL_MODE="internet"
    export NAI_VERSION=$(gum input --prompt "Enter NAI Version to deploy: " --value "2.7.0")
    echo ""
    gum spin --spinner dot --spinner.foreground 212 --title "Extracting downloaded NAI ${NAI_VERSION} bundle..." -- sleep 3
    mkdir -p "${BUNDLE_DIR}/charts"
    tar -xf "bundlenai-v${NAI_VERSION}.tar" -C "${BUNDLE_DIR}/charts" 2>/dev/null || true
fi

if ! command -v helm &> /dev/null; then
    if [ "${INSTALL_MODE}" == "internet" ]; then
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh && sudo ./get_helm.sh >/dev/null 2>&1 && rm -f get_helm.sh
    else
        PREREQ_TARBALL=$(ls nkp-prereqs-bundle.tar* 2>/dev/null | awk '{print $1}' | head -n 1 || true)
        if [ -n "$PREREQ_TARBALL" ]; then
            mkdir -p .temp_helm
            tar -xf "$PREREQ_TARBALL" -C .temp_helm --strip-components=2 "nkp-prereqs-bundle/binaries/helm" 2>/dev/null || true
            sudo mv .temp_helm/helm /usr/local/bin/helm
            rm -rf .temp_helm && chmod +x /usr/local/bin/helm
        fi
    fi
fi

export USE_SKOPEO="true"
if ! command -v skopeo &> /dev/null; then
    if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else OS="unknown"; fi
    if [ "${INSTALL_MODE}" == "internet" ]; then
        if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
            sudo apt-get update -y -qq && sudo apt-get install -y -qq skopeo containers-common >/dev/null 2>&1 || true
        elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
            sudo yum install -y -q skopeo >/dev/null 2>&1 || true
        fi
    else
        PREREQ_TARBALL=$(ls nkp-prereqs-bundle.tar* 2>/dev/null | awk '{print $1}' | head -n 1 || true)
        if [ -n "$PREREQ_TARBALL" ]; then
            mkdir -p .temp_packages
            tar -xf "$PREREQ_TARBALL" -C .temp_packages --strip-components=2 "nkp-prereqs-bundle/packages" 2>/dev/null || true
            if ls .temp_packages/*skopeo* 1> /dev/null 2>&1; then
                if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
                    sudo dpkg -i .temp_packages/*skopeo*.deb .temp_packages/*containers-common*.deb 2>/dev/null || true
                elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
                    sudo rpm -Uvh --force --nodeps .temp_packages/*skopeo*.rpm .temp_packages/*containers-common*.rpm 2>/dev/null || true
                fi
            fi
            rm -rf .temp_packages
        fi
    fi
    if ! command -v skopeo &> /dev/null; then export USE_SKOPEO="false"; fi
fi

# ==============================================================================
# STEP 2: ENVIRONMENT CONFIGURATION GATHERING
# ==============================================================================
echo ""
echo "Do you need to provision a new NKP cluster for NAI, or use an existing one?"
CLUSTER_MODE=$(gum choose "Provision a NEW cluster" "Use an EXISTING cluster")

MGMT_MODE="none"
if [ "$CLUSTER_MODE" == "Provision a NEW cluster" ]; then
    echo ""
    echo "How should this new cluster be managed?"
    MGMT_MODE=$(gum choose "Managed by an existing NKP Management Cluster" "Self-Managed (Standalone)")
fi

# Load the simple cache
if [ -f ".nai_cache.env" ]; then source .nai_cache.env; fi

FILE_SERVER_SHORT_NAME="${FILE_SERVER_SHORT_NAME:-${FILE_SERVER_NAME:-}}"
FILE_SERVER_FQDN_OR_IP="${FILE_SERVER_FQDN_OR_IP:-${FILE_SERVER_NAME:-}}"
PC_ENDPOINT="${PC_ENDPOINT:-}"
NUTANIX_USER="${NUTANIX_USER:-admin}"
FILES_REST_USER="${FILES_REST_USER:-files-fs2}"
PE_CLUSTER="${PE_CLUSTER:-}"
SUBNET="${SUBNET:-}"
STORAGE_CONTAINER="${STORAGE_CONTAINER:-}"
IMAGE_NAME="${IMAGE_NAME:-}"
REGISTRY_URL="${REGISTRY_URL:-harbor.local:5000}"
REGISTRY_USER="${REGISTRY_USER:-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-nai-system}"
NAI_CP_VIP="${NAI_CP_VIP:-}"
NAI_METALLB_RANGE="${NAI_METALLB_RANGE:-}"
MGMT_KUBECONFIG="${MGMT_KUBECONFIG:-}"
MGMT_WORKSPACE_NAMESPACE="${MGMT_WORKSPACE_NAMESPACE:-}"

if [ "$CLUSTER_MODE" == "Provision a NEW cluster" ]; then
    if [ "$MGMT_MODE" == "Managed by an existing NKP Management Cluster" ]; then
        MGMT_KUBECONFIG=$(gum input --prompt "Path to Management Kubeconfig: " --value "${MGMT_KUBECONFIG:-$HOME/.kube/config}")
        MGMT_WORKSPACE_NAMESPACE=$(gum input --prompt "Target Workspace Namespace: " --value "${MGMT_WORKSPACE_NAMESPACE:-default}")
    fi
else
    DEF_KUBECONFIG="${PWD}/${NAI_CLUSTER_NAME}.conf"
    if [ ! -f "$DEF_KUBECONFIG" ]; then DEF_KUBECONFIG="$HOME/.kube/config"; fi
    EXISTING_KUBECONFIG=$(gum input --prompt "Path to Kubeconfig file: " --value "${EXISTING_KUBECONFIG:-$DEF_KUBECONFIG}")
    export KUBECONFIG="${EXISTING_KUBECONFIG}"
    chmod 600 "${KUBECONFIG}" 2>/dev/null || true
fi

gum style --foreground 99 -- "--- Nutanix Prism Central & Block Storage Details ---"
PC_ENDPOINT=$(gum input --prompt "Prism Central IP/FQDN: " --value "${PC_ENDPOINT:-}")
NUTANIX_USER=$(gum input --prompt "Prism Central Username: " --value "${NUTANIX_USER:-admin}")

if [ -n "${NUTANIX_PASSWORD:-}" ]; then
    gum style --foreground 240 "(Press Enter to keep cached password, or type a new one to override)"
    NEW_PASS=$(gum input --password --prompt "Prism Central Password: ")
    if [ -n "$NEW_PASS" ]; then NUTANIX_PASSWORD="$NEW_PASS"; fi
else
    while [[ -z "${NUTANIX_PASSWORD:-}" ]]; do NUTANIX_PASSWORD=$(gum input --password --prompt "Prism Central Password: "); done
fi

echo ""
gum style --foreground 99 -- "--- Nutanix Files & RWX Storage Details ---"
gum style --foreground 214 "⚠️ REQUIREMENT 1: The Logical Short Name for Prism Central (e.g., NAI-FS2)."
FILE_SERVER_SHORT_NAME=$(gum input --prompt "File Server Short Name: " --value "${FILE_SERVER_SHORT_NAME:-}")

gum style --foreground 214 "⚠️ REQUIREMENT 2: The Direct Network Endpoint for the CSI Pod (IP or FQDN)."
FILE_SERVER_FQDN_OR_IP=$(gum input --prompt "File Server IP or FQDN: " --value "${FILE_SERVER_FQDN_OR_IP:-}")

FILES_REST_USER=$(gum input --prompt "Files REST API Username: " --value "${FILES_REST_USER:-files-fs2}")

if [ -n "${FILES_REST_PASSWORD:-}" ]; then
    gum style --foreground 240 "(Press Enter to keep cached password, or type a new one to override)"
    NEW_PASS=$(gum input --password --prompt "Files REST API Password: ")
    if [ -n "$NEW_PASS" ]; then FILES_REST_PASSWORD="$NEW_PASS"; fi
else
    while [[ -z "${FILES_REST_PASSWORD:-}" ]]; do FILES_REST_PASSWORD=$(gum input --password --prompt "Files REST API Password: "); done
fi

if [ "$CLUSTER_MODE" == "Provision a NEW cluster" ]; then
    echo ""
    gum style --foreground 99 -- "--- Nutanix Infrastructure Details (For NEW NAI Cluster) ---"
    PE_CLUSTER=$(gum input --prompt "Prism Element Cluster Name: " --value "${PE_CLUSTER:-}")
    SUBNET=$(gum input --prompt "AHV Subnet Name/UUID for K8s VMs: " --value "${SUBNET:-}")
    STORAGE_CONTAINER=$(gum input --prompt "CSI Storage Container: " --value "${STORAGE_CONTAINER:-}")
    IMAGE_NAME=$(gum input --prompt "AHV Image Name for K8s Nodes: " --value "${IMAGE_NAME:-}")
    NAI_CP_VIP=$(gum input --prompt "NAI Control Plane VIP: " --value "${NAI_CP_VIP:-}")
    NAI_METALLB_RANGE=$(gum input --prompt "NAI MetalLB IP Range: " --value "${NAI_METALLB_RANGE:-}")
fi

echo ""
gum style --foreground 99 -- "--- Registry Configuration ---"
REGISTRY_URL=$(gum input --prompt "Private Registry URL (Without protocol): " --value "${REGISTRY_URL:-}")
REGISTRY_USER=$(gum input --prompt "Registry Username: " --value "${REGISTRY_USER:-admin}")

if [ -n "${REGISTRY_PASS:-}" ]; then
    NEW_PASS=$(gum input --password --prompt "Registry Password (Enter to keep cached): ")
    if [ -n "$NEW_PASS" ]; then REGISTRY_PASS="$NEW_PASS"; fi
else
    while [[ -z "${REGISTRY_PASS:-}" ]]; do REGISTRY_PASS=$(gum input --password --prompt "Registry Password: "); done
fi

TARGET_NAMESPACE=$(gum input --prompt "Target K8s Namespace for NAI: " --value "${TARGET_NAMESPACE:-nai-system}")

{
    echo "export REGISTRY_URL=\"${REGISTRY_URL}\""
    echo "export REGISTRY_USER=\"${REGISTRY_USER}\""
    echo "export REGISTRY_PASS=\"${REGISTRY_PASS}\""
    echo "export TARGET_NAMESPACE=\"${TARGET_NAMESPACE}\""
    echo "export PC_ENDPOINT=\"${PC_ENDPOINT}\""
    echo "export NUTANIX_USER=\"${NUTANIX_USER}\""
    echo "export NUTANIX_PASSWORD=\"${NUTANIX_PASSWORD}\""
    echo "export FILE_SERVER_SHORT_NAME=\"${FILE_SERVER_SHORT_NAME}\""
    echo "export FILE_SERVER_FQDN_OR_IP=\"${FILE_SERVER_FQDN_OR_IP}\""
    echo "export FILES_REST_USER=\"${FILES_REST_USER}\""
    echo "export FILES_REST_PASSWORD=\"${FILES_REST_PASSWORD}\""
    echo "export PE_CLUSTER=\"${PE_CLUSTER}\""
    echo "export SUBNET=\"${SUBNET}\""
    echo "export STORAGE_CONTAINER=\"${STORAGE_CONTAINER}\""
    echo "export IMAGE_NAME=\"${IMAGE_NAME}\""
    echo "export NAI_CP_VIP=\"${NAI_CP_VIP}\""
    echo "export NAI_METALLB_RANGE=\"${NAI_METALLB_RANGE}\""
    echo "export MGMT_KUBECONFIG=\"${MGMT_KUBECONFIG}\""
    echo "export MGMT_WORKSPACE_NAMESPACE=\"${MGMT_WORKSPACE_NAMESPACE}\""
} > .nai_cache.env

# ==============================================================================
# STEP 3: IMAGE REGISTRY SEEDING
# ==============================================================================
echo ""
gum style --foreground 99 -- "--- Image Registry Seeding ---"
IMAGE_BUNDLES=( nai-v*.tar *nai*image*.tar* *image*.tar* )
GUESSED_BUNDLE=""
for b in "${IMAGE_BUNDLES[@]}"; do
    if [[ -f "$b" && "$b" != *helm* ]]; then GUESSED_BUNDLE="$b"; break; fi
done

IMAGE_CHECK_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" -u "${REGISTRY_USER}:${REGISTRY_PASS}" "https://${REGISTRY_URL}/v2/nkp/nutanix/nai-api/tags/list" || echo "000")

if [[ "$IMAGE_CHECK_STATUS" == "200" ]]; then
    gum style --foreground 82 "✔ NAI images already detected in mirror."
else
    IMAGE_LIST=$(tar -xOf "$GUESSED_BUNDLE" manifest.json | grep -o '"RepoTags":\[[^]]*\]' | grep -o '"nutanix[^"]*"' | tr -d '"' || true)
    if [ "$USE_SKOPEO" != "true" ]; then
        docker load -i "$GUESSED_BUNDLE"
        echo "${REGISTRY_PASS}" | docker login "${REGISTRY_URL}" -u "${REGISTRY_USER}" --password-stdin
    fi
    for img in $IMAGE_LIST; do
        NEW_TAG="${REGISTRY_URL}/nkp/${img}"
        if [ "$USE_SKOPEO" == "true" ]; then
            skopeo copy --dest-tls-verify=false --dest-creds="${REGISTRY_USER}:${REGISTRY_PASS}" "docker-archive:${GUESSED_BUNDLE}:${img}" "docker://${NEW_TAG}" >/dev/null 2>&1 || true
        else
            docker tag "$img" "$NEW_TAG" && docker push "$NEW_TAG" >/dev/null 2>&1 || true
        fi
    done
fi

# ==============================================================================
# STEP 4: PROVISION CLUSTER (IF SELECTED)
# ==============================================================================
if [ "$CLUSTER_MODE" == "Provision a NEW cluster" ]; then
    if ! gum confirm "Ready to provision the NEW '${NAI_CLUSTER_NAME}' Kubernetes cluster and deploy NAI?"; then exit 0; fi

    NKP_CREATE_CMD="nkp create cluster nutanix --cluster-name \"${NAI_CLUSTER_NAME}\" \
      --endpoint \"https://${PC_ENDPOINT}:9440\" \
      --control-plane-prism-element-cluster \"${PE_CLUSTER}\" \
      --worker-prism-element-cluster \"${PE_CLUSTER}\" \
      --control-plane-subnets \"${SUBNET}\" \
      --worker-subnets \"${SUBNET}\" \
      --control-plane-endpoint-ip \"${NAI_CP_VIP}\" \
      --kubernetes-service-load-balancer-ip-range \"${NAI_METALLB_RANGE}\" \
      --csi-storage-container \"${STORAGE_CONTAINER}\" \
      --control-plane-vm-image \"${IMAGE_NAME}\" \
      --worker-vm-image \"${IMAGE_NAME}\" \
      --worker-vcpus 12 \
      --worker-memory 32 \
      --worker-disk-size 150 \
      --control-plane-disk-size 150 \
      --registry-mirror-url \"https://${REGISTRY_URL}/nkp\" \
      --registry-mirror-username \"${REGISTRY_USER}\" \
      --registry-mirror-password \"${REGISTRY_PASS}\" \
      --registry-mirror-cacert \"/opt/registry/certs/domain.crt\" \
      --ssh-public-key-file \"$HOME/.ssh/id_rsa.pub\" \
      --insecure"

    if [ "$MGMT_MODE" == "Self-Managed (Standalone)" ]; then
        NKP_CREATE_CMD="${NKP_CREATE_CMD} --self-managed"
    else
        NKP_CREATE_CMD="${NKP_CREATE_CMD} --kubeconfig \"${MGMT_KUBECONFIG}\" --namespace \"${MGMT_WORKSPACE_NAMESPACE}\""
    fi

    eval "$NKP_CREATE_CMD"
    
    if [ "$MGMT_MODE" == "Self-Managed (Standalone)" ]; then
        nkp get kubeconfig -c "${NAI_CLUSTER_NAME}" > "${PWD}/${NAI_CLUSTER_NAME}.conf"
    else
        nkp get kubeconfig -c "${NAI_CLUSTER_NAME}" -n "${MGMT_WORKSPACE_NAMESPACE}" --kubeconfig "${MGMT_KUBECONFIG}" > "${PWD}/${NAI_CLUSTER_NAME}.conf"
    fi
    export KUBECONFIG="${PWD}/${NAI_CLUSTER_NAME}.conf"
else
    CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "unknown-context")
    if ! gum confirm "Ready to deploy NAI to existing cluster context: ${CURRENT_CTX}?"; then exit 0; fi
fi

# ==============================================================================
# STEP 5: NAMESPACE SAFETY & GATEWAY CONFLICT RESOLUTION 
# ==============================================================================
NS_STATUS=$(kubectl get namespace "${TARGET_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
if [ "$NS_STATUS" == "Terminating" ]; then
    gum style --foreground 196 "❌ ERROR: The namespace '${TARGET_NAMESPACE}' is stuck in the 'Terminating' state."
    echo "Please execute your teardown script to clear the finalizers before reinstalling."
    exit 1
fi

gum style --foreground 212 "🧹 Evicting pre-existing gateway class conflicts (Traefik)..."
kubectl delete gatewayclass traefik 2>/dev/null || true

kubectl create namespace "${TARGET_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true

gum style --foreground 212 "🔐 Safely storing storage secrets..."
kubectl delete secret ntnx-secret -n "${TARGET_NAMESPACE}" 2>/dev/null || true

kubectl create secret generic ntnx-secret -n "${TARGET_NAMESPACE}" \
  --from-literal=key="${PC_ENDPOINT}:9440:${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
  --from-literal=files-key="${FILE_SERVER_FQDN_OR_IP}:${FILES_REST_USER}:${FILES_REST_PASSWORD}"

cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nai-nfs-storage
provisioner: csi.nutanix.com
parameters:
  storageType: NutanixFiles
  dynamicProv: "ENABLED"
  csi.storage.k8s.io/provisioner-secret-name: "ntnx-secret"
  csi.storage.k8s.io/provisioner-secret-namespace: "${TARGET_NAMESPACE}"
  csi.storage.k8s.io/node-publish-secret-name: "ntnx-secret"
  csi.storage.k8s.io/node-publish-secret-namespace: "${TARGET_NAMESPACE}"
  csi.storage.k8s.io/controller-expand-secret-name: "ntnx-secret"
  csi.storage.k8s.io/controller-expand-secret-namespace: "${TARGET_NAMESPACE}"
  nfsServerName: "${FILE_SERVER_SHORT_NAME}"
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

rm -rf "${BUNDLE_DIR}/unpacked" && mkdir -p "${BUNDLE_DIR}/unpacked"
shopt -s nullglob
for chart in "${BUNDLE_DIR}/charts"/*.tgz; do
    chart_name=$(basename "$chart" .tgz)
    mkdir -p "${BUNDLE_DIR}/unpacked/${chart_name}"
    tar -xzf "$chart" -C "${BUNDLE_DIR}/unpacked/${chart_name}" --strip-components=1
done
shopt -u nullglob

# ==============================================================================
# STEP 6: CORE ENGINE DEPLOYMENT + VERSION-AWARE ENVOY PATCH
# ==============================================================================
gum style --foreground 212 "🚀 Installing foundational operators with Unified AI Gateway enabled..."

gum style --foreground 214 "🧹 Purging stuck Envoy/KServe CRDs from previous teardowns..."
STUCK_CRDS=$(kubectl get crd -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E 'envoyproxy.io|kserve.io' || true)
for crd in $STUCK_CRDS; do
    gum style --foreground 196 "   -> Ripping finalizers off ghost CRD: $crd"
    kubectl patch crd "$crd" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
done
sleep 2

GATEWAY_CRD_DIR=$(find "${BUNDLE_DIR}/unpacked" -maxdepth 1 -name "gateway-crds-helm-*" | head -n 1 || true)
deploy_crd_chart_directly "gateway-crds" "$GATEWAY_CRD_DIR"

KSERVE_CRD_DIR=$(find "${BUNDLE_DIR}/unpacked" -maxdepth 1 -name "kserve-crd-*" | head -n 1 || true)
deploy_crd_chart_directly "kserve-crd" "$KSERVE_CRD_DIR"

OTEL_DIR=$(find "${BUNDLE_DIR}/unpacked" -maxdepth 1 -name "opentelemetry-operator-*" | head -n 1 || true)
deploy_chart "opentelemetry-operator" "$OTEL_DIR"

KSERVE_DIR=$(find "${BUNDLE_DIR}/unpacked" -maxdepth 1 -name "kserve-v*" | head -n 1 || true)
deploy_chart "kserve" "$KSERVE_DIR" \
    --set "kserve.controller.deploymentMode=RawDeployment"

# --- VERSION-AWARE ENVOY NAMESPACE CONFIGURATION ENTRYPOINT ---
GATEWAY_HELM_DIR=$(find "${BUNDLE_DIR}/unpacked" -maxdepth 1 -name "gateway-helm-*" | head -n 1 || true)
if [ -n "$GATEWAY_HELM_DIR" ]; then

    if version_le "$NAI_VERSION" "2.7.99"; then
        gum style --foreground 214 "⚠️ NAI Version ${NAI_VERSION} detected. Applying the Envoy Gateway 2.7.x Patch..."
        
        # Force creation of dedicated infrastructure namespace
        kubectl create namespace envoy-gateway-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
        
        # Direct helm injection to protect data plane dependencies
        helm upgrade --install "gateway-helm" "$GATEWAY_HELM_DIR" \
            --namespace "envoy-gateway-system" \
            --wait --insecure-skip-tls-verify \
            --set "aiGateway.enabled=true" \
            --set "rateLimit.enabled=true" \
            --set "gateway.enabled=true" > "/tmp/gateway-helm_install.log" 2>&1 || {
                gum style --foreground 196 "❌ FATAL ERROR: Helm failed to deploy gateway-helm!"
                cat "/tmp/gateway-helm_install.log"
                exit 1
            }

        gum style --foreground 212 "⚙ Injecting Master AI Extension policies to envoy-gateway-config..."
        cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-gateway-config
  namespace: envoy-gateway-system
data:
  envoy-gateway.yaml: |
    apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: EnvoyGateway
    gateway:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
    logging:
      level:
        default: info
    provider:
      type: Kubernetes
      kubernetes:
        rateLimitDeployment:
          container:
            image: docker.io/envoyproxy/ratelimit:3fb70258
          patch:
            type: StrategicMerge
            value:
              spec:
                template:
                  spec:
                    containers:
                    - imagePullPolicy: IfNotPresent
                      name: envoy-ratelimit
        shutdownManager:
          image: docker.io/envoyproxy/gateway:v1.7.0
    rateLimit:
      backend:
        type: Redis
        redis:
          url: redis-standalone.${TARGET_NAMESPACE}.svc.cluster.local:6379
    extensionApis:
      enableBackend: true
      enableEnvoyPatchPolicy: true
    extensionManager:
      maxMessageSize: 11Mi
      backendResources:
      - group: inference.networking.k8s.io
        kind: InferencePool
        version: v1
      hooks:
        xdsTranslator:
          post:
          - Translation
          - Cluster
          - Route
          translation:
            cluster:
              includeAll: true
            listener:
              includeAll: true
            route:
              includeAll: true
            secret:
              includeAll: true
      service:
        fqdn:
          hostname: ai-gateway-controller.${TARGET_NAMESPACE}.svc.cluster.local
          port: 1063
EOF

        # Force control plane to pick up the expanded spec and rebuild proxy hooks
        kubectl delete deploy -n envoy-gateway-system -l app.kubernetes.io/name=envoy >/dev/null 2>&1 || true
        kubectl delete pod -n envoy-gateway-system -l control-plane=envoy-gateway >/dev/null 2>&1 || true

    else
        # For NAI 2.8+ versions, just let the standard deployment handle it natively
        gum style --foreground 82 "✔ NAI Version ${NAI_VERSION} is 2.8+. Bypassing the legacy Envoy patch..."
        
        deploy_chart "gateway-helm" "$GATEWAY_HELM_DIR" \
            --set "aiGateway.enabled=true" \
            --set "rateLimit.enabled=true" \
            --set "gateway.enabled=true"
    fi
fi
# --- END VERSION-AWARE ENVOY CONFIGURATION ---

NAI_OPS_DIR=$(find "${BUNDLE_DIR}/unpacked" -maxdepth 1 -name "nai-operators-*" | head -n 1 || true)
deploy_chart "nai-operators" "$NAI_OPS_DIR"

sleep 10

NAI_CORE_DIR=$(find "${BUNDLE_DIR}/unpacked" -maxdepth 1 -name "nai-core-*" | head -n 1 || true)
deploy_chart "nai-core" "$NAI_CORE_DIR" \
      --timeout 20m \
      --set "global.storage.storageClassName=nutanix-volume" \
      --set "global.storage.storageClassNameRWX=nai-nfs-storage" \
      --set "gateway.certManager.selfSigned=true"

# ==============================================================================
# STEP 7: CLEAN VERIFICATION
# ==============================================================================
echo ""
gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "✔ Nutanix Enterprise AI successfully deployed!"