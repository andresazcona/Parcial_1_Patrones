# Documentación Técnica — Sistema de Pedidos

Esta guía explica en detalle cómo está construido, cómo funciona y por qué se tomaron las decisiones de diseño que se ven en este proyecto.

---

## Tabla de contenidos

1. [Visión general](#1-visión-general)
2. [¿Qué es Helm y cómo se usa aquí?](#2-qué-es-helm-y-cómo-se-usa-aquí)
3. [Estructura del chart de Helm](#3-estructura-del-chart-de-helm)
4. [¿Qué es el Ingress y cómo está configurado?](#4-qué-es-el-ingress-y-cómo-está-configurado)
5. [¿Qué es ArgoCD y cómo está configurado?](#5-qué-es-argocd-y-cómo-está-configurado)
6. [¿Qué es el HPA?](#6-qué-es-el-hpa)
7. [Persistencia de datos](#7-persistencia-de-datos)
8. [Seguridad y manejo de credenciales](#8-seguridad-y-manejo-de-credenciales)
9. [Separación de ambientes](#9-separación-de-ambientes)
10. [Flujo completo de una request HTTP](#10-flujo-completo-de-una-request-http)
11. [Infraestructura de Azure](#11-infraestructura-de-azure)
12. [Decisiones de diseño](#12-decisiones-de-diseño)

---

## 1. Visión general

El proyecto implementa una arquitectura de tres capas (base de datos, backend, frontend) dentro de un cluster Kubernetes usando dos herramientas clave:

- **Helm**: empaqueta todos los recursos Kubernetes en un "chart" reutilizable y parametrizable.
- **ArgoCD**: observa el repositorio Git y aplica automáticamente los cambios al cluster (GitOps).

```
┌─── Git Repository ────────────────────────────────────┐
│  charts/pedido-app/   ← Chart de Helm                 │
│  environments/        ← Definiciones de ArgoCD         │
└───────────────────────────────────────────────────────┘
         │ git push
         ▼
┌─── ArgoCD ────────────────────────────────────────────┐
│  Detecta cambios cada ~3 min                          │
│  Aplica helm template | kubectl apply automáticamente  │
└───────────────────────────────────────────────────────┘
         │ kubectl apply
         ▼
┌─── AKS Cluster ───────────────────────────────────────┐
│  Namespace: pedido-dev                                │
│  ┌──────────────────────────────────────────────────┐ │
│  │ Ingress (nginx)                                  │ │
│  │   /api/*  →  backend-svc :8080                   │ │
│  │   /       →  frontend-svc :80                    │ │
│  ├──────────────────────────────────────────────────┤ │
│  │ backend (Spring Boot)  │  frontend (Nginx+React)  │ │
│  ├──────────────────────────────────────────────────┤ │
│  │ PostgreSQL (StatefulSet + PVC)                   │ │
│  └──────────────────────────────────────────────────┘ │
│                                                        │
│  Namespace: pedido-prod  (misma estructura, más réplicas) │
└───────────────────────────────────────────────────────┘
```

---

## 2. ¿Qué es Helm y cómo se usa aquí?

**Helm** es el gestor de paquetes de Kubernetes. Funciona igual que `apt` o `npm` pero para recursos de Kubernetes. Un "chart" es un paquete que contiene plantillas YAML parametrizadas por variables.

### ¿Por qué Helm?

Sin Helm tendríamos que mantener archivos YAML separados para dev y prod (con muchos valores duplicados). Con Helm:
- Hay un único conjunto de plantillas
- Los valores cambian por archivo (`values-dev.yaml`, `values-prod.yaml`)
- Un solo comando instala o actualiza toda la aplicación

### Cómo funciona una instalación

```
helm install pedido-app-dev ./charts/pedido-app \
  --values values.yaml \
  --values values-dev.yaml
```

Helm hace internamente:
1. Lee `Chart.yaml` para saber qué chart es
2. Combina `values.yaml` + `values-dev.yaml` (el segundo sobreescribe al primero)
3. Renderiza cada archivo en `templates/` sustituyendo `{{ .Values.xxx }}`
4. Envía los YAML resultantes a la API de Kubernetes

### Subcharts

El chart principal (`pedido-app`) tiene dos subcharts en `charts/`:
- `backend/` — gestiona el Deployment, Service, ConfigMap y HPA del Spring Boot
- `frontend/` — gestiona el Deployment y Service del frontend

Los valores de los subcharts se pasan con el prefijo del subchart:
```yaml
# En values.yaml, esto llega al subchart backend:
backend:
  replicaCount: 2
  image:
    repository: andresazcona.azurecr.io/pedido-backend
```

---

## 3. Estructura del chart de Helm

### Chart.yaml — Metadatos del chart

```yaml
apiVersion: v2
name: pedido-app
description: Sistema de gestión de pedidos
version: 1.0.0      # Versión del chart
appVersion: "1.0.0" # Versión de la aplicación
```

### values.yaml — Variables base

Define todas las variables con sus valores por defecto. Cualquier ambiente puede sobreescribir cualquier valor.

```yaml
backend:
  replicaCount: 1          # Default: 1 réplica
  image:
    repository: ""         # Vacío — debe setearse por ambiente
    tag: "latest"
  resources:
    requests:
      cpu: "150m"          # 0.15 cores solicitados
      memory: "256Mi"
    limits:
      cpu: "400m"          # Máximo 0.4 cores
      memory: "512Mi"
```

### templates/ — Plantillas de recursos

Cada archivo genera uno o más recursos Kubernetes:

| Archivo | Recurso(s) generado(s) | Tipo |
|---------|------------------------|------|
| `postgresql.yaml` | StatefulSet + PVC + Service | Estado (BD) |
| `ingress.yaml` | Ingress | Red |
| `db-secret.yaml` | Secret (opcional) | Seguridad |
| `backend/deployment.yaml` | Deployment | Aplicación |
| `backend/service.yaml` | Service (ClusterIP) | Red |
| `backend/configmap.yaml` | ConfigMap | Configuración |
| `backend/hpa.yaml` | HorizontalPodAutoscaler | Escalado |
| `frontend/deployment.yaml` | Deployment | Aplicación |
| `frontend/service.yaml` | Service (ClusterIP) | Red |

### Ejemplo de plantilla con variables

**`configmap.yaml`** del backend genera la URL de conexión a la BD dinámicamente:

```yaml
data:
  SPRING_DATASOURCE_URL: "jdbc:postgresql://{{ .Release.Name }}-db:{{ .Values.db.port }}/{{ .Values.db.name }}"
  SPRING_DATASOURCE_USERNAME: {{ .Values.db.user | quote }}
```

Para el release `pedido-app-dev` esto produce:
```yaml
data:
  SPRING_DATASOURCE_URL: "jdbc:postgresql://pedido-app-dev-db:5432/pedido_db"
  SPRING_DATASOURCE_USERNAME: "pedido_user"
```

---

## 4. ¿Qué es el Ingress y cómo está configurado?

### Concepto de Ingress

Un **Ingress** es un recurso de Kubernetes que actúa como **punto de entrada HTTP/HTTPS** al cluster. Sin Ingress, cada Service necesitaría una IP pública propia (LoadBalancer), lo cual es caro. Con Ingress:

```
Internet ──► 1 IP pública (Ingress) ──► múltiples Services internos
```

El **Ingress Controller** (en este caso `ingress-nginx`) es el componente que recibe las requests y las enruta según las reglas del Ingress resource.

### ¿Dónde está?

```bash
kubectl get pods -n ingress-nginx
# NAME                                        READY   STATUS
# ingress-nginx-controller-xxx                1/1     Running

kubectl get svc -n ingress-nginx ingress-nginx-controller
# EXTERNAL-IP: 20.121.172.186   ← IP pública de Azure
```

### Cómo está configurado en el chart

```yaml
# charts/pedido-app/templates/ingress.yaml
spec:
  ingressClassName: nginx
  rules:
    - host: pedido-dev.eastus.cloudapp.azure.com
      http:
        paths:
          # Todo lo que empiece con /api/ va al backend
          - path: /api(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: pedido-app-dev-backend
                port:
                  number: 8080

          # Todo lo demás va al frontend
          - path: /()(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: pedido-app-dev-frontend
                port:
                  number: 80
```

### La anotación rewrite-target

```yaml
annotations:
  nginx.ingress.kubernetes.io/rewrite-target: /$2
```

Esta anotación es crítica. Sin ella:
- Request: `GET /api/pedidos`
- El backend recibiría: `GET /api/pedidos` → pero la app tiene el endpoint en `/pedidos`, no en `/api/pedidos`

Con `rewrite-target: /$2`:
- El grupo `$2` captura todo lo que viene **después** de `/api/`
- Request: `GET /api/pedidos` → Backend recibe: `GET /pedidos` ✅

### Flujo de red

```
Usuario → http://pedido-dev.eastus.cloudapp.azure.com/api/pedidos
    │
    ▼
ingress-nginx (20.121.172.186:80)
    │  Regla: host=pedido-dev..., path=/api/*
    │  Rewrite: /api/pedidos → /pedidos
    ▼
Service: pedido-app-dev-backend (ClusterIP, puerto 8080)
    │
    ▼
Pod: pedido-app-dev-backend-xxx (Spring Boot en :8080)
    │  GET /pedidos
    ▼
Service: pedido-app-dev-db (ClusterIP, puerto 5432)
    │
    ▼
Pod: pedido-app-dev-db-0 (PostgreSQL)
```

---

## 5. ¿Qué es ArgoCD y cómo está configurado?

### Concepto de ArgoCD y GitOps

**ArgoCD** implementa el patrón **GitOps**: el repositorio Git es la fuente de verdad del estado del cluster. Cualquier cambio debe pasar por Git; ArgoCD lo detecta y lo aplica.

```
Developer → git push → GitHub → (ArgoCD polling) → kubectl apply → Cluster
```

Beneficios:
- Auditoría completa (cada cambio tiene un commit con autor y timestamp)
- Rollback trivial (`git revert`)
- No se necesita acceso directo al cluster para desplegar

### ¿Dónde está ArgoCD?

```bash
kubectl get pods -n argocd
# argocd-server-xxx              1/1  Running
# argocd-application-controller  1/1  Running
# argocd-repo-server-xxx         1/1  Running

# IP pública del servidor ArgoCD
kubectl get svc argocd-server -n argocd
# EXTERNAL-IP: 20.121.183.83
```

### Estructura de una ArgoCD Application

```yaml
# environments/dev/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pedido-app-dev
  namespace: argocd

spec:
  # Repositorio Git a observar
  source:
    repoURL: https://github.com/andresazcona/Parcial_1_Patrones.git
    targetRevision: HEAD          # Siempre el commit más reciente
    path: charts/pedido-app       # Dónde está el chart dentro del repo

    helm:
      valueFiles:
        - values.yaml             # Base
        - values-dev.yaml         # Sobreescrituras de dev

  # Dónde se despliega
  destination:
    server: https://kubernetes.default.svc
    namespace: pedido-dev

  # Política de sincronización automática
  syncPolicy:
    automated:
      prune: true     # Si se borra un recurso en Git, lo borra del cluster
      selfHeal: false # No revertir cambios transitorios de Kubernetes
    syncOptions:
      - CreateNamespace=true          # Crear el namespace si no existe
      - PrunePropagationPolicy=foreground
```

### Ciclo de vida de un cambio

```
1. Developer edita values-dev.yaml (ej: tag: "v1.2")
2. git push a main
3. ArgoCD polling cada ~3 minutos detecta el nuevo commit
4. ArgoCD compara el estado en Git vs el estado en Kubernetes
5. ArgoCD detecta que el Deployment tiene imagen diferente
6. ArgoCD ejecuta internamente: helm template | kubectl apply
7. Kubernetes hace rolling update del Deployment
8. Los pods nuevos sustituyen a los viejos sin downtime
```

### Estados en la UI de ArgoCD

| Estado | Significado |
|--------|-------------|
| `Synced` | El cluster coincide exactamente con Git |
| `OutOfSync` | Hay diferencias entre Git y el cluster |
| `Healthy` | Todos los pods están Running y Ready |
| `Progressing` | Rolling update en curso |
| `Degraded` | Algún pod está crasheando |

---

## 6. ¿Qué es el HPA?

### Concepto

El **HorizontalPodAutoscaler** escala automáticamente el número de réplicas de un Deployment según métricas (CPU, memoria, etc.). Si hay mucho tráfico → más pods. Si el tráfico baja → menos pods.

```
Tráfico bajo  → 1 réplica  (min)
Tráfico medio → 3 réplicas (automático)
Tráfico alto  → 10 réplicas (max)
```

### Cómo está configurado

```yaml
# charts/pedido-app/charts/backend/templates/hpa.yaml
spec:
  scaleTargetRef:
    kind: Deployment
    name: pedido-app-dev-backend

  minReplicas: 1    # Siempre al menos 1 pod
  maxReplicas: 3    # Nunca más de 3 pods (en dev)

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70  # Escalar cuando el uso de CPU supere 70%
```

### Diferencia por ambiente

| Parámetro | Dev | Prod |
|-----------|-----|------|
| `minReplicas` | 1 | 2 |
| `maxReplicas` | 3 | 10 |
| `targetCPU` | 70% | 60% |

Prod escala antes (60% de CPU) y puede tener más pods porque el tráfico real lo requiere.

### Verificar el HPA

```bash
kubectl get hpa -n pedido-dev
# NAME                          REFERENCE              TARGETS   MINPODS   MAXPODS   REPLICAS
# pedido-app-dev-backend-hpa    Deployment/backend     15%/70%   1         3         1
```

---

## 7. Persistencia de datos

### El problema

Los pods son **efímeros**: si PostgreSQL se reinicia, sin un volumen persistente, todos los datos desaparecerían.

### La solución: PersistentVolumeClaim (PVC)

Un **PVC** es una solicitud de almacenamiento persistente. Kubernetes encuentra un **PersistentVolume** (disco de Azure) que satisfaga la solicitud y lo "monta" en el pod.

```yaml
# En postgresql.yaml (simplificado)
apiVersion: apps/v1
kind: StatefulSet
spec:
  volumeClaimTemplates:
    - metadata:
        name: postgres-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 2Gi        # Dev: 2 GB
            # Prod: 20 GB, StorageClass: managed-csi (Azure Disk)
```

### Por qué StatefulSet y no Deployment

Los **StatefulSets** garantizan:
- Nombre de pod estable (`db-0`, siempre el mismo)
- El PVC se re-monta al mismo pod si se reinicia
- Orden de inicio/parada predecible

Con un Deployment normal, si el pod se reinicia en otro nodo, podría perder el disco.

### Verificar la persistencia

```bash
# Ver el PVC
kubectl get pvc -n pedido-dev
# NAME                     STATUS   VOLUME           CAPACITY   ACCESS MODES
# pedido-app-dev-db-pvc    Bound    pvc-c9a03407...  2Gi        RWO

# Reiniciar la BD (simula un fallo)
kubectl delete pod pedido-app-dev-db-0 -n pedido-dev

# El StatefulSet recrea el pod automáticamente con el mismo PVC
kubectl get pod pedido-app-dev-db-0 -n pedido-dev -w

# Los datos siguen ahí
curl http://pedido-dev.eastus.cloudapp.azure.com/api/pedidos
```

---

## 8. Seguridad y manejo de credenciales

### ¿Por qué no poner la contraseña en values.yaml?

Si la contraseña estuviera en `values.yaml` y se hiciera `git push`:
- La contraseña quedaría en el historial de Git para siempre
- Cualquiera con acceso al repositorio la vería
- Aunque se borre en un commit posterior, sigue en el historial

### Solución: Secret pre-creado

```bash
# Se crea manualmente UNA vez, fuera de Git:
kubectl create secret generic pedido-db-secret \
  --namespace pedido-dev \
  --from-literal=db-password=MiContraseñaSegura
```

Kubernetes cifra el Secret en `etcd`. El chart referencia el Secret por nombre:

```yaml
# deployment.yaml del backend
env:
  - name: SPRING_DATASOURCE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: pedido-db-secret   # Nombre del secret
        key: db-password         # Clave dentro del secret
```

### Separación de sensible / no sensible

| Dato | Dónde va | Razón |
|------|----------|-------|
| Contraseña de BD | `Secret` (pre-creado con kubectl) | No puede estar en Git |
| URL de conexión | `ConfigMap` | No es sensible |
| Usuario de BD | `ConfigMap` | No es sensible |
| Puerto, nombre de BD | `ConfigMap` | No es sensible |

### .gitignore

El `.gitignore` incluye:
```
*.secret.yaml   # Archivos de secrets nunca se commitean
/images         # Las imágenes Docker (234 MB) no van en Git
```

---

## 9. Separación de ambientes

### Cómo funciona el merge de values

Helm combina valores de izquierda a derecha; los últimos sobreescriben los anteriores:

```
values.yaml (base)  +  values-dev.yaml (overrides)  =  configuración final
```

Ejemplo:
```yaml
# values.yaml (base)
backend:
  replicaCount: 1
  resources:
    requests:
      cpu: "150m"

# values-dev.yaml
backend:
  replicaCount: 1    # mismo
  # (recursos no definidos → hereda de values.yaml)

# values-prod.yaml
backend:
  replicaCount: 2    # sobreescribe
  resources:
    requests:
      cpu: "500m"    # sobreescribe
```

### Diferencias clave entre ambientes

| Aspecto | Dev | Prod |
|---------|-----|------|
| Namespace | `pedido-dev` | `pedido-prod` |
| Réplicas backend | 1 | 2 |
| Réplicas frontend | 1 | 2 |
| CPU backend | 150m / 400m | 500m / 1000m |
| PVC BD | 2 Gi | 20 Gi |
| StorageClass | default | `managed-csi` (Azure) |
| HPA max | 3 | 10 |
| TLS | No | Sí |
| Host Ingress | `pedido-dev.eastus...` | `pedido-prod.eastus...` |

### Nomenclatura de recursos

Todos los recursos se nombran con el _release name_ de Helm para evitar conflictos:

```
Release: pedido-app-dev  →  Recursos: pedido-app-dev-backend, pedido-app-dev-db, ...
Release: pedido-app-prod →  Recursos: pedido-app-prod-backend, pedido-app-prod-db, ...
```

---

## 10. Flujo completo de una request HTTP

### Caso: `GET /api/pedidos` desde el navegador

```
1. DNS lookup: pedido-dev.eastus.cloudapp.azure.com → 20.121.172.186
   (o entrada en /etc/hosts)

2. TCP connection al puerto 80 de 20.121.172.186

3. nginx-ingress-controller recibe la request:
   - Host: pedido-dev.eastus.cloudapp.azure.com  ✅ regla coincide
   - Path: /api/pedidos                           ✅ patrón /api(/|$)(.*) coincide
   - Rewrite: /api/pedidos → /pedidos             (grupo $2 = "pedidos")

4. nginx hace proxy a Service pedido-app-dev-backend:8080
   (ClusterIP interno, ej: 10.0.123.45)

5. kube-proxy balancea al Pod del backend (ej: 10.244.1.50:8080)

6. Spring Boot procesa GET /pedidos:
   - Spring Data JPA genera SQL: SELECT * FROM pedidos
   - HikariPool reutiliza conexión existente al DB

7. TCP al Service pedido-app-dev-db:5432 → Pod db-0 (StatefulSet)

8. PostgreSQL ejecuta la query y devuelve resultados

9. Spring Boot serializa a JSON: [{...}, {...}]

10. La respuesta recorre el camino inverso hasta el navegador
```

### Caso: cambio de código via GitOps

```
1. Developer: git push (nuevo tag de imagen)

2. GitHub recibe el push en main

3. ArgoCD (polling cada 3 min) detecta el nuevo commit SHA

4. ArgoCD ejecuta internamente:
   helm template pedido-app-dev ./charts/pedido-app \
     -f values.yaml -f values-dev.yaml

5. Compara manifiestos resultantes vs cluster actual
   → Detecta: Deployment tiene image:v1.1 en Git pero v1.0 en cluster

6. ArgoCD aplica el Deployment actualizado:
   kubectl apply -f deployment.yaml

7. Kubernetes hace rolling update:
   - Crea pod nuevo con imagen v1.1
   - Espera a que pase readiness probe
   - Termina pod viejo con imagen v1.0
   - Sin downtime

8. ArgoCD marca la app como Synced + Healthy
```

---

## 11. Infraestructura de Azure

### Recursos creados

| Recurso | Nombre | Propósito |
|---------|--------|-----------|
| Resource Group | `rg-pedido-app` | Contenedor de todos los recursos |
| AKS Cluster | `aks-pedido-app` | Cluster Kubernetes (2 nodos Standard_B2s) |
| ACR | `andresazcona.azurecr.io` | Registro de imágenes Docker |
| Load Balancer | (automático) | IP pública para ingress-nginx |
| Load Balancer | (automático) | IP pública para ArgoCD |
| Azure Disks | (automático) | Almacenamiento para PVCs |
| Managed Resource Group | `MC_rg-pedido-app_aks-pedido-app_eastus` | Recursos internos de AKS (no tocar) |

### Nodos del cluster

```
2x Standard_B2s:
  - 2 vCPUs
  - 4 GB RAM
  - 8 GB disco temporal
```

### Imágenes en ACR

| Imagen | Descripción |
|--------|-------------|
| `andresazcona.azurecr.io/pedido-backend:latest` | Spring Boot API |
| `andresazcona.azurecr.io/pedido-frontend:latest` | Frontend React/Nginx |
| `andresazcona.azurecr.io/postgresql:15-alpine` | PostgreSQL 15 |

### Apagar / encender el cluster

El script `azure-control.sh` facilita el control del cluster:

```bash
./azure-control.sh stop    # Detiene el cluster (ahorra ~$8-12/día)
./azure-control.sh start   # Enciende el cluster y configura kubectl
./azure-control.sh status  # Muestra estado del cluster y los pods
./azure-control.sh argocd  # Port-forward a ArgoCD en localhost:8080
```

---

## 12. Decisiones de diseño

### ¿Por qué subcharts en lugar de un chart plano?

El enunciado pide separación. Con subcharts:
- `backend/` puede tener sus propios defaults sin contaminar los valores de `frontend/`
- Cada subchart puede versanarse independientemente
- La estructura refleja claramente los tres componentes

### ¿Por qué TCP socket probes en lugar de HTTP /actuator/health?

La imagen del backend (`nikx00/pedido-backend`) es una Spring Boot API que **no incluye Spring Actuator** en su configuración. Al configurar probes HTTP a `/actuator/health`, el endpoint respondía 404 y Kubernetes mataba el pod en un loop.

La probe TCP socket simplemente verifica que el puerto 8080 esté escuchando, lo cual es suficiente para saber que el proceso está vivo:

```yaml
livenessProbe:
  tcpSocket:
    port: 8080
  initialDelaySeconds: 90  # Spring Boot tarda ~33s en arrancar
  periodSeconds: 30
  failureThreshold: 3
```

### ¿Por qué selfHeal: false en ArgoCD?

`selfHeal: true` hace que ArgoCD revierta **cualquier** cambio manual al cluster. El problema: durante rolling updates, Kubernetes crea ReplicaSets intermedios que difieren del estado en Git. Con selfHeal activo, ArgoCD los revertía mientras Kubernetes intentaba actualizar, creando un loop infinito.

Con `selfHeal: false`, ArgoCD solo sincroniza cuando hay un nuevo commit en Git.

### ¿Por qué custom StatefulSet en lugar de Bitnami chart?

Bitnami dejó de publicar imágenes en Docker Hub en 2023. Las tags `bitnami/postgresql:16.x` devuelven `manifest unknown` desde Docker Hub. En lugar de requerir autenticación a Bitnami Container Registry, se optó por:
1. Usar `postgres:15-alpine` (imagen oficial de Docker Hub, siempre disponible)
2. Tagearla y empujarla al ACR propio
3. Definir el StatefulSet directamente en el chart

Esto simplifica el grafo de dependencias y evita un punto de fallo externo.

### ¿Por qué resources.requests bajos (150m CPU)?

Los nodos `Standard_B2s` tienen 2 vCPUS cada uno. Con los pods del sistema (kube-proxy, coredns, ingress-nginx, argocd, metrics-server) ya consumidos, quedan aproximadamente `1.2 vCPU` disponibles por nodo para la aplicación. Con 2 nodos:

```
Disponible: ~2.4 vCPU total
Por pod:    150m = 0.15 vCPU
Capacidad:  ~16 pods de backend simultáneos (rolling update incluido)
```

Con 250m (el valor original), el rolling update necesitaba 3×250m = 750m en un nodo, lo cual excedía la capacidad disponible y dejaba pods en `Pending`.
