#!/usr/bin/env bash
# =============================================================================
# setup-azure.sh
# Configura AKS + ACR + ArgoCD para el Parcial I – Patrones Arquitectónicos
# =============================================================================
set -euo pipefail

# ── VARIABLES ─────────────────────────────────────────────────────────────────
RESOURCE_GROUP="rg-pedido-app"
LOCATION="eastus"
ACR_NAME="andresazcona"
AKS_NAME="aks-pedido-app"
AKS_NODE_COUNT=2
AKS_NODE_SIZE="Standard_B2s"
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="v2.10.0"

GITHUB_REPO="https://github.com/andresazcona/Parcial_1_Patrones.git"

echo "======================================================"
echo " Setup Azure – Pedido App"
echo "======================================================"

# ── 1. RESOURCE GROUP ─────────────────────────────────────────────────────────
echo "[1/9] Creando Resource Group: $RESOURCE_GROUP en $LOCATION..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output table

# ── 2. AZURE CONTAINER REGISTRY ───────────────────────────────────────────────
echo "[2/9] Creando ACR: $ACR_NAME..."
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled false \
  --output table

echo "  Login al ACR..."
az acr login --name "$ACR_NAME"

# ── 3. PUSH IMAGES ────────────────────────────────────────────────────────────
echo "[3/9] Cargando y publicando imágenes al ACR..."
bash "$(dirname "$0")/push-images.sh" "$ACR_NAME"

# ── 4. AKS CLUSTER ────────────────────────────────────────────────────────────
echo "[4/9] Creando AKS cluster: $AKS_NAME (puede tardar 5-10 min)..."
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_NAME" \
  --node-count "$AKS_NODE_COUNT" \
  --node-vm-size "$AKS_NODE_SIZE" \
  --enable-managed-identity \
  --generate-ssh-keys \
  --output table

# ── 5. ATTACH ACR A AKS (sin pull secret) ────────────────────────────────────
echo "[5/9] Vinculando ACR al AKS (pull sin credenciales)..."
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_NAME" \
  --attach-acr "$ACR_NAME" \
  --output table

# ── 6. KUBECONFIG ─────────────────────────────────────────────────────────────
echo "[6/9] Obteniendo credenciales del clúster..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_NAME" \
  --overwrite-existing

kubectl get nodes

# ── 7. INGRESS NGINX + METRICS SERVER ─────────────────────────────────────────
echo "[7/9] Instalando ingress-nginx y metrics-server..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --wait

helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args[0]="--kubelet-insecure-tls" \
  --wait

# Obtener IP pública del Ingress
echo "  Esperando IP pública del Load Balancer..."
INGRESS_IP=""
while [ -z "$INGRESS_IP" ]; do
  INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -z "$INGRESS_IP" ] && echo "  Aún esperando..." && sleep 10
done
echo "  Ingress IP: $INGRESS_IP"

# ── 8. ARGOCD ─────────────────────────────────────────────────────────────────
echo "[8/9] Instalando ArgoCD $ARGOCD_VERSION..."
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$ARGOCD_NAMESPACE" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"

echo "  Esperando que ArgoCD esté listo..."
kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=300s

# Obtener contraseña inicial de ArgoCD
ARGOCD_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "  ┌──────────────────────────────────────────────────┐"
echo "  │  ArgoCD admin password: $ARGOCD_PASSWORD"
echo "  └──────────────────────────────────────────────────┘"
echo "  (Guarda esta contraseña, se usa en el paso 9)"

# Exponer ArgoCD via LoadBalancer (o usa port-forward para acceso temporal)
kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" \
  -p '{"spec":{"type":"LoadBalancer"}}'
sleep 20
ARGOCD_IP=$(kubectl get svc argocd-server -n "$ARGOCD_NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pendiente")

# Login ArgoCD CLI
argocd login "$ARGOCD_IP" \
  --username admin \
  --password "$ARGOCD_PASSWORD" \
  --insecure || echo "  (Usa port-forward si el IP aún no está disponible)"

# Registrar repositorio privado de GitHub
echo ""
echo "  Registrando repositorio privado en ArgoCD..."
echo "  (Necesitarás un GitHub Personal Access Token con permisos 'repo')"
read -rsp "  GitHub Token: " GH_TOKEN
echo ""

argocd repo add "$GITHUB_REPO" \
  --username andresazcona \
  --password "$GH_TOKEN"

# ── 9. APLICAR APPS ARGOCD ────────────────────────────────────────────────────
echo "[9/9] Aplicando definiciones de ArgoCD..."
kubectl apply -f environments/dev/application.yaml
kubectl apply -f environments/prod/application.yaml

echo ""
echo "======================================================"
echo " ✓ Setup completado"
echo "======================================================"
echo ""
echo "  Ingress IP:   $INGRESS_IP"
echo "  ArgoCD UI:    https://$ARGOCD_IP"
echo "  ACR:          $ACR_NAME.azurecr.io"
echo ""
echo "  Agrega en tu /etc/hosts (o DNS de Azure) las entradas:"
echo "    $INGRESS_IP  pedido-dev.eastus.cloudapp.azure.com"
echo "    $INGRESS_IP  pedido-prod.eastus.cloudapp.azure.com"
echo ""
echo "  Credenciales de BD: pasa --set db.auth.password=<TU_PASSWORD>"
echo "  al hacer helm install/upgrade (ver README)."
