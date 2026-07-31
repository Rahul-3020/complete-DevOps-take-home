#!/usr/bin/env bash
# One-command setup for the DevOps take-home demo service (Parts 1-3).
#
# Idempotent: safe to run repeatedly. Creates (or reuses) a kind cluster
# named "demo", installs ingress-nginx, builds the service image, loads it
# into the cluster, and installs the Helm chart as release "demo" in
# namespace "demo".

set -euo pipefail

CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE="demo"
IMAGE_NAME="demo-service"
IMAGE_TAG="1.0.0"
INGRESS_NGINX_VERSION="controller-v1.11.2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log() { echo "==> $*"; }

# --- 1. kind cluster ---------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists, reusing it"
else
  log "creating kind cluster '$CLUSTER_NAME'"
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# --- 2. ingress-nginx ---------------------------------------------------------
# Using the kind-specific manifest from the upstream project, which wires
# the controller to the hostPort mapping created above. Re-applying is safe.
if kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
  log "ingress-nginx already installed, skipping"
else
  log "installing ingress-nginx (kind flavour, ${INGRESS_NGINX_VERSION})"
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
fi

log "waiting for ingress-nginx controller to be ready (this can take a minute)"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s || {
    log "ingress-nginx did not report ready in time; continuing, check 'kubectl -n ingress-nginx get pods'"
  }

# --- 3. build + load the image -----------------------------------------------
log "building image ${IMAGE_NAME}:${IMAGE_TAG}"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" ./service

log "loading image into kind cluster '${CLUSTER_NAME}'"
kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name "$CLUSTER_NAME"

# --- 4. install the chart -----------------------------------------------------
log "installing chart as release '${RELEASE}' in namespace '${NAMESPACE}'"
helm upgrade --install "$RELEASE" ./chart \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set image.repository="${IMAGE_NAME}" \
  --set image.tag="${IMAGE_TAG}" \
  --wait --timeout 120s

log "done."
echo ""
echo "Verify with:"
echo "  kubectl -n ${NAMESPACE} get pods"
echo "  kubectl -n ${NAMESPACE} port-forward svc/${RELEASE} 8080:80 &"
echo "  curl http://localhost:8080/"
echo "  curl --resolve demo.local:80:127.0.0.1 http://demo.local/"
