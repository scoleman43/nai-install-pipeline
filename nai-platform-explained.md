# Understanding the NAI Platform: A Beginner's Guide to Every Moving Part

This guide assumes you've never touched Kubernetes before. Every term is defined the first time it's used. Every component is tied back to the exact step in `nai-install.sh` where it gets installed, so you can see the theory and the practice side by side.

---

## Part 0: The One Concept Everything Else Depends On

Before any of this makes sense, you need one mental picture: **Kubernetes**.

Imagine an apartment building manager. Tenants (your software programs) need a place to live (computer resources — CPU, memory, disk), they sometimes move out or get evicted (crash or get shut down), and new tenants move in constantly. A **Kubernetes cluster** is that apartment building plus the manager. You tell the manager "I need a 2-bedroom unit for this tenant," and Kubernetes finds space, moves the tenant in, and — critically — if that tenant's apartment catches fire (the program crashes), Kubernetes automatically finds them a new one and moves them back in, without you lifting a finger.

Each "tenant" running inside Kubernetes is called a **pod** (a small, wrapped bundle containing one or more running programs). The building itself is made of physical or virtual computers called **nodes**.

Everything below is either: (a) a *tenant* running inside this building, (b) a *service* the building provides to its tenants (like plumbing or electricity), or (c) a *tool you use from outside* to manage the building.

**NKP** (Nutanix Kubernetes Platform) is Nutanix's packaged, ready-to-run version of this apartment building — it's the actual Kubernetes distribution the script provisions in Step 4, via the `nkp create cluster` command (lines 490–522). Think of NKP as "Kubernetes, pre-assembled and warrantied by Nutanix," as opposed to building the apartment complex brick by brick yourself.

---

## Part 1: The Mind Map

```
NAI PLATFORM (built on Kubernetes / NKP)
│
├── 🏗️  FOUNDATION LAYER
│   ├── Kubernetes / NKP .......... the "building" — schedules and runs everything
│   └── kubectl / nkp CLI ......... the tools you type commands into, to talk to the building
│
├── 📦 PACKAGE MANAGEMENT
│   └── Helm ....................... installs/upgrades/removes whole applications as one unit
│         (used by the deploy_chart() function throughout the script)
│
├── 🌐 NETWORKING & TRAFFIC
│   ├── Gateway API CRDs ........... the "rulebook" defining how traffic routing works
│   ├── Envoy Gateway (gateway-helm) the actual traffic cop enforcing those rules
│   ├── cert-manager ............... issues/manages HTTPS certificates (the "locks")
│   └── MetalLB range ("NAI_METALLB_RANGE") hands out real IP addresses to services
│
├── 🔭 OBSERVABILITY (seeing what's happening inside)
│   ├── OpenTelemetry Operator ..... collects logs/metrics/traces from every component
│   └── Prometheus CRDs (monitors, rules) the metrics-alerting rulebook
│
├── 🤖 MODEL SERVING
│   └── KServe ...................... runs and exposes the actual AI/ML models
│
├── 💾 STORAGE
│   ├── Nutanix CSI Driver + StorageClass  connects pods to real disks
│   ├── Nutanix Volumes (block storage) .. fast, single-pod storage
│   └── Nutanix Files (NFS / RWX storage)  shared storage many pods can use at once
│
├── 🖼️  CONTAINER IMAGES & REGISTRY
│   ├── Harbor / private registry .. the "warehouse" storing every app's shipping container
│   ├── Skopeo ....................... fast tool for copying container images into the warehouse
│   └── Docker ........................ fallback tool for the same job, plus local image loading
│
├── 🧠 THE APPLICATION ITSELF
│   ├── nai-operators ................ the automation "robots" managing NAI's internals
│   └── nai-core ...................... the actual Nutanix Enterprise AI application
│
└── 🛠️  DEVELOPER-EXPERIENCE TOOLING
    └── gum ............................ makes the install script's terminal UI pretty/interactive
```

---

## Part 2: Every Component, Explained From Zero

### Helm — the app store for Kubernetes

**What it is:** Helm is a tool that installs, upgrades, and removes entire applications on Kubernetes as single, versioned units called **charts**.

**The analogy:** Without Helm, installing an application on Kubernetes is like assembling IKEA furniture from 40 loose bags of screws, with no instructions, where you have to remember exactly which screw goes where and in what order — every single time you install, upgrade, or remove it. Helm is the flat-pack box with a barcode: you scan it (`helm install`), it builds the whole thing correctly, and if you want to return it or swap the couch cushions for a newer model, `helm upgrade` and `helm uninstall` handle that cleanly too.

**Why it's included / how it relates to everything else:** Nearly every other component in this platform — KServe, OpenTelemetry, the gateway, NAI itself — is packaged as a Helm chart. Helm is the delivery mechanism for almost the entire stack. It's the plumbing that makes all the other components installable in a repeatable, undoable way.

**What breaks without it:** You'd have to hand-write and hand-apply dozens of raw Kubernetes configuration files for every component, get the order exactly right, and manually track what version of what is installed where. One typo and you have a half-installed, broken cluster with no easy way to roll back.

**Where it installs in the script:** Helm itself gets installed as a prerequisite around lines 197–210 (downloaded via the official `get-helm-3` script if online, or extracted from a prerequisites bundle if air-gapped). After that, the custom `deploy_chart()` function (defined lines 24–45) wraps `helm upgrade --install ... --wait --timeout 15m` and is reused to install almost everything else in the script — OpenTelemetry, KServe, the gateway, `nai-operators`, and `nai-core` all go through this one function.

---

### Kubernetes / NKP — the foundation everything runs on

**What it is:** Kubernetes is software that manages a group of computers as one pool of resources, automatically placing programs on them and restarting anything that fails. NKP is Nutanix's pre-built, supported distribution of Kubernetes.

**The analogy:** Picture an air traffic control system for a busy airport, except instead of planes it's managing hundreds of small programs, deciding which physical machine each one lands on, rerouting them if a runway (server) goes down, and doing it all without human intervention.

**Why it's included:** It's not really "included" — it's the ground everything else stands on. KServe, the gateway, OpenTelemetry, NAI itself: none of them can exist without a Kubernetes cluster to run inside.

**What breaks without it:** Nothing else in this list works at all. There's no "AI platform" without something to schedule and run the containers that make it up.

**Where it installs in the script:** Step 4 (lines 484–542) either provisions a brand-new NKP cluster via `nkp create cluster nutanix ...` (with all the Nutanix infrastructure details — Prism Element cluster, subnet, storage container, control-plane VIP, MetalLB range) or, if you chose "Use an EXISTING cluster," simply points the script at an existing cluster's kubeconfig file (line 301).

---

### cert-manager — the automatic locksmith

**What it is:** cert-manager is a Kubernetes add-on that automatically creates, renews, and manages the digital certificates that power HTTPS (the padlock icon in a browser).

**The analogy:** Every secure website needs a certificate — like a notarized ID card that proves "yes, this really is who it claims to be" and enables encrypted communication. Getting and renewing these by hand for dozens of internal services would be like manually renewing the ID card for every employee in a company, every few months, forever. cert-manager is the automated ID office that does this continuously in the background.

**Why it's included:** The NAI gateway and its endpoints need HTTPS. cert-manager supplies the certificate machinery that the gateway (`gateway.certManager.selfSigned=true`, line 791) relies on.

**What breaks without it:** No valid certificates means either broken HTTPS connections or manually-managed certificates that silently expire and take down access to the platform.

**Where it installs in the script:** This one is handled defensively rather than freshly installed — lines 600–652 check if you're on the "NKP Starter" license tier (which may be missing cert-manager's CRDs — see the CRD explanation below) and, if so, seed the required `Certificate` and `Issuer` CRDs either from the internet (`kubectl apply -f https://github.com/cert-manager/cert-manager/releases/...`, line 604) or from an embedded YAML block (lines 607–649) for air-gapped installs.

---

### CRDs — a quick detour, because you'll see this term everywhere

**What it is:** A **Custom Resource Definition (CRD)** is how you teach Kubernetes a brand-new vocabulary word. Out of the box, Kubernetes understands nouns like "Pod" and "Service." A CRD lets an application add its own noun — like "Certificate" or "InferenceService" — so Kubernetes can manage that concept too.

**The analogy:** Kubernetes ships with a basic dictionary. A CRD is like submitting a new word to that dictionary — after cert-manager registers "Certificate" as a word Kubernetes understands, you can write a request that says "create me a Certificate," and Kubernetes knows exactly what that means and how to handle it.

**Why it matters here:** KServe, the gateway, and cert-manager all extend Kubernetes' vocabulary via CRDs *before* their actual application logic is installed — you have to teach the dictionary the word before anyone can use it in a sentence.

**Where it shows up in the script:** The custom `deploy_crd_chart_directly()` function (lines 47–60) applies CRDs straight via `kubectl apply --server-side` rather than through Helm, because Helm has a 1MB size limit that large CRD bundles can exceed. It's used for `gateway-crds` (line 663) and `kserve-crd` (line 666).

---

### Gateway API + Envoy Gateway — the traffic cop

**What it is:** The Gateway API is a standardized *rulebook* (a set of CRDs) for how traffic should be routed into a Kubernetes cluster. Envoy Gateway is the actual *traffic cop* — a real running program that reads those rules and enforces them, deciding which incoming web request goes to which service.

**The analogy:** Think of a large office building with many companies inside. The Gateway API is the building's directory and routing policy ("requests for Company A go to floor 3, requests for Company B go to floor 7"). Envoy Gateway is the actual front-desk security guard reading that directory and physically pointing each visitor to the right elevator.

**Why it's included:** NAI exposes multiple services (chat interfaces, admin panels, model endpoints) that all need to be reachable from one external address without colliding. This is also why the script explicitly evicts a conflicting `traefik` gateway class at line 554 — you can only have one traffic cop on duty.

**What breaks without it:** External requests to NAI's various endpoints wouldn't know where to go — you'd get connection failures or the "404 No matching route found" error the script's own comments mention (line 797), which is exactly the bug the script patches around lines 793–809 by explicitly allowing routes from all namespaces.

**Where it installs in the script:** CRDs first (`gateway-crds`, line 663), then the real controller via `deploy_chart "opentelemetry-operator"`... wait — specifically the gateway controller is deployed at lines 676–764, either through a manual `helm upgrade --install "gateway-helm"` with a hand-patched `EnvoyGateway` ConfigMap for older NAI versions (2.7.x and below, lines 679–754), or through the standard `deploy_chart "gateway-helm"` helper for 2.8+ (lines 759–762).

---

### MetalLB range — handing out real addresses

**What it is:** In a data center (unlike the cloud), there's no automatic service that assigns a public IP address to something you want to expose. A load-balancer IP range is a pool of real network addresses set aside so Kubernetes services can hand one out and become reachable from the rest of the network.

**The analogy:** Kubernetes services normally live in a private internal "phone extension" system, not reachable from outside. A load-balancer IP pool is like reserving a block of real, dialable phone numbers so specific extensions can be reached directly from outside the building.

**Why it's included:** Without an external IP, nothing running in the cluster — including NAI's gateway — could be reached from a browser or another machine on the network.

**What breaks without it:** The gateway would only be reachable from inside the cluster; nobody on the corporate network could ever load the NAI web interface.

**Where it installs in the script:** Collected as user input at line 357 (`NAI_METALLB_RANGE`) and fed into the `nkp create cluster` command as `--kubernetes-service-load-balancer-ip-range` (line 497) when provisioning a new cluster.

---

### OpenTelemetry — the platform's nervous system

**What it is:** OpenTelemetry is an open standard and toolset for collecting three kinds of signals from running software: **logs** (a diary of events), **metrics** (numeric measurements over time, like CPU usage), and **traces** (a record of a single request's journey through multiple services).

**The analogy:** Imagine a hospital patient hooked up to monitors: one tracks heart rate, one tracks oxygen, one records everything the doctors did during a procedure. Without those monitors, doctors are just guessing when something goes wrong. OpenTelemetry is that set of monitors, but for software — it lets engineers see "the request slowed down here" or "this service's memory usage is spiking" instead of guessing blind.

**Why it's included:** Modern AI platforms are made of many small, cooperating services (the gateway, model servers, operators). When something breaks or slows down, you need visibility into *which* piece is misbehaving — OpenTelemetry is what makes that possible instead of digging through a dozen sets of raw log files by hand.

**What breaks without it:** Diagnosing performance problems or failures becomes guesswork. The script's own header comment even references a "Sledgehammer Telemetry Fix" (line 6), which tells you the team has already hit real problems in this exact area.

**Where it installs in the script:** The `opentelemetry-operator` Helm chart is deployed at line 669: `deploy_chart "opentelemetry-operator" "$OTEL_DIR"`.

---

### Prometheus (monitors, rules) — the alarm system

**What it is:** Prometheus is a monitoring system that regularly checks numeric health signals (like CPU, memory, request counts) and can fire alerts when something crosses a threshold. `PodMonitor`, `ServiceMonitor`, and `PrometheusRule` are CRDs (remember those?) that tell Prometheus *what* to watch and *when* to alert.

**The analogy:** If OpenTelemetry is the hospital monitor collecting readings, Prometheus is the nurse's station that watches those readings continuously and sounds an alarm if a patient's heart rate crosses a dangerous line.

**Why it's included / relation to other components:** It consumes signals that OpenTelemetry and the applications themselves expose, turning raw numbers into "something is wrong, alert a human."

**What breaks without it:** No proactive alerting — problems are only discovered when a user notices something is broken, not when the metrics first show trouble.

**Where it installs in the script:** This one is conditional and slightly inverted — lines 774–784 check if you're on the "NKP Starter" license (which doesn't ship a full Prometheus stack). If so, the script *deletes* any hardcoded monitor YAML files bundled with NAI Core (`find "${NAI_CORE_DIR}" -type f -name "*monitor*.yaml" -delete`, line 777) so the install doesn't fail trying to use CRDs that don't exist, and for internet installs, it fetches just the bare `podmonitors`, `servicemonitors`, and `prometheusrules` CRD definitions directly from the Prometheus Operator's GitHub releases (line 781) so those objects can at least be created even without the full monitoring stack running.

---

### KServe — the model-serving engine

**What it is:** KServe is a Kubernetes add-on purpose-built for running machine learning models and exposing them as standardized web endpoints that other software can send requests to.

**The analogy:** Training a model is like a chef perfecting a recipe in a test kitchen. That's not the same as running a restaurant that can take orders from hundreds of customers simultaneously, scale up on a busy Friday night, and rest (scale to zero) when no one's ordering. KServe is the restaurant infrastructure — the ordering system, the kitchen line, the staffing that scales up and down — built specifically around serving trained models instead of home-cooked recipes.

**Why it's included:** This is the actual point of the platform. All the networking, storage, and observability exist to support reliably serving AI models — KServe is the component that does that serving.

**What breaks without it:** You'd have working infrastructure with nothing to actually run or expose your AI models through — like building the restaurant with no kitchen.

**Where it installs in the script:** CRDs are applied directly at line 666 (`deploy_crd_chart_directly "kserve-crd" "$KSERVE_CRD_DIR"`), then the controller itself is installed at lines 671–673 via `deploy_chart "kserve" "$KSERVE_DIR" --set "kserve.controller.deploymentMode=RawDeployment"` — that last flag tells KServe to run models as plain Kubernetes deployments rather than through a separate serverless layer, which is a simpler, more predictable mode.

---

### Storage: CSI driver, StorageClass, Nutanix Files/Volumes

**What it is:** A **StorageClass** is a Kubernetes "menu item" describing a type of storage that can be requested on demand. The **CSI (Container Storage Interface) driver** is the translator that turns a Kubernetes storage request into an actual command against real Nutanix disks. **Nutanix Volumes** provide block storage (fast, one-user-at-a-time — like a personal hard drive), while **Nutanix Files** provides NFS/RWX storage (shared, many-users-at-once — like a shared network drive).

**The analogy:** A StorageClass is like ordering "a filing cabinet" from a catalog without knowing the warehouse logistics. The CSI driver is the warehouse worker who actually goes and finds or builds that filing cabinet from the physical storage the company owns. Block storage (Volumes) is a personal filing cabinet only one desk can use; file storage (Files) is a shared filing room the whole office can open simultaneously.

**Why it's included:** AI models and their supporting services need to persistently store things — model weights, chat history, configuration — even if the pod running them restarts. Shared storage (Files) matters specifically because *multiple* pods often need to read the same data at once (e.g., several model-serving replicas sharing one model file).

**What breaks without it:** Any pod that restarts loses all its data, and no two pods could share a common set of files — model replicas couldn't share the same downloaded model weights, for instance.

**Where it installs in the script:** Nutanix Files connection details are gathered at lines 332–347 (file server name, REST API credentials). A Kubernetes `Secret` bundling both Nutanix Prism and Files credentials is created at lines 561–563, and the actual `StorageClass` named `nai-nfs-storage` — pointing at the `csi.nutanix.com` provisioner with `storageType: NutanixFiles` — is applied at lines 565–584. It's referenced later by `nai-core`'s Helm values at line 790 (`global.storage.storageClassNameRWX=nai-nfs-storage`), alongside block storage at line 789 (`global.storage.storageClassName=nutanix-volume`).

---

### Container registry (Harbor-style), Skopeo, Docker — the image warehouse

**What it is:** A **container image** is a complete, self-contained snapshot of an application and everything it needs to run — like a shipping container packed with everything a factory needs, rather than loose parts. A **registry** (your notes mention Harbor specifically) is the warehouse that stores these shipping containers so Kubernetes can pull them when it needs to start a program. **Skopeo** and **Docker** are two different tools for physically moving container images into that warehouse.

**The analogy:** If Kubernetes is the apartment building, container images are the fully-furnished, pre-built rooms delivered by truck, and the registry is the loading dock and warehouse where those rooms are stored until they're needed. Skopeo is a specialized, lightweight forklift built just for moving these containers efficiently; Docker is the general-purpose truck that can do the same job but less efficiently, and needs a large staging area (your local disk) to unload everything first.

**Why it's included:** In an **air-gapped** environment (no internet access, as your memory notes correctly describe — both "modes" in this script are hybrid air-gapped, with only prerequisite tooling touching the internet), Kubernetes can't just reach out to the public internet to fetch images the way it normally would. Every image the platform needs must be pre-loaded into a private, internally-reachable registry first.

**What breaks without it:** Every single pod would fail to start, stuck in an "ImagePullBackOff" state, because Kubernetes would have nowhere to fetch its container images from.

**Where it installs in the script:** Registry connection details are gathered at lines 361–369. The whole of Step 3 (lines 398–482) handles getting images into that registry: it checks whether images already exist in the mirror (line 409), and if not, tries a fast "Direct-Seek" method that reads image names straight out of the tar bundle without fully unpacking it (line 420), then pushes each one via `skopeo copy` (line 472) — falling back to `docker load` plus `docker push` (lines 448–476) if Skopeo isn't available, with an explicit warning about needing 70GB of free disk space for that slower path (lines 436–445).

---

### nai-operators and nai-core — the application itself

**What it is:** `nai-operators` installs the automated "robot managers" that handle NAI's internal lifecycle tasks. `nai-core` installs the actual Nutanix Enterprise AI application — the piece end users interact with.

**The analogy:** If everything above is the city's infrastructure (roads, power, water, mail delivery), `nai-operators` and `nai-core` are the actual business that opens its doors inside that city and starts serving customers.

**Why it's included:** This is the reason the whole script exists — everything else is scaffolding built specifically to support these two installs succeeding.

**What breaks without it:** Nothing — this *is* NAI. Every other component in this document exists purely to make this step possible.

**Where it installs in the script:** `nai-operators` is deployed at lines 767–768, followed by a 10-second pause (line 770) to let it settle. `nai-core` is deployed at lines 786–791 with specific values wiring it up to everything built earlier: the access domain (`global.domain`), the block and file storage classes discussed above, and self-signed certificate generation via cert-manager.

---

### gum — the terminal's user interface

**What it is:** `gum` is a small command-line tool for building interactive, good-looking terminal prompts — colored boxes, selection menus, spinners, and confirmation dialogs — instead of plain, ugly text prompts.

**The analogy:** It's the difference between filling out a form on a well-designed website with clear buttons and dropdowns, versus filling out the same form by typing raw text into a blank box with no formatting or guidance.

**Why it's included:** It's not part of the *platform* NAI runs on at all — it never touches Kubernetes. It exists purely to make running the installer itself pleasant and less error-prone (e.g., `gum choose` for menus, `gum confirm` for yes/no prompts, `gum style` for colored boxes).

**What breaks without it:** Nothing about NAI itself breaks — but the script would refuse to even start, since line 65 hard-checks for `gum` and exits immediately if it's missing.

**Where it installs in the script:** It isn't installed by this script at all — it's a required pre-existing dependency, checked (not installed) at lines 65–68, alongside `kubectl`, `nkp`, `tar`, `curl`, and `docker` at lines 72–82.

---

## Part 3: How It All Connects, In One Sentence Each

- **NKP** builds the Kubernetes cluster everything else lives in.
- **Helm** is how almost every other component gets installed onto that cluster.
- **cert-manager** and the **Gateway API / Envoy Gateway** work together so traffic can reach NAI securely.
- **MetalLB** gives that gateway a real, reachable network address.
- **The registry (Harbor) + Skopeo/Docker** make sure every container image NAI needs is available locally, since the environment is air-gapped.
- **The CSI driver + StorageClasses (Volumes/Files)** give NAI's pods somewhere persistent and, where needed, shared to store data.
- **OpenTelemetry + Prometheus** let engineers see what's happening and get alerted when it isn't.
- **KServe** is the engine that actually runs and serves the AI models.
- **nai-operators + nai-core** are NAI itself, sitting on top of all of the above.

If you're writing this up for the READMEs, this "why it's here" framing (rather than just "here's what we install") is probably the most useful bridge for a reader who knows infrastructure in general but hasn't seen this specific stack before.
