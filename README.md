# Parcial I — Patrones Arquitectónicos Avanzados

**Sistema de gestión de pedidos** desplegado con Helm + ArgoCD en Azure Kubernetes Service (AKS).

---

## Arquitectura general

```
Internet
    │
    ▼
┌─────────────────────────────────────────┐
│  ingress-nginx  (IP: 20.121.172.186)    │
│                                         │
│  /api/*  ──────►  backend  :8080        │
│  /       ──────►  frontend :80          │
└─────────────────────────────────────────┘
         │                    │
         ▼                    ▼
  Spring Boot API        Nginx + React
         │
         ▼
    PostgreSQL :5432
    (PVC persistente)
```

| Ambiente | Namespace     | Host Ingress                            |
|----------|---------------|-----------------------------------------|
| Dev      | `pedido-dev`  | `pedido-dev.eastus.cloudapp.azure.com`  |
| Prod     | `pedido-prod` | `pedido-prod.eastus.cloudapp.azure.com` |

---

## Estructura del repositorio

```
charts/
└── pedido-app/              ← Chart principal
    ├── Chart.yaml
    ├── values.yaml          ← Valores base (todos los ambientes)
    ├── values-dev.yaml      ← Sobreescrituras para desarrollo
    ├── values-prod.yaml     ← Sobreescrituras para producción
    ├── templates/
    │   ├── ingress.yaml     ← Ingress /api/* y /
    │   ├── postgresql.yaml  ← StatefulSet + PVC + Service de PostgreSQL
    │   └── db-secret.yaml   ← Secret de credenciales (opcional)
    └── charts/
        ├── backend/         ← Subchart Spring Boot
        │   └── templates/
        │       ├── deployment.yaml
        │       ├── service.yaml
        │       ├── configmap.yaml
        │       └── hpa.yaml
        └── frontend/        ← Subchart Nginx/React
            └── templates/
                ├── deployment.yaml
                └── service.yaml

environments/
├── dev/
│   └── application.yaml    ← ArgoCD Application para dev
└── prod/
    └── application.yaml    ← ArgoCD Application para prod
```

---

## Prerrequisitos

- `kubectl` configurado apuntando al cluster AKS
- `helm` v3.x instalado
- Acceso al ACR `andresazcona.azurecr.io` (o imágenes propias)

---

## 1. Instalación manual con Helm

### Paso 1 — Crear el namespace

```bash
kubectl create namespace pedido-dev
# Para producción:
kubectl create namespace pedido-prod
```

### Paso 2 — Crear el Secret de credenciales de BD

El chart no expone contraseñas en texto plano. El Secret se pre-crea de forma segura:

```bash
kubectl create secret generic pedido-db-secret \
  --namespace pedido-dev \
  --from-literal=db-password=TuPasswordSegura
```

> **¿Por qué fuera del chart?** Si el secret estuviera en `values.yaml`, la contraseña quedaría en el historial de Git. Al pre-crearlo con `kubectl`, Kubernetes lo cifra en etcd y nunca aparece en el repositorio.

### Paso 3 — Instalar el chart en dev

```bash
helm install pedido-app-dev ./charts/pedido-app \
  --namespace pedido-dev \
  --values charts/pedido-app/values.yaml \
  --values charts/pedido-app/values-dev.yaml \
  --set db.createSecret=false
```

### Paso 4 — Instalar el chart en prod

```bash
kubectl create namespace pedido-prod

kubectl create secret generic pedido-db-secret \
  --namespace pedido-prod \
  --from-literal=db-password=TuPasswordSegura

helm install pedido-app-prod ./charts/pedido-app \
  --namespace pedido-prod \
  --values charts/pedido-app/values.yaml \
  --values charts/pedido-app/values-prod.yaml \
  --set db.createSecret=false
```

### Paso 5 — Verificar el despliegue

```bash
kubectl get pods -n pedido-dev
kubectl get ingress -n pedido-dev
kubectl get hpa -n pedido-dev
```

### Upgrade y desinstalación

```bash
# Actualizar
helm upgrade pedido-app-dev ./charts/pedido-app \
  --namespace pedido-dev \
  --values charts/pedido-app/values.yaml \
  --values charts/pedido-app/values-dev.yaml

# Desinstalar
helm uninstall pedido-app-dev --namespace pedido-dev
```

---

## 2. Configuración de ArgoCD

ArgoCD gestiona la sincronización automática desde Git. Cuando se hace `git push`, ArgoCD detecta el cambio y lo aplica al cluster sin ningún comando manual.

### Aplicar las definiciones de Application

```bash
kubectl apply -f environments/dev/application.yaml
kubectl apply -f environments/prod/application.yaml
```

### Acceder a la UI de ArgoCD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
# Abrir: http://localhost:8080
# Usuario: admin
```

Obtener contraseña inicial:
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Qué hace cada Application

Ambas apps apuntan al mismo repositorio Git pero con distintos `values`:

```
Repositorio: https://github.com/andresazcona/Parcial_1_Patrones.git
Path:        charts/pedido-app

Dev:  values.yaml + values-dev.yaml  →  namespace pedido-dev
Prod: values.yaml + values-prod.yaml →  namespace pedido-prod
```

**Política de sync (automated):**
- `prune: true` — elimina recursos que se borren en Git
- `selfHeal: false` — no revierte cambios manuales de estado transitorio

### Demostración GitOps

```bash
# 1. Editar el tag de imagen en Git
sed -i 's/tag: "latest"/tag: "v1.1"/' charts/pedido-app/values-dev.yaml

# 2. Push al repositorio
git add charts/pedido-app/values-dev.yaml
git commit -m "demo: nueva versión del backend"
git push origin main

# 3. En ~2 minutos ArgoCD lo aplica automáticamente. Verificar:
kubectl rollout status deployment/pedido-app-dev-backend -n pedido-dev
```

---

## 3. Endpoints de acceso

### Dev

| Recurso  | URL                                                              |
|----------|------------------------------------------------------------------|
| Frontend | `http://pedido-dev.eastus.cloudapp.azure.com`                   |
| API      | `http://pedido-dev.eastus.cloudapp.azure.com/api/pedidos`        |

### Prod

| Recurso  | URL                                                               |
|----------|-------------------------------------------------------------------|
| Frontend | `http://pedido-prod.eastus.cloudapp.azure.com`                   |
| API      | `http://pedido-prod.eastus.cloudapp.azure.com/api/pedidos`        |

> **Nota:** Agregar al `/etc/hosts` para resolución local:
> ```
> 20.121.172.186  pedido-dev.eastus.cloudapp.azure.com
> 20.121.172.186  pedido-prod.eastus.cloudapp.azure.com
> ```

### Ejemplos de uso de la API

```bash
# Listar pedidos
curl http://pedido-dev.eastus.cloudapp.azure.com/api/pedidos

# Crear un pedido
curl -X POST http://pedido-dev.eastus.cloudapp.azure.com/api/pedidos \
  -H "Content-Type: application/json" \
  -d '{"producto": "Laptop", "cantidad": 1, "precio": 1500.00}'

# Verificar persistencia: reiniciar el pod de BD y volver a listar
kubectl delete pod pedido-app-dev-db-0 -n pedido-dev
sleep 30
curl http://pedido-dev.eastus.cloudapp.azure.com/api/pedidos
# Los datos persisten gracias al PVC
```

---

## 4. Recursos Kubernetes por ambiente

| Recurso                | Dev                               | Prod                               |
|------------------------|-----------------------------------|------------------------------------|
| Deployment backend     | 1 réplica                         | 2 réplicas                         |
| Deployment frontend    | 1 réplica                         | 2 réplicas                         |
| StatefulSet PostgreSQL | 1 réplica                         | 1 réplica                          |
| PVC PostgreSQL         | 2 Gi                              | 20 Gi (managed-csi)                |
| HPA backend            | min 1 / max 3 réplicas (CPU 70%)  | min 2 / max 10 réplicas (CPU 60%)  |
| Ingress                | 1 (nginx, HTTP)                   | 1 (nginx, HTTPS + TLS)             |
| Secret                 | `pedido-db-secret`                | `pedido-db-secret`                 |
| ConfigMap              | `*-backend-config`                | `*-backend-config`                 |

---

## 5. Variables configurables (values.yaml)

| Parámetro                        | Descripción                          | Default        |
|----------------------------------|--------------------------------------|----------------|
| `backend.image.repository`       | Imagen del backend                   | *(requerido)*  |
| `backend.image.tag`              | Tag de la imagen                     | `latest`       |
| `backend.replicaCount`           | Réplicas del backend                 | `1`            |
| `backend.resources.requests.cpu` | CPU solicitada                       | `150m`         |
| `backend.hpa.maxReplicas`        | Máximo de réplicas HPA               | `5`            |
| `frontend.image.repository`      | Imagen del frontend                  | *(requerido)*  |
| `frontend.replicaCount`          | Réplicas del frontend                | `1`            |
| `db.auth.database`               | Nombre de la BD                      | `pedido_db`    |
| `db.auth.username`               | Usuario de la BD                     | `pedido_user`  |
| `db.persistence.size`            | Tamaño del PVC                       | `5Gi`          |
| `ingress.host`                   | Hostname del Ingress                 | `pedido-app.local` |

---

## 6. Nota sobre PostgreSQL

El enunciado indica usar el chart oficial de Bitnami como dependencia. En esta implementación se usa un **StatefulSet personalizado** con la imagen oficial `postgres:15-alpine` por la siguiente razón:

> Las imágenes de Bitnami dejaron de publicarse en Docker Hub desde 2023. Al intentar hacer pull desde AKS (`bitnami/postgresql:16.x`), el cluster devuelve `manifest unknown`. La solución fue usar `postgres:15-alpine` oficial, empujarla al ACR propio y desplegarla mediante un StatefulSet declarado en el chart.

La funcionalidad es **equivalente**: StatefulSet + PVC persistente + Service + Secret de credenciales.

---

*Para documentación técnica detallada ver [docs.md](docs.md)*
