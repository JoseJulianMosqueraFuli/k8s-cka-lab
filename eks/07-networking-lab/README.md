# Lab 07: Red y aislamiento — quién habla con quién

## Resumen

Implementas aislamiento de red real en el cluster: NetworkPolicies para controlar
tráfico entre pods, verificas con pods de prueba, configuras prefix delegation
para maximizar pods por nodo, y estableces boundaries por namespace con RBAC,
ResourceQuota y LimitRange.

El objetivo es que un pod solo pueda hablar con quien explícitamente le permites.
Todo lo demás está bloqueado.

**Se monta sobre:** el cluster del lab 02 (EC2) o 03 (Auto Mode).
**Costo estimado adicional:** ~$0.00 (no hay infra nueva, solo configuración)
**Tiempo:** ~2h 30m

**Herramientas necesarias:**

- AWS CLI v2
- kubectl
- La imagen `identity-api` del lab 04 (opcional, para pruebas de conectividad)

**Conexión CKA:** `domains/03-services-networking` — NetworkPolicies, Services, DNS (20% del examen)

---

## Qué vas a construir

```
Namespace: frontend         Namespace: backend          Namespace: database
┌──────────────┐            ┌──────────────┐           ┌──────────────┐
│  web-app     │──allowed──→│  api-server  │──allowed─→│  postgres    │
│  (port 80)   │            │  (port 8080) │           │  (port 5432) │
└──────────────┘            └──────────────┘           └──────────────┘
       ↑                           ↑                          ↑
   Internet                   Solo frontend              Solo backend
                              puede hablarle             puede hablarle

Default-deny en todos los namespaces: si no hay regla, no hay tráfico.
```

---

## Parte 1: NetworkPolicies — aislamiento de tráfico

### Paso 1.1: Verificar que NetworkPolicies funcionan

En EKS con VPC CNI, las NetworkPolicies funcionan nativamente desde la versión
1.25 del add-on. No necesitas Calico ni otro CNI adicional.

```bash
# Verificar versión del VPC CNI
kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'
# Debe ser >= v1.14.0 para Network Policy support

# Verificar que la feature está habilitada
kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env}' | \
  grep -o "ENABLE_NETWORK_POLICY.*true" || echo "Verificar configuración"
```

Si no está habilitado:

```bash
kubectl set env daemonset aws-node -n kube-system ENABLE_NETWORK_POLICY=true
```

### Paso 1.2: Crear los namespaces y las aplicaciones de prueba

```bash
# Crear namespaces con labels
kubectl create namespace frontend
kubectl label namespace frontend tier=frontend

kubectl create namespace backend
kubectl label namespace backend tier=backend

kubectl create namespace database
kubectl label namespace database tier=database
```

```yaml
# manifests/apps.yaml
---
# Frontend
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
        tier: frontend
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
---
# Backend
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-server
  template:
    metadata:
      labels:
        app: api-server
        tier: backend
    spec:
      containers:
        - name: api
          image: hashicorp/http-echo:0.2.3
          args: ["-text=hello from backend"]
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
---
# Database (simulada)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: database
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
        tier: database
    spec:
      containers:
        - name: pg
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_PASSWORD
              value: "lab-only-not-production"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
---
# Services
apiVersion: v1
kind: Service
metadata:
  name: web-app
  namespace: frontend
spec:
  selector:
    app: web-app
  ports:
    - port: 80
---
apiVersion: v1
kind: Service
metadata:
  name: api-server
  namespace: backend
spec:
  selector:
    app: api-server
  ports:
    - port: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: database
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
```

```bash
kubectl apply -f manifests/apps.yaml
```

### Paso 1.3: Verificar conectividad ANTES del aislamiento

```bash
# Desde frontend → backend (debería funcionar)
kubectl exec -n frontend deploy/web-app -- \
  wget -qO- --timeout=3 http://api-server.backend.svc.cluster.local:5678
# "hello from backend"

# Desde frontend → database (debería funcionar — aún no hay policies)
kubectl exec -n frontend deploy/web-app -- \
  wget -qO- --timeout=3 http://postgres.database.svc.cluster.local:5432 2>&1 || echo "Conexión posible (aunque postgres no responde HTTP)"

# Desde backend → database
kubectl exec -n backend deploy/api-server -- \
  wget -qO- --timeout=3 http://postgres.database.svc.cluster.local:5432 2>&1 || echo "Conexión posible"
```

**Sin NetworkPolicies, todos hablan con todos.** Eso es el default de Kubernetes.

### Paso 1.4: Default-deny en cada namespace

```yaml
# manifests/default-deny.yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: frontend
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: backend
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: database
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

```bash
kubectl apply -f manifests/default-deny.yaml
```

### Paso 1.5: Verificar que TODO está bloqueado

```bash
# Desde frontend → backend (DEBE fallar)
kubectl exec -n frontend deploy/web-app -- \
  wget -qO- --timeout=3 http://api-server.backend.svc.cluster.local:5678
# wget: download timed out

# Desde frontend → internet (DEBE fallar)
kubectl exec -n frontend deploy/web-app -- \
  wget -qO- --timeout=3 http://example.com
# wget: download timed out
```

### ¿Por qué default-deny primero?

| Enfoque              | Resultado                                                 |
| -------------------- | --------------------------------------------------------- |
| Sin políticas        | Todo abierto — un pod comprometido alcanza todo           |
| Solo allow rules     | Lo no cubierto sigue abierto (falso sentido de seguridad) |
| Default-deny + allow | Solo lo explícito funciona — **zero trust real**          |

### Paso 1.6: Abrir solo lo necesario

```yaml
# manifests/allow-policies.yaml
---
# Frontend puede hablar con backend y resolver DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-egress
  namespace: frontend
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
    - Egress
  egress:
    # Permitir DNS
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    # Permitir tráfico al backend
    - to:
        - namespaceSelector:
            matchLabels:
              tier: backend
      ports:
        - protocol: TCP
          port: 5678
---
# Backend acepta tráfico solo de frontend
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-ingress
  namespace: backend
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              tier: frontend
      ports:
        - protocol: TCP
          port: 5678
---
# Backend puede hablar con database y DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-egress
  namespace: backend
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              tier: database
      ports:
        - protocol: TCP
          port: 5432
---
# Database acepta tráfico solo de backend
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-ingress
  namespace: database
spec:
  podSelector:
    matchLabels:
      tier: database
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              tier: backend
      ports:
        - protocol: TCP
          port: 5432
```

```bash
kubectl apply -f manifests/allow-policies.yaml
```

### Paso 1.7: Verificar que solo lo permitido funciona

```bash
# Frontend → backend: FUNCIONA
kubectl exec -n frontend deploy/web-app -- \
  wget -qO- --timeout=3 http://api-server.backend.svc.cluster.local:5678
# "hello from backend"

# Frontend → database: BLOQUEADO
kubectl exec -n frontend deploy/web-app -- \
  wget -qO- --timeout=3 http://postgres.database.svc.cluster.local:5432
# wget: download timed out

# Backend → database: FUNCIONA (TCP, no HTTP)
kubectl exec -n backend deploy/api-server -- \
  sh -c "echo 'test' | nc -w3 postgres.database.svc.cluster.local 5432" 2>&1
# La conexión se establece (postgres responderá con su handshake)
```

---

## Parte 2: Service Discovery y CoreDNS

### Cómo se resuelve un Service

```bash
# FQDN completo
kubectl exec -n frontend deploy/web-app -- nslookup api-server.backend.svc.cluster.local
# Address: 10.100.x.y

# Desde el mismo namespace puedes usar solo el nombre
kubectl exec -n backend deploy/api-server -- nslookup postgres.database.svc.cluster.local
```

### Anatomía del FQDN

```
api-server.backend.svc.cluster.local
│          │       │   │
│          │       │   └── dominio del cluster (configurable)
│          │       └────── siempre "svc" para services
│          └────────────── namespace
└───────────────────────── nombre del service
```

### ¿Por qué usar FQDN completo en NetworkPolicies?

Porque las NetworkPolicies trabajan a nivel IP, no DNS. Pero cuando depuras,
necesitas verificar que el DNS resuelve correctamente antes de culpar a la policy.

```bash
# Debug DNS
kubectl exec -n frontend deploy/web-app -- nslookup api-server.backend.svc.cluster.local
# Si esto falla → problema de DNS/CoreDNS, no de NetworkPolicy
# Si resuelve pero no conecta → NetworkPolicy bloqueando
```

---

## Parte 3: VPC CNI — IPs y capacidad de pods

### Cada pod consume una IP real del VPC

```bash
# Ver IPs de pods
kubectl get pods -A -o wide | awk '{print $7}' | sort
# Todas son IPs del rango 10.x.x.x del VPC

# Ver cuántas IPs tiene un nodo asignadas
kubectl get node <NODE_NAME> -o jsonpath='{.status.allocatable.pods}'
```

### Cuántos pods caben por instancia

| Instancia | ENIs | IPs/ENI | Pods máximos (default) | Con prefix delegation |
| --------- | ---- | ------- | ---------------------- | --------------------- |
| t3.medium | 3    | 6       | 17                     | 110                   |
| t3.large  | 3    | 12      | 35                     | 110                   |
| m5.large  | 3    | 10      | 29                     | 110                   |
| m5.xlarge | 4    | 15      | 58                     | 110                   |

Fórmula: `(ENIs × (IPs/ENI - 1)) + 2`

### ¿Por qué esto importa?

Si tienes un `t3.medium` y despliegas 20 pods, el pod 18 queda en `Pending` con
`"Too many pods"`. No es un problema de CPU ni memoria — es un límite de red.

### Prefix Delegation: multiplicar la densidad

```bash
# Habilitar prefix delegation
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true \
  WARM_PREFIX_TARGET=1

# Ahora cada "slot" de IP se convierte en un /28 (16 IPs)
# Un t3.medium pasa de 17 pods a 110 pods máximos
```

### ¿Por qué no habilitarlo siempre?

- Consume más IPs del subnet (puede agotar subnets pequeños)
- Subnets /24 con prefix delegation pueden quedarse sin espacio rápido
- La recomendación: subnets /19 o más grandes si usas prefix delegation

---

## Parte 4: Security Groups for Pods

### ¿Cuándo un pod necesita su propio Security Group?

Cuando el pod necesita hablar con un recurso AWS (RDS, ElastiCache) que tiene
un security group específico que solo permite tráfico de ciertos SGs.

```yaml
# manifests/sg-policy.yaml
apiVersion: vpcresources.k8s.aws/v1beta1
kind: SecurityGroupPolicy
metadata:
  name: db-access
  namespace: backend
spec:
  podSelector:
    matchLabels:
      needs-rds-access: "true"
  securityGroups:
    groupIds:
      - sg-0123456789abcdef0 # SG que el RDS permite en su inbound
```

```bash
kubectl apply -f manifests/sg-policy.yaml
```

### ¿Por qué no usar esto para todo?

| Mecanismo             | Granularidad   | Gestión         | Caso de uso                    |
| --------------------- | -------------- | --------------- | ------------------------------ |
| NetworkPolicy         | Pod-to-pod     | kubectl/YAML    | Aislamiento dentro del cluster |
| Security Group (nodo) | Nodo completo  | AWS Console/CLI | Default para todo el nodo      |
| SG for Pods           | Pod individual | YAML + AWS      | Acceso a recursos AWS con SG   |

NetworkPolicies son para tráfico **dentro** del cluster. SG for Pods es para
tráfico **hacia afuera** del cluster (a recursos AWS).

---

## Parte 5: Aislamiento por equipo — ResourceQuota y LimitRange

### Paso 5.1: ResourceQuota

```yaml
# manifests/quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-alpha-quota
  namespace: frontend
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "20"
    services: "5"
    persistentvolumeclaims: "5"
```

```bash
kubectl apply -f manifests/quota.yaml
kubectl describe quota -n frontend
```

### Paso 5.2: LimitRange (defaults automáticos)

```yaml
# manifests/limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: frontend
spec:
  limits:
    - default:
        cpu: 200m
        memory: 128Mi
      defaultRequest:
        cpu: 50m
        memory: 64Mi
      max:
        cpu: "1"
        memory: 512Mi
      min:
        cpu: 10m
        memory: 16Mi
      type: Container
```

```bash
kubectl apply -f manifests/limitrange.yaml
```

### ¿Por qué ambos juntos?

| Control       | Qué hace                                          | Sin él...                                     |
| ------------- | ------------------------------------------------- | --------------------------------------------- |
| ResourceQuota | Limita el TOTAL del namespace                     | Un equipo puede consumir todo el cluster      |
| LimitRange    | Pone defaults y límites por contenedor individual | Un pod sin limits puede consumir todo su nodo |

### Paso 5.3: RBAC por equipo

```yaml
# manifests/rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: team-frontend-dev
  namespace: frontend
rules:
  - apiGroups: ["", "apps", "networking.k8s.io"]
    resources: ["pods", "deployments", "services", "ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-frontend-binding
  namespace: frontend
subjects:
  - kind: Group
    name: team-frontend
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: team-frontend-dev
  apiGroup: rbac.authorization.k8s.io
```

El equipo `team-frontend` puede hacer deploy en `frontend` pero no tiene acceso
a `backend` ni `database`. El namespace es la frontera real.

---

## Troubleshooting

| Síntoma                                   | Causa probable                              | Fix                                                   |
| ----------------------------------------- | ------------------------------------------- | ----------------------------------------------------- |
| Pods no resuelven DNS tras default-deny   | Egress a kube-dns bloqueado                 | Agregar egress rule para UDP/53 a `k8s-app: kube-dns` |
| NetworkPolicy no bloquea nada             | VPC CNI sin `ENABLE_NETWORK_POLICY=true`    | Verificar env vars del daemonset aws-node             |
| "Too many pods" pero hay CPU/mem libre    | Límite de IPs por ENI                       | Habilitar prefix delegation                           |
| Pod con SG for Pods no tiene conectividad | Branch ENI no creado (instancia no soporta) | Solo funciona en Nitro instances                      |
| ResourceQuota bloquea deploys             | Namespace excedió el total                  | `kubectl describe quota -n <ns>`                      |
| Pod rechazado por LimitRange              | Requests/limits fuera del rango min-max     | Ajustar el spec del contenedor                        |

---

## 🔴 Destruir recursos del lab

```bash
# Borrar namespaces (borra todo lo que contienen)
kubectl delete namespace frontend backend database

# Si habilitaste prefix delegation y quieres revertir:
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=false \
  WARM_PREFIX_TARGET-

# El cluster y VPC se borran con el destroy del lab base
```

---

## Lecciones aprendidas

1. **Sin default-deny, las NetworkPolicies son decorativas.** Si solo creas allow
   rules sin el deny base, el tráfico no cubierto sigue pasando. Es como un
   firewall que permite todo por defecto.

2. **El DNS es prerrequisito.** Cuando pones default-deny con egress, lo primero
   que se rompe es la resolución DNS. Siempre incluye una regla para `kube-dns`
   UDP/53.

3. **Los límites de pods por nodo son un problema de red, no de compute.** En EKS
   con VPC CNI, cada pod consume una IP real. Si tu instancia solo soporta 17 IPs,
   solo caben 17 pods — da igual cuánta CPU tenga.

4. **El namespace es una frontera de seguridad real si lo configuras.** Con RBAC +
   ResourceQuota + LimitRange + NetworkPolicy + default-deny, un namespace se
   convierte en un tenant seguro. Sin eso, es solo una carpeta.

5. **NetworkPolicy ≠ Security Group.** Son complementarios: NetworkPolicy aísla
   dentro del cluster, Security Groups protegen hacia AWS. Para un pod que habla
   con RDS, necesitas ambos.
