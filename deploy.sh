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

INGRESS_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
RHCL_BASE_DNS="${INGRESS_DOMAIN/#apps./rhcl.}"

if [ -z "$RHCL_BASE_DNS" ]; then
  echo "Error: unable to retrieve the OpenShift base DNS."
  exit 1
fi

echo "RHCL base DNS set to: ${RHCL_BASE_DNS}"

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
    targetRevision: HEAD
    path: chart
    helm:
      parameters:
        - name: baseDns
          value: "${RHCL_BASE_DNS}"
  destination:
    server: https://kubernetes.default.svc
    namespace: rhcl-reference
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
