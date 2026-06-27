# RHCL Reference

Reference manifests and examples for teams implementing [Red Hat Connectivity Link (RHCL)](https://www.redhat.com/en/technologies/cloud-computing/openshift/connectivity-link) on OpenShift.

This repository is meant to be shared with interested parties and customers who need practical starting points for RHCL features. Copy the YAML manifests that match your use case, adapt them to your environment, and integrate them into your own GitOps workflow.

> **This is a reference implementation, not a production-ready deployment.** Review, harden, and tailor every manifest before using it in production.

## What is included

The chart deploys a complete RHCL lab environment on OpenShift, covering:

| Area | What it demonstrates |
|------|----------------------|
| **MetalLB** | LoadBalancer IP assignment for the Gateway on bare-metal / disconnected clusters |
| **Istio Service Mesh** | Sail Operator–managed Istio with an external authorization extension provider |
| **Gateway API** | Istio-backed `Gateway` with wildcard hostname routing |
| **RHCL / Kuadrant** | RHCL operator subscription and `Kuadrant` CR with observability enabled |
| **Rate limiting** | `RateLimitPolicy` attached to an `HTTPRoute` |
| **External authorization** | Istio `AuthorizationPolicy` with a custom request interceptor |
| **External backends** | `ServiceEntry`, `DestinationRule`, and `HTTPRoute` with URL rewrite to an external host |
| **Observability** | OpenShift user-workload monitoring, Kuadrant observability stack, Grafana dashboards, and Kiali |
| **Troubleshooting** | `netshoot` pod for network debugging inside the cluster |

## Repository structure

```
.
├── deploy.sh                          # Bootstrap script (OpenShift GitOps + Argo CD Application)
└── chart/
    ├── Chart.yaml
    ├── values.yaml                    # Cluster-specific parameters
    └── templates/
        ├── 1-metallb/                 # MetalLB operator, IP pool, L2 advertisement
        ├── 2-istio/                 # Istio, CNI, Kiali, OSSM Console
        ├── 3-gateway-api/             # Gateway API resources (Istio + optional OpenShift default)
        ├── 4-rhcl/                    # RHCL operator and Kuadrant CR
        ├── 7-monitoring/              # OpenShift monitoring, Grafana, RHCL dashboards
        ├── 8-example-apps/            # Sample applications and policies
        └── 99-tshoot-tools/           # netshoot troubleshooting pod
```

Templates are ordered by Argo CD sync waves (directory prefix numbers) so dependencies are applied in the correct sequence.

## Prerequisites

- OpenShift 4.x cluster with cluster-admin access
- OpenShift GitOps (Argo CD) — installed automatically by `deploy.sh`, or pre-installed in your environment
- Sufficient resources to run Istio, MetalLB, RHCL, and the example applications
- A free IP range on the cluster machine network (for MetalLB), if you expose the Gateway via LoadBalancer
- Network access to pull container images and, for some examples, to reach external hosts (e.g. `httpbin.org`)

## Configuration

Edit `chart/values.yaml` before deploying, or override values at install time:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `baseDns` | Base DNS suffix for example application hostnames | `rhcl.ocp.acme.com` |
| `rhclVersion` | RHCL / Kuadrant operator version used for observability manifests | `1.4.0` |
| `metallb.ipAddressPool.addresses` | IP range MetalLB can assign to LoadBalancer services | `192.168.1.240-192.168.1.250` |

Example hostnames generated from `baseDns`:

- `hello-world-app.<baseDns>`
- `external-app.<baseDns>`

## Deployment

### Option 1 — Automated bootstrap (recommended for lab environments)

The `deploy.sh` script:

1. Installs the OpenShift GitOps operator and waits for Argo CD to become available
2. Derives `baseDns` from the cluster ingress domain (`apps.<domain>` → `rhcl.<domain>`)
3. Detects a free IP block on the machine network for MetalLB
4. Creates an Argo CD `Application` that syncs this Helm chart

```bash
./deploy.sh
```

Monitor progress in the Argo CD UI (OpenShift GitOps) or with:

```bash
oc get applications -n openshift-gitops
oc get kuadrant -n kuadrant-system
```

### Option 2 — Helm (manual)

```bash
helm template rhcl-reference ./chart \
  --set baseDns=rhcl.ocp.example.com \
  --set metallb.ipAddressPool.addresses[0]=192.168.1.240-192.168.1.250 \
  | oc apply -f -
```

### Option 3 — Copy individual manifests

Browse `chart/templates/` and copy only the files relevant to your scenario. Remove Argo CD annotations (`argocd.argoproj.io/*`) if you are not using GitOps, and replace Helm templating (`{{ .Values.baseDns }}`, etc.) with your own values.

## Example applications

### Hello World (`8-example-apps/1-hello-world-app/`)

A minimal backend exposed through Gateway API, with a `RateLimitPolicy` (5,000 requests per 10 seconds).

**Key resources:** `Deployment`, `Service`, `HTTPRoute`, `RateLimitPolicy`

### External authorization (`hello-world-ext-authz.yaml` + request interceptor)

Demonstrates Istio external authorization via a custom extension provider:

1. The Istio mesh is configured with a `request-interceptor-provider` pointing to the interceptor service
2. An `AuthorizationPolicy` on the Gateway triggers the interceptor for `hello-world-app.<baseDns>`
3. The `request-interceptor-app` (built from [request-interceptor](https://github.com/dsferreira54/request-interceptor)) validates or transforms requests before they reach the backend

**Key resources:** Istio `meshConfig.extensionProviders`, `AuthorizationPolicy`, interceptor `Deployment`

### External backend (`8-example-apps/2-external-app/`)

Routes traffic to an external HTTPS host (`httpbin.org`) through the Gateway using `ServiceEntry`, `DestinationRule`, and an `HTTPRoute` with a URL rewrite filter.

**Key resources:** `ServiceEntry`, `DestinationRule`, `HTTPRoute` (with `URLRewrite`)

### Request interceptor app (`8-example-apps/3-request-interceptor-app/`)

OpenShift `BuildConfig` that builds the interceptor image from Git and deploys it into the `example-apps` namespace.

## Gateway API options

Two Gateway configurations are provided under `3-gateway-api/`:

| File | Controller | Status |
|------|------------|--------|
| `istio-gateway-api.yaml` | Istio (`gatewayClassName: istio`) | **Active** — used by the example apps |
| `standalone-gateway-api.yaml` | OpenShift default Gateway (`openshift.io/gateway-controller/v1`) | Commented out — enable if you prefer the platform Gateway |

Only one Gateway configuration should be active at a time.

## Observability

The monitoring stack includes:

- **User-workload monitoring** enabled on the cluster (`enableUserWorkload: true`)
- **Kuadrant observability** deployed via a nested Argo CD Application (kube-state-metrics, telemetry, etc.)
- **Grafana** with pre-configured RHCL dashboards (App Developer, Business User, Platform Engineer, DNS Operator)
- **Kiali** and the OSSM Console for service mesh visibility

Grafana admin credentials are defined in `7-monitoring/2-grafana.yaml` for lab use only. Change them before any shared or long-lived deployment.

## Troubleshooting

A privileged `netshoot` pod is deployed in the `troubleshooting` namespace for in-cluster network diagnostics (DNS, connectivity, packet capture).

Example — test the hello-world app through the Gateway LoadBalancer IP:

```bash
GATEWAY_IP=$(oc get svc -n istio-ingress -l istio.io/gateway-name=main-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

curl -H "Host: hello-world-app.<baseDns>" "http://${GATEWAY_IP}/"
```

Replace `<baseDns>` with your configured value.

## Adapting for your environment

When copying manifests into your own repository, review at minimum:

1. **DNS and hostnames** — replace `baseDns` and any hardcoded domains
2. **IP addressing** — adjust MetalLB pools to match your network
3. **Namespaces** — align with your naming conventions and RBAC model
4. **Operator channels and versions** — match your supported RHCL, Istio, and OpenShift versions
5. **Secrets and credentials** — never reuse lab passwords or tokens
6. **Sync waves / ordering** — preserve dependency order if applying without Argo CD
7. **External dependencies** — remove or replace references to external services you cannot reach

## Sync wave overview

| Wave | Components |
|------|------------|
| 0–4 | MetalLB |
| 5–10 | Istio, CNI, Kiali, OSSM Console |
| 11–12 | Gateway API |
| 13–14 | RHCL operator, Kuadrant |
| 15–21 | Monitoring and Grafana |
| 22–27 | Example apps (hello-world, external-app) |
| 28–31 | Request interceptor and external authz |
| 32–34 | Troubleshooting tools |

## License and disclaimer

These manifests are provided as-is for educational and reference purposes. They are not officially supported by Red Hat. Validate all configurations against your organization's security, networking, and operational requirements before deploying to production.

For official RHCL documentation, see the [Red Hat Connectivity Link product page](https://www.redhat.com/en/technologies/cloud-computing/openshift/connectivity-link) and [Red Hat documentation](https://docs.redhat.com/).
