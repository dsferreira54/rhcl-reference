# RHCL Reference

Reference manifests and examples for teams implementing [Red Hat Connectivity Link (RHCL)](https://www.redhat.com/en/technologies/cloud-computing/openshift/connectivity-link) on OpenShift.

This repository is meant to be shared with interested parties and customers who need practical starting points for RHCL features. Copy the YAML manifests that match your use case, adapt them to your environment, and integrate them into your own GitOps workflow.

> **This is a reference implementation, not a production-ready deployment.** Review, harden, and tailor every manifest before using it in production.

## What is included

The chart deploys a complete RHCL lab environment on OpenShift, covering:

| Area | What it demonstrates |
|------|----------------------|
| **MetalLB** | LoadBalancer IP assignment for the Gateway on bare-metal / disconnected clusters |
| **Istio Service Mesh** | Sail Operator–managed Istio with an optional external authorization extension provider |
| **Gateway API** | Istio-backed `Gateway` with wildcard hostname routing |
| **RHCL / Kuadrant** | RHCL operator subscription, `Kuadrant` CR with observability, and OpenShift console plugin |
| **Rate limiting** | `RateLimitPolicy` attached to an `HTTPRoute` |
| **External authorization** | Istio `AuthorizationPolicy` with a custom request interceptor (configurable) |
| **Request mirroring** | Gateway API `RequestMirror` filter that copies traffic to the interceptor (configurable) |
| **External backends** | `ServiceEntry`, `DestinationRule`, and `HTTPRoute` with URL rewrite to an external host |
| **Observability** | OpenShift user-workload monitoring, Kuadrant observability stack, Grafana dashboards, and Kiali |
| **Troubleshooting** | `netshoot` pod for network debugging inside the cluster |

## Repository structure

```
.
├── deploy.sh                          # Bootstrap script (OpenShift GitOps + Argo CD Application)
└── chart/
    ├── Chart.yaml
    ├── values.yaml                    # Cluster-specific parameters and feature toggles
    └── templates/
        ├── 1-metallb/                 # MetalLB operator, IP pool, L2 advertisement
        ├── 2-istio/                   # Istio, CNI, Kiali, OSSM Console
        ├── 3-gateway-api/             # Gateway API resources (Istio + optional OpenShift default)
        ├── 4-rhcl/                    # RHCL operator, Kuadrant CR, console plugin enablement
        ├── 7-monitoring/              # OpenShift monitoring, Grafana, RHCL dashboards
        └── 8-example-apps/            # Sample applications, policies, and troubleshooting tools
            ├── 0-namespace.yaml
            ├── 1-hello-world-app/
            ├── 2-external-app/
            ├── 3-request-interceptor-app/
            └── 4-tshoot-tools/
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

| Parameter | Description | Default |
|-----------|-------------|---------|
| `baseDns` | Base DNS suffix for example application hostnames | `rhcl.ocp.acme.com` |
| `rhclVersion` | RHCL / Kuadrant operator version used for observability manifests | `1.4.0` |
| `metallb.ipAddressPool.addresses` | IP range MetalLB can assign to LoadBalancer services | `192.168.1.240-192.168.1.250` |
| `helloWorldApp.requestInterceptor.externalAuthorization.enabled` | Deploy Istio `AuthorizationPolicy` and configure the extension provider | `true` |
| `helloWorldApp.requestInterceptor.requestMirror.enabled` | Add a `RequestMirror` filter on the hello-world `HTTPRoute` | `true` |

Example hostnames generated from `baseDns`:

- `hello-world-app.<baseDns>`
- `external-app.<baseDns>`

Both request interceptor features depend on the `request-interceptor-app` deployment. Disable them independently if you only need one pattern, or set both to `false` to run hello-world without the interceptor.

## Deployment

### Option 1 — Automated bootstrap (recommended for lab environments)

The `deploy.sh` script:

1. Installs the OpenShift GitOps operator and waits for Argo CD to become available
2. Grants the Argo CD application controller service account cluster-admin (required for cluster-scoped resources)
3. Derives `baseDns` from the cluster ingress domain (`apps.<domain>` → `rhcl.<domain>`)
4. Detects a free IP on the machine network for MetalLB
5. Creates an Argo CD `Application` that syncs this Helm chart

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
  --set helloWorldApp.requestInterceptor.externalAuthorization.enabled=true \
  --set helloWorldApp.requestInterceptor.requestMirror.enabled=true \
  | oc apply -f -
```

### Option 3 — Copy individual manifests

Browse `chart/templates/` and copy only the files relevant to your scenario. Remove Argo CD annotations (`argocd.argoproj.io/*`) if you are not using GitOps, and replace Helm templating (`{{ .Values.baseDns }}`, `{{- if .Values.helloWorldApp... }}`, etc.) with your own values.

## Example applications

All example workloads run in the `example-apps` namespace.

### Hello World (`8-example-apps/1-hello-world-app/`)

A minimal backend exposed through Gateway API, with a `RateLimitPolicy` (5 requests per 10 seconds).

When the request interceptor features are enabled in `values.yaml`, the same manifest also deploys:

- A `RequestMirror` filter that sends a copy of each request to the interceptor service
- An Istio `AuthorizationPolicy` on the Gateway that delegates authorization to the interceptor

**Key resources:** `Deployment`, `Service`, `HTTPRoute`, `RateLimitPolicy`, optional `AuthorizationPolicy`

### Request interceptor app (`8-example-apps/3-request-interceptor-app/`)

OpenShift `BuildConfig` that builds the interceptor image from Git and deploys it into the `example-apps` namespace. The app is built from [request-interceptor](https://github.com/dsferreira54/request-interceptor).

It serves two roles depending on configuration:

1. **External authorization** — Istio calls the interceptor via the `request-interceptor-provider` extension provider before forwarding traffic to the backend
2. **Request mirroring** — the hello-world `HTTPRoute` mirrors a copy of each request to the interceptor for logging or inspection

The Istio mesh extension provider and Gateway `AuthorizationPolicy` are only rendered when `helloWorldApp.requestInterceptor.externalAuthorization.enabled` is `true`.

**Key resources:** `ImageStream`, `BuildConfig`, `Deployment`, `Service`

### External backend (`8-example-apps/2-external-app/`)

Routes traffic to an external HTTPS host (`httpbin.org`) through the Gateway using `ServiceEntry`, `DestinationRule`, and an `HTTPRoute` with a URL rewrite filter.

**Key resources:** `ServiceEntry`, `DestinationRule`, `HTTPRoute` (with `URLRewrite`)

### Troubleshooting tools (`8-example-apps/4-tshoot-tools/`)

A privileged `netshoot` pod in the `example-apps` namespace for in-cluster network diagnostics (DNS, connectivity, packet capture).

## Gateway API options

Two Gateway configurations are provided under `3-gateway-api/`:

| File | Controller | Status |
|------|------------|--------|
| `istio-gateway-api.yaml` | Istio (`gatewayClassName: istio`) | **Active** — used by the example apps |
| `envoy-gateway-api.yaml` | OpenShift default Gateway (`openshift.io/gateway-controller/v1`) | Excluded via `.helmignore` — uncomment and enable if you prefer the platform Gateway |

Only one Gateway configuration should be active at a time.

## Observability

The monitoring stack includes:

- **User-workload monitoring** enabled on the cluster (`enableUserWorkload: true`)
- **Kuadrant observability** deployed via a nested Argo CD Application (kube-state-metrics, telemetry, etc.)
- **Grafana** with pre-configured RHCL dashboards (App Developer, Business User, Platform Engineer, DNS Operator)
- **Kiali** and the OSSM Console for service mesh visibility
- **RHCL console plugin** enabled automatically via a PostSync Job that patches the cluster `Console` CR

Grafana admin credentials are defined in `7-monitoring/2-grafana.yaml` for lab use only. Change them before any shared or long-lived deployment.

## Troubleshooting

Test the hello-world app through the Gateway LoadBalancer IP:

```bash
GATEWAY_IP=$(oc get svc -n istio-ingress -l istio.io/gateway-name=main-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

curl -H "Host: hello-world-app.<baseDns>" "http://${GATEWAY_IP}/"
```

Replace `<baseDns>` with your configured value.

Open a shell in the netshoot pod:

```bash
oc exec -n example-apps -it netshoot-0 -- bash
```

## Adapting for your environment

When copying manifests into your own repository, review at minimum:

1. **DNS and hostnames** — replace `baseDns` and any hardcoded domains
2. **IP addressing** — adjust MetalLB pools to match your network
3. **Namespaces** — align with your naming conventions and RBAC model
4. **Operator channels and versions** — match your supported RHCL, Istio, and OpenShift versions
5. **Secrets and credentials** — never reuse lab passwords or tokens
6. **Feature toggles** — decide whether you need external authorization, request mirroring, or both
7. **Sync waves / ordering** — preserve dependency order if applying without Argo CD
8. **External dependencies** — remove or replace references to external services you cannot reach

## Sync wave overview

| Wave | Components |
|------|------------|
| 0–4 | MetalLB |
| 5–10 | Istio, CNI, Kiali, OSSM Console |
| 11–12 | Gateway API |
| 13–14 | RHCL operator, Kuadrant |
| 15 | OpenShift monitoring, Kuadrant observability, RHCL console plugin |
| 16–21 | Grafana and RHCL dashboards |
| 22–25 | Example apps namespace, hello-world app and rate limit |
| 26–27 | External backend (httpbin.org) |
| 28–30 | Request interceptor build and deployment |
| 31 | External authorization policy (when enabled) |
| 33–34 | netshoot troubleshooting pod |

## License and disclaimer

These manifests are provided as-is for educational and reference purposes. They are not officially supported by Red Hat. Validate all configurations against your organization's security, networking, and operational requirements before deploying to production.

For official RHCL documentation, see the [Red Hat Connectivity Link product page](https://www.redhat.com/en/technologies/cloud-computing/openshift/connectivity-link) and [Red Hat documentation](https://docs.redhat.com/).
