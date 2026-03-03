#!/usr/bin/env bash
# =============================================================================
# push-images.sh
# Carga las imágenes Docker desde los .tar y las publica en el ACR de Azure.
# Uso: bash push-images.sh <ACR_NAME>
# =============================================================================
set -euo pipefail

ACR_NAME="${1:-andresazcona}"
ACR_HOST="${ACR_NAME}.azurecr.io"
IMAGES_DIR="$(dirname "$0")/images"

# Tag que se usará en el registry
BACKEND_TAG="latest"
FRONTEND_TAG="latest"

echo "ACR: $ACR_HOST"
echo "Directorio de imágenes: $IMAGES_DIR"
echo ""

# ── Login ACR ─────────────────────────────────────────────────────────────────
echo "[1/4] Login al ACR..."
az acr login --name "$ACR_NAME"

# ── Cargar Backend ────────────────────────────────────────────────────────────
echo "[2/4] Cargando pedido-backend.tar..."
BACKEND_LOCAL_TAG=$(docker load -i "$IMAGES_DIR/pedido-backend.tar" \
  | grep "Loaded image" | awk '{print $NF}')
echo "  Imagen cargada: $BACKEND_LOCAL_TAG"

echo "  Tagging como $ACR_HOST/pedido-backend:$BACKEND_TAG..."
docker tag "$BACKEND_LOCAL_TAG" "$ACR_HOST/pedido-backend:$BACKEND_TAG"

echo "  Pushing..."
docker push "$ACR_HOST/pedido-backend:$BACKEND_TAG"

# ── Cargar Frontend ───────────────────────────────────────────────────────────
echo "[3/4] Cargando pedido-frontend.tar..."
FRONTEND_LOCAL_TAG=$(docker load -i "$IMAGES_DIR/pedido-frontend.tar" \
  | grep "Loaded image" | awk '{print $NF}')
echo "  Imagen cargada: $FRONTEND_LOCAL_TAG"

echo "  Tagging como $ACR_HOST/pedido-frontend:$FRONTEND_TAG..."
docker tag "$FRONTEND_LOCAL_TAG" "$ACR_HOST/pedido-frontend:$FRONTEND_TAG"

echo "  Pushing..."
docker push "$ACR_HOST/pedido-frontend:$FRONTEND_TAG"

# ── Verificar ─────────────────────────────────────────────────────────────────
echo "[4/4] Verificando imágenes en ACR..."
az acr repository list --name "$ACR_NAME" --output table

echo ""
echo "Imágenes disponibles:"
az acr repository show-tags --name "$ACR_NAME" \
  --repository pedido-backend --output table
az acr repository show-tags --name "$ACR_NAME" \
  --repository pedido-frontend --output table

echo ""
echo "Push completado exitosamente."
echo "  Backend:  $ACR_HOST/pedido-backend:$BACKEND_TAG"
echo "  Frontend: $ACR_HOST/pedido-frontend:$FRONTEND_TAG"
