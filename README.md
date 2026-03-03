# Pedido-App – Helm Chart & ArgoCD GitOps

Sistema de gestión de pedidos desplegado con Helm y ArgoCD.

---

## Estructura del repositorio

```
.
├── charts/
│   └── pedido-app/
│       ├── Chart.yaml              # Chart principal + dependencia Bitnami PostgreSQL
│       ├── values.yaml             # Valores por defecto
│       ├── values-dev.yaml         # Overrides para desarrollo
│       ├── values-prod.yaml        # Overrides para producción
│       ├── templates/
│       │   ├── _helpers.tpl        # Helpers compartidos
│       │   ├── ingress.yaml        # Ingress único: /api/* → backend, / → frontend
│       │   └── db-secret.yaml      # Secret de credenciales de PostgreSQL
│       └── charts/
│           ├── backend/            # Subchart Spring Boot API
│           │   └── templates/
│           │       ├── configmap.yaml
│           │       ├── deployment.yaml
│           │       ├── hpa.yaml
│           │       └── service.yaml
│           └── frontend/           # Subchart React/Vue/Angular
│               └── templates/
│                   ├── deployment.yaml
│                   └── service.yaml
└── environments/
    ├── dev/
    │   └── application.yaml        # ArgoCD Application – pedido-app-dev
    └── prod/
        └── application.yaml        # ArgoCD Application – pedido-app-prod
```

---

## Pre-requisitos

| Herramienta | Versión mínima |
|-------------|---------------|
| Helm | 3.12+ |
| kubectl | 1.28+ |
| ArgoCD | 2.9+ |
| Ingress controller (nginx) | cualquiera |
| Metrics Server (para HPA) | 0.6+ |

---

## 1 – Instalación manual con Helm

### 1.1 – Agregar el repositorio de Bitnami y actualizar dependencias

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Descargar la dependencia postgresql en charts/pedido-app/charts/
helm dependency update charts/pedido-app
```

### 1.2 – Instalar en entorno **dev**

```bash
helm install pedido-app charts/pedido-app \
  --namespace pedido-dev \
  --create-namespace \
  -f charts/pedido-app/values.yaml \
  -f charts/pedido-app/values-dev.yaml \
  --set db.auth.password="<CONTRASEÑA_SEGURA>"
```

> **Nunca** pases credenciales reales en flags de CI/CD visibles.
> Usa un secreto externo o Sealed Secrets (ver sección de seguridad).

### 1.3 – Instalar en entorno **prod**

```bash
helm install pedido-app charts/pedido-app \
  --namespace pedido-prod \
  --create-namespace \
  -f charts/pedido-app/values.yaml \
  -f charts/pedido-app/values-prod.yaml \
  --set db.auth.password="<CONTRASEÑA_PROD_SEGURA>"
```

### 1.4 – Actualizar un release existente

```bash
helm upgrade pedido-app charts/pedido-app \
  --namespace pedido-dev \
  -f charts/pedido-app/values.yaml \
  -f charts/pedido-app/values-dev.yaml \
  --set db.auth.password="<CONTRASEÑA_SEGURA>"
```

### 1.5 – Desinstalar

```bash
helm uninstall pedido-app --namespace pedido-dev
```

---

## 2 – Imágenes de los servicios

Actualiza los valores de imagen en el archivo correspondiente al entorno:

```yaml
# values-dev.yaml
backend:
  image:
    repository: ghcr.io/tu-org/pedido-backend
    tag: "dev"

frontend:
  image:
    repository: ghcr.io/tu-org/pedido-frontend
    tag: "dev"
```

---

## 3 – Configuración de ArgoCD

### 3.1 – Registrar el repositorio en ArgoCD

```bash
argocd repo add https://github.com/tu-org/pedido-app-helm.git \
  --username <GIT_USER> \
  --password <GIT_TOKEN>
```

### 3.2 – Aplicar las definiciones de Application

```bash
# Dev
kubectl apply -f environments/dev/application.yaml

# Prod
kubectl apply -f environments/prod/application.yaml
```

ArgoCD detectará automáticamente el repositorio y sincronizará el estado del clúster
con lo definido en Git.

### 3.3 – Cómo funciona la sincronización automática

```
┌─────────────┐   push    ┌─────────────┐   poll/webhook  ┌──────────┐
│  Developer  │ ───────▶  │  Git Repo   │ ───────────────▶ │  ArgoCD  │
└─────────────┘           └─────────────┘                  └────┬─────┘
                                                                 │ kubectl apply
                                                                 ▼
                                                          ┌─────────────┐
                                                          │  Kubernetes │
                                                          └─────────────┘
```

- **`automated.selfHeal: true`** → ArgoCD revierte cualquier cambio manual en el clúster.
- **`automated.prune: true`** → Recursos eliminados de Git son eliminados del clúster.
- **Polling** → ArgoCD revisa el repositorio cada 3 minutos por defecto.  
  Para reducir la latencia, configura un webhook en GitHub/GitLab apuntando a:  
  `https://<ARGOCD_HOST>/api/webhook`

### 3.4 – Demostración GitOps (cambio de imagen sin comandos manuales)

1. Edita `values-dev.yaml` y cambia el `tag` del backend:
   ```yaml
   backend:
     image:
       tag: "v1.1.0"
   ```
2. Haz commit y push:
   ```bash
   git add charts/pedido-app/values-dev.yaml
   git commit -m "feat: actualizar backend a v1.1.0"
   git push origin main
   ```
3. ArgoCD detecta el cambio (o es notificado via webhook) y aplica el rolling update
   al Deployment del backend **sin ningún comando manual**.

---

## 4 – Endpoints de acceso

| Entorno | Frontend | Backend API |
|---------|----------|-------------|
| Dev  | `http://pedido-dev.local/`       | `http://pedido-dev.local/api/`  |
| Prod | `https://pedido-prod.local/`     | `https://pedido-prod.local/api/` |

> Asegúrate de agregar las entradas correspondientes en `/etc/hosts` para pruebas locales:
> ```
> <INGRESS_IP>  pedido-dev.local
> <INGRESS_IP>  pedido-prod.local
> ```

---

## 5 – Recursos Kubernetes desplegados

| Recurso | Nombre | Notas |
|---------|--------|-------|
| Deployment | `pedido-app-backend` | Spring Boot API |
| Deployment | `pedido-app-frontend` | React/Vue/Angular |
| Service (ClusterIP) | `pedido-app-backend` | Puerto 8080 |
| Service (ClusterIP) | `pedido-app-frontend` | Puerto 80 |
| Ingress | `pedido-app-ingress` | `/api/*` → backend, `/` → frontend |
| PersistentVolumeClaim | gestionado por Bitnami chart | Datos de PostgreSQL |
| ConfigMap | `pedido-app-backend-config` | URL de DB, variables no sensibles |
| Secret | `pedido-db-secret` | Credenciales de PostgreSQL (base64) |
| HorizontalPodAutoscaler | `pedido-app-backend-hpa` | CPU target 70% (dev), 60% (prod) |
| StatefulSet | `pedido-app-postgresql` | Gestionado por Bitnami chart |

---

## 6 – Seguridad de credenciales

Las credenciales **nunca** se almacenan en texto plano en el repositorio.
Opciones recomendadas:

- **Sealed Secrets** (Bitnami): cifra el Secret con la clave pública del clúster.
- **External Secrets Operator**: sincroniza desde HashiCorp Vault / AWS Secrets Manager.
- **ArgoCD Vault Plugin**: inyecta secretos en tiempo de sincronización.

Para desarrollo local/demo, pasa la contraseña via `--set` en la línea de comandos.

---

## 7 – HPA y escalado del backend

El backend cuenta con un `HorizontalPodAutoscaler` (autoscaling/v2):

```yaml
# dev
hpa:
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 70

# prod
hpa:
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 60
```

Requiere **Metrics Server** instalado en el clúster:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

---

## 8 – Diagrama de arquitectura

```
                         ┌─────────────────────────────────────┐
                         │           Kubernetes Cluster          │
                         │                                       │
 Usuario ──▶ Ingress ──▶ │  /api/*  ──▶  [Backend Service]      │
                         │                      │                │
                         │              [Backend Pods x N]       │
                         │               (Spring Boot + HPA)     │
                         │                      │                │
                         │              [PostgreSQL StatefulSet] │
                         │               (PVC con persistencia)  │
                         │                                       │
              ──▶        │  /       ──▶  [Frontend Service]      │
                         │              [Frontend Pods x N]      │
                         └─────────────────────────────────────┘
```
