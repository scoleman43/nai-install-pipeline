# Nutanix Enterprise AI (NAI) Installer

A deployment script for **Nutanix Enterprise AI**, designed for air-gapped (dark site) environments. Both installation modes — Dark Site and Internet-Based — deploy NAI entirely from a local Harbor registry; no container images are ever pulled from the internet during the install. The Internet-Based mode is a hybrid that only uses an outbound connection to download prerequisite tooling (such as `helm` or `skopeo`) onto the bastion, not to source NKP or NAI images.

> **This is an add-on to the [NKP Install Pipeline](https://github.com/scoleman43/nkp-install-pipeline).** It is designed to run on the same bastion host after the NKP pipeline has completed. The tools, Harbor registry, and Kubernetes cluster provisioned by that pipeline are direct prerequisites for this installer.

---

## Table of Contents

- [Prerequisites](#prerequisites)
  - [Nutanix Files — Pre-Configuration Required](#nutanix-files--pre-configuration-required)
- [Quick Start](#quick-start)
- [Installation Modes](#installation-modes)
- [Configuration Reference](#configuration-reference)
- [Uninstall & Reinstall](#uninstall--reinstall)
- [Architecture Notes](#architecture-notes)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Complete the NKP Install Pipeline First

This installer assumes the [NKP Install Pipeline](https://github.com/scoleman43/nkp-install-pipeline) has already been run to completion on the bastion host. The following are provided by that pipeline and do not need to be installed separately:

| Provided By NKP Pipeline | What It Supplies |
|--------------------------|-----------------|
| `phase1.sh` | Docker runtime, `gum`, `kubectl`, `helm`, `skopeo`, and a running Harbor registry with a valid SSL certificate |
| `phase2.sh` | AHV node OS image staged in Prism Central |
| `phase3.sh` | A running NKP Kubernetes cluster with a valid kubeconfig (`./<cluster-name>.conf`) and the Harbor `/nkp` project pre-populated |

If you are deploying NAI onto an **existing NKP cluster** that was not provisioned by the pipeline, ensure the following tools are available on your bastion before proceeding:

| Tool | Purpose |
|------|---------|
| `kubectl` | Kubernetes cluster interaction |
| `nkp` | Nutanix Kubernetes Platform CLI |
| `helm` | Chart deployment (auto-installed if missing in internet mode) |
| `docker` | Container image operations |
| `gum` | Interactive terminal UI — [install here](https://github.com/charmbracelet/gum) |
| `skopeo` | *(Recommended)* Faster image mirroring; falls back to `docker` if unavailable |

### Required Assets

Place the following NAI-specific bundle files in your working directory on the bastion:

**For Air-Gapped installs:**
- `*helm*.tar` or `*chart*.tar` — NAI Helm Charts bundle (from Nutanix Support Portal)
- `nai-v*.tar` or `*nai*image*.tar*` — NAI container image bundle

**For Internet-Connected installs:**
- `bundlenai-v<VERSION>.tar` — NAI bundle downloaded from Nutanix Portal

### Nutanix Files — Pre-Configuration Required

NAI uses Nutanix Files to provide RWX (ReadWriteMany) shared storage for model weights and inference data. This is separate from the block storage used by NKP and must be configured in Prism Central **before** running the NAI installer. The installer will fail at the CSI storage class step if Files is not ready.

Complete the following on your Nutanix Files file server before proceeding:

**1. Enable NFS**

NFSv4 must be enabled on the file server. In Prism Central, navigate to **Files → your file server → Protocol Configuration** and ensure NFS is enabled. NAI's CSI driver provisions NFS-backed PersistentVolumes dynamically, so this must be active before any PVCs are created.

**2. Verify DNS Resolution**

The NAI installer accepts either an IP address or an FQDN for the file server endpoint (`FILE_SERVER_FQDN_OR_IP`). Using an IP address will work and avoids any DNS dependency, but using an FQDN is recommended — it decouples the configuration from a specific IP, makes the setup more resilient to network changes, and is consistent with how Nutanix Files is typically referenced in production environments.

If using an FQDN, confirm DNS is resolving correctly before running the installer:

- In Prism Central, navigate to **Files → your file server → Configuration → DNS**
- If DNS is not set to automatic, select **Manual** and enter your DNS server details
- Use the built-in **DNS Verify** function to test resolution — every entry should show a green verified checkmark before proceeding
- Any entry that does not show a green checkmark indicates a DNS misconfiguration that will cause CSI volume operations to fail at runtime

> ⚠️ **Ubuntu DNS and `.local` domains:** Ubuntu uses `systemd-resolved`, which does not forward `.local` queries to the upstream DNS server — it treats them as mDNS/Bonjour and only resolves them on the local host. If your file server or any other infrastructure component uses a `.local` domain (e.g., `files-server.nutanix.local`), name resolution **will silently fail** on Ubuntu-based cluster nodes. Use `.internal` or a proper registered domain (e.g., `.corp`, `.com`) for all infrastructure DNS entries instead.

**3. Create a Files REST API User Account**

The NAI CSI driver authenticates to the Files REST API to manage NFS exports. Create a dedicated API user on the file server before running the installer:

- In Prism Central, navigate to **Files → your file server → Manage Roles**
- Create a user with **File Server Admin** or equivalent REST API access
- Note the username and password — the installer will prompt for these as `FILES_REST_USER` and `FILES_REST_PASSWORD`

The installer stores this credential in the `ntnx-secret` Kubernetes secret under the `files-key` field, alongside the Prism Central block storage credential.

### Additional Infrastructure Requirements

Beyond the NKP pipeline and Nutanix Files configuration, NAI also requires:

- If provisioning a **new dedicated NAI cluster** (rather than deploying onto the existing NKP cluster): additional VIPs for a second control plane and MetalLB range

---

## Quick Start

These steps assume you are on the same bastion host where the NKP Install Pipeline completed.

### 1. Copy the NAI Scripts to the Bastion

```bash
# From the bastion host, in the same working directory as the NKP pipeline scripts
chmod +x nai-install.sh nai-teardown.sh
```

### 2. Stage Your NAI Bundle Files

```bash
# Your working directory should look something like this
ls -1
# phase1.sh
# phase2.sh
# phase3.sh
# nai-install.sh
# nai-teardown.sh
# nai-v2.7.0-helm-charts.tar       <-- NAI Helm bundle
# nai-v2.7.0-images.tar            <-- NAI image bundle
# nkp-prod-01.conf                 <-- kubeconfig from Phase 3
```

### 3. Run the Installer

```bash
./nai-install.sh
```

The installer is fully interactive and will prompt for all required values.

### 4. Follow the Interactive Prompts

**Stage 1 — Network Mode**
```
? Please select the installation network mode:
  > Dark Site / Air-Gapped (Local bundle)
    Internet-Based (Direct or Proxy)
```

**Stage 2 — Cluster Mode**

> ⚠️ **Recommendation:** NAI should be deployed on its own dedicated Kubernetes cluster, separate from the NKP management plane cluster provisioned by the NKP pipeline. Running NAI on the same cluster as the NKP management plane is not recommended — NAI's GPU workloads, inference operators, and gateway components are resource-intensive and can destabilize the management plane. Use **Provision a NEW cluster** to create a dedicated NAI cluster, or point to an existing dedicated cluster if one has already been provisioned.

```
? Do you need to provision a new NKP cluster for NAI, or use an existing one?
  > Provision a NEW cluster
    Use an EXISTING cluster
```

**Stage 3 — Credentials & Endpoints**

You will be prompted for:
- Prism Central IP/FQDN and credentials
- Nutanix Files server short name, IP/FQDN, and REST API credentials
- Private registry URL, username, and password — use the same Harbor instance deployed by `phase1.sh`
- *(If provisioning a new dedicated cluster)* PE cluster name, AHV subnet, storage container, VM image, control plane VIP, and MetalLB IP range

**Stage 4 — Deployment**

The installer will confirm before making any changes, then:
1. Seed NAI images into your Harbor registry under the `/nkp` project
2. Provision a new NKP cluster (if selected)
3. Deploy all NAI components via Helm

---

## Installation Modes

Both modes are fundamentally air-gapped installs — NAI components are always deployed from the local Harbor registry, never pulled from the internet. The difference between the two modes is only in how the bastion acquires prerequisite tooling before the install begins.

### Dark Site (Fully Offline)

The true air-gapped path. No outbound internet access is required at any point.

- All NAI images and Helm charts are sourced from local bundle files staged on the bastion
- Prerequisite tools (`helm`, `skopeo`) are already present from the NKP pipeline, or can be bootstrapped from the `nkp-prereqs-bundle.tar` available on the NKP pipeline's GitHub Releases page
- All NAI component deployments pull exclusively from the local Harbor registry

### Internet-Based (Hybrid)

A hybrid mode for bastions that have a temporary or limited outbound connection. The NKP and NAI installs themselves remain fully air-gapped — internet access is only used to fetch missing prerequisite binaries onto the bastion.

- Downloads and installs `helm` automatically if missing from the bastion
- Attempts to install `skopeo` via the system package manager (`apt` / `yum`)
- All NAI images and Helm charts are still sourced from local bundle files — no NAI or NKP container images are pulled from the internet during deployment

### Cluster Provisioning

| Option | Recommended | Description |
|--------|-------------|-------------|
| **Provision NEW — Self-Managed** | ✅ Yes | Creates a dedicated standalone NKP cluster for NAI; kubeconfig saved to `./<cluster-name>.conf` |
| **Provision NEW — Managed** | ✅ Yes | Creates a dedicated NAI cluster registered to an existing NKP Management Cluster |
| **Use Existing Cluster** | ⚠️ Only if dedicated | Deploys NAI onto an existing cluster — only appropriate if that cluster is already dedicated to NAI, not shared with the NKP management plane |

> ⚠️ **Do not install NAI on the same cluster as the NKP management plane.** NAI's inference operators, GPU workloads, and Envoy gateway components are resource-intensive and will compete with management plane services, risking instability for the entire NKP environment.

---

## Configuration Reference

All inputs are cached to `.nai_cache.env` on the local bastion after the first run. On subsequent runs, previously entered values are pre-filled — press **Enter** to accept cached values or type new ones to override. This file is generated by the script and exists only on the bastion; it is never committed to this repository.

> **Note:** `.nai_cache.env` contains plaintext credentials. Restrict its permissions with `chmod 600 .nai_cache.env` and delete it when no longer needed, or use the cache purge option in `nai-teardown.sh`.

| Variable | Description | Example |
|----------|-------------|---------|
| `PC_ENDPOINT` | Prism Central IP or FQDN | `10.0.0.10` |
| `NUTANIX_USER` | Prism Central username | `admin` |
| `FILE_SERVER_SHORT_NAME` | Logical name of Files server in Prism | `NAI-FS2` |
| `FILE_SERVER_FQDN_OR_IP` | Network endpoint for CSI pod | `10.0.0.20` |
| `FILES_REST_USER` | Files REST API username | `files-fs2` |
| `REGISTRY_URL` | Harbor registry from phase1.sh (no protocol prefix) | `harbor.local:5000` |
| `REGISTRY_USER` | Registry username | `admin` |
| `TARGET_NAMESPACE` | Kubernetes namespace for NAI | `nai-system` |
| `PE_CLUSTER` | Prism Element cluster name *(new clusters only)* | `PE-PROD` |
| `SUBNET` | AHV subnet name or UUID *(new clusters only)* | `VLAN-100` |
| `STORAGE_CONTAINER` | CSI storage container *(new clusters only)* | `default` |
| `IMAGE_NAME` | AHV VM image for K8s nodes *(new clusters only)* | `nkp-ubuntu-22.04` |
| `NAI_CP_VIP` | Control plane virtual IP *(new clusters only)* | `10.0.0.50` |
| `NAI_METALLB_RANGE` | MetalLB IP range *(new clusters only)* | `10.0.0.51-10.0.0.60` |

---

## Uninstall & Reinstall

The `nai-teardown.sh` script performs a complete, forced removal of NAI and all associated resources. It is the recommended path before any reinstall, version upgrade, or recovery from a broken state. It does not affect the underlying NKP cluster or the Harbor registry.

> ⚠️ **This operation is destructive.** All deployed models, configuration, and NAI data will be permanently deleted. The script will prompt for confirmation before proceeding.

### Running the Teardown

```bash
./nai-teardown.sh
```

If NAI was deployed into a non-default namespace, set the variable before running:

```bash
TARGET_NAMESPACE=my-nai-namespace ./nai-teardown.sh
```

### What It Does

The teardown runs in four stages:

**Stage 1 — Graceful Helm Removal**

Attempts clean `helm uninstall` for all releases in order:
- `gateway-helm` from `envoy-gateway-system`
- `nai-core`, `nai-operators`, `kserve`, `opentelemetry-operator`, `gateway-crds`, `kserve-crd` from `nai-system`

**Stage 2 — Forced Namespace Deletion**

Handles the common case where Kubernetes namespaces get stuck in `Terminating` due to lingering finalizers. For each of `nai-system`, `nai-admin`, and `envoy-gateway-system` it:
1. Issues a non-blocking `kubectl delete namespace`
2. Strips finalizers from all standard resources (`pods`, `pvc`, `secrets`, etc.)
3. Strips finalizers from all Custom Resources (Envoy, KServe, and others)
4. Force-finalizes the namespace via the Kubernetes raw API

**Stage 3 — Cluster-Scoped Cleanup**

Removes resources that live outside any namespace and would otherwise block a clean reinstall:
- `GatewayClass` objects (`traefik`, `envoy-gateway-gatewayclass`)
- `StorageClass` (`nai-nfs-storage`)
- Envoy `ClusterRole` and `ClusterRoleBinding` (prevents collision on reinstall)
- Finalizers on any stuck `envoyproxy.io` or `kserve.io` CRDs

**Stage 4 — Credential Cache**

Optionally deletes `.nai_cache.env`. Recommended if credentials have changed or you are handing off to another operator.

### Reinstalling After Teardown

Once the teardown completes, you can run the installer immediately:

```bash
./nai-install.sh
```

Cached values from `.nai_cache.env` (if kept) will pre-fill all prompts, making a reinstall fast. The installer also performs its own ghost CRD check on startup as a second safety net.

---

## Architecture Notes

### Storage (Split-Brain CSI)

The installer creates two storage classes:

- **`nutanix-volume`** — Block storage (RWO) for stateful workloads, using the same Nutanix CSI driver already deployed by the NKP pipeline
- **`nai-nfs-storage`** — Nutanix Files-backed NFS (RWX) for shared model storage, requiring a separately provisioned Files server

The Files CSI secret (`ntnx-secret`) stores both the Prism Central block storage credentials and the Files REST API credentials under separate keys.

### Version-Aware Envoy Gateway Patching

For NAI **≤ 2.7.x**, the installer applies a compatibility patch that:
- Deploys the Envoy Gateway into a dedicated `envoy-gateway-system` namespace
- Injects an `EnvoyGateway` ConfigMap with AI extension manager hooks wired to `ai-gateway-controller`
- Configures Redis rate limiting pointed at the NAI-managed Redis instance
- Bounces Envoy control plane pods to pick up the new configuration

For NAI **2.8+**, standard Helm deployment is used and the patch is skipped automatically.(assuming this gets fixed in the next upcoming release)

### Ghost CRD Cleanup

Before deployment, the installer removes finalizers from any stuck `envoyproxy.io` or `kserve.io` CRDs left over from a previous teardown, preventing namespace deadlocks.

---

## Troubleshooting

**Namespace stuck in `Terminating`**
Run `nai-teardown.sh` to strip finalizers and force-close the namespace before reinstalling. The installer will exit early with an explicit error if this condition is detected on startup.

**Helm deploy fails with a 1MB limit error**
CRD-heavy charts (`gateway-crds`, `kserve-crd`) are applied directly via `kubectl apply --server-side` to bypass this limit. If you see this error for another chart, check the chart size and consider splitting CRDs manually.

**Images not found in registry**
The installer checks `/v2/nkp/nutanix/nai-api/tags/list` to detect existing images. If the check returns a non-200 status, it will attempt to push from the local bundle. Ensure your Harbor instance is running and that the `/nkp` project exists — both are set up by `phase1.sh` in the NKP pipeline.

**`gum` not found**
If you did not run the NKP pipeline, install `gum` manually:
```bash
# Linux (Debian/Ubuntu)
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update && sudo apt install gum
```

**`skopeo` unavailable in air-gapped mode**
If `skopeo` cannot be found, the installer falls back to `docker load` + `docker push`. Ensure the Docker daemon is running and that your user is in the `docker` group (the NKP `phase1.sh` handles this — if you skipped it, run `sudo usermod -aG docker $USER` and re-login).
