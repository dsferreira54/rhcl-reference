oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for ArgoCD openshift-gitops to become Available..."

until [ "$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null)" = "Available" ]; do
  sleep 10
done

echo "ArgoCD openshift-gitops is Available."

oc patch argocd openshift-gitops \
  -n openshift-gitops \
  --type merge \
  -p '{
    "spec": {
      "controller": {
        "appSync": "5s"
      },
      "extraConfig": {
        "timeout.reconciliation.jitter": "0s"
      }
    }
  }'

echo "Granting cluster-admin to the ArgoCD application controller service account..."

oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshift-gitops-argocd-application-controller-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: openshift-gitops-argocd-application-controller
  namespace: openshift-gitops
EOF

INGRESS_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
RHCL_BASE_DNS="${INGRESS_DOMAIN/#apps./rhcl.}"

if [ -z "$INGRESS_DOMAIN" ]; then
  echo "Error: unable to retrieve the OpenShift ingress domain."
  exit 1
fi

if [ -z "$RHCL_BASE_DNS" ]; then
  echo "Error: unable to retrieve the OpenShift base DNS."
  exit 1
fi

echo "OpenShift ingress domain set to: ${INGRESS_DOMAIN}"
echo "RHCL base DNS set to: ${RHCL_BASE_DNS}"

echo "Detecting available MetalLB IP address pool on the machine network..."

METALLB_IP_POOL="$(python3 <<'PY'
import ipaddress
import json
import re
import subprocess
import sys

POOL_SIZE = 1


def oc_json(args):
    return json.loads(subprocess.check_output(["oc"] + args + ["-o", "json"], text=True))


def add_used_ip(used, value):
    try:
        used.add(ipaddress.ip_address(value))
    except ValueError:
        pass


install_config = subprocess.check_output(
    [
        "oc",
        "get",
        "configmap",
        "cluster-config-v1",
        "-n",
        "kube-system",
        "-o",
        "jsonpath={.data.install-config}",
    ],
    text=True,
)
match = re.search(r"machineNetwork:\s*\n\s*-\s*cidr:\s*(\S+)", install_config)
if not match:
    sys.exit("machine network CIDR not found in install-config")

network = ipaddress.ip_network(match.group(1), strict=False)
used = {network.network_address, network.broadcast_address}

gateway = network.network_address + 1
if gateway in network:
    used.add(gateway)

for node in oc_json(["get", "nodes"])["items"]:
    for addr in node.get("status", {}).get("addresses", []):
        if addr["type"] in ("InternalIP", "ExternalIP"):
            add_used_ip(used, addr["address"])

for svc in oc_json(["get", "svc", "-A"])["items"]:
    for ingress in (svc.get("status", {}).get("loadBalancer", {}) or {}).get("ingress", []) or []:
        if ingress.get("ip"):
            add_used_ip(used, ingress["ip"])
    for external_ip in svc.get("spec", {}).get("externalIPs", []) or []:
        add_used_ip(used, external_ip)

try:
    pools = json.loads(
        subprocess.check_output(
            ["oc", "get", "ipaddresspool", "-A", "-o", "json"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    )
    for pool in pools.get("items", []):
        for address in pool.get("spec", {}).get("addresses", []) or []:
            if "-" in address:
                start, end = address.split("-", 1)
                start_ip = ipaddress.ip_address(start.strip())
                end_ip = ipaddress.ip_address(end.strip())
                current = int(start_ip)
                while current <= int(end_ip):
                    add_used_ip(used, current)
                    current += 1
            elif "/" in address:
                for ip in ipaddress.ip_network(address, strict=False):
                    add_used_ip(used, ip)
            else:
                add_used_ip(used, address)
except subprocess.CalledProcessError:
    pass

hosts = [ip for ip in network.hosts()]
used_in_network = {ip for ip in used if ip in network}

for index in range(len(hosts) - POOL_SIZE, -1, -1):
    block = hosts[index : index + POOL_SIZE]
    if all(ip not in used_in_network for ip in block):
        print(f"{block[0]}-{block[-1]}")
        sys.exit(0)

sys.exit(f"no contiguous block of {POOL_SIZE} free IPs found in {network}")
PY
)"

if [ -z "$METALLB_IP_POOL" ]; then
  echo "Error: unable to detect a free MetalLB IP address pool."
  exit 1
fi

echo "MetalLB IP address pool set to: ${METALLB_IP_POOL}"

oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhcl-reference
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/dsferreira54/rhcl-reference
    targetRevision: main
    path: chart
    helm:
      parameters:
        - name: baseDns
          value: "${RHCL_BASE_DNS}"
        - name: ingressDomain
          value: "${INGRESS_DOMAIN}"
        - name: metallb.ipAddressPool.addresses[0]
          value: "${METALLB_IP_POOL}"
  destination:
    server: https://kubernetes.default.svc
    namespace: rhcl-reference
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
EOF
