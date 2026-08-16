# Lab Manual: EKS Auto Mode en Virginia (us-east-1)

## Resumen
Cluster EKS con Auto Mode — AWS gestiona todo: nodos, escalado, LB Controller, storage drivers.
Tú solo despliegas pods. Es la forma más nueva y simple de usar EKS.
Todo desde la consola de AWS + CLI.

**Costo estimado:** ~$0.15-0.25/hr (EKS $0.10 + EC2 instancias que Auto Mode lance + ~12% management fee)

**Herramientas necesarias en tu PC:**
- AWS CLI v2
- kubectl

**NO necesitas:** eksctl, helm (Auto Mode incluye lo que normalmente instalas con ellos)

---

## ¿Qué es EKS Auto Mode?

Es un **modo de operación del cluster** lanzado en re:Invent 2024 donde AWS toma control
de casi toda la infraestructura:

```
┌─────────────────────────────────────────────────────────────┐
│                   SIN Auto Mode (EC2/Fargate)                │
│                                                             │
│  Tú gestionas:                                              │
│  ├─ Node Groups / Fargate Profiles                          │
│  ├─ AWS Load Balancer Controller (Helm + OIDC + IAM)        │
│  ├─ EBS CSI Driver (para volúmenes persistentes)            │
│  ├─ Cluster Autoscaler o Karpenter                          │
│  ├─ VPC CNI config                                          │
│  └─ Actualizaciones de nodos                                │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   CON Auto Mode                              │
│                                                             │
│  AWS gestiona:                                              │
│  ├─ Nodos (EC2 con Bottlerocket, invisibles para ti)        │
│  ├─ Escalado automático (basado en Karpenter)               │
│  ├─ Load Balancing (ALB/NLB integrado)                      │
│  ├─ Storage (EBS CSI incluido)                              │
│  ├─ Pod networking + Network Policies                       │
│  ├─ Pod Identity Agent                                      │
│  └─ Actualizaciones automáticas (máx 21 días de vida/nodo)  │
│                                                             │
│  Tú solo:                                                   │
│  ├─ Despliegas pods                                         │
│  └─ Configuras Ingress/Services                             │
└─────────────────────────────────────────────────────────────┘
```

### ¿Cómo funciona por debajo?

Auto Mode usa **EC2 por debajo** (no Fargate). La diferencia es:
- Las instancias las elige y lanza AWS automáticamente (usando Karpenter)
- Corren Bottlerocket (SO mínimo para contenedores, no Amazon Linux)
- No puedes hacer SSH ni SSM a ellas
- AWS las actualiza y rota automáticamente cada 21 días máximo
- Desde abril 2026, estas instancias están ocultas en la consola EC2 por defecto

### ¿Karpenter? ¿Qué es?

Karpenter es un autoscaler de nodos (open source, creado por AWS). A diferencia del
Cluster Autoscaler clásico que trabaja con Auto Scaling Groups, Karpenter:
- Observa pods en Pending
- Calcula la instancia más eficiente para correrlos
- La lanza directamente (sin ASG intermediario)
- Consolida workloads si hay nodos subutilizados

En Auto Mode, Karpenter viene integrado. No lo instalas ni configuras.
AWS expone su funcionalidad via **NodePools** y **NodeClasses**.

### Pricing: ¿Cuánto más cuesta?

| Componente | Precio |
|------------|--------|
| Cluster EKS | $0.10/hr (igual que siempre) |
| EC2 instances | Precio normal de EC2 |
| **Management fee (Auto Mode)** | ~12% sobre el precio EC2 de las instancias que lance |

Ejemplo: si Auto Mode lanza un c6a.2xlarge ($0.306/hr), pagas:
- $0.306 (EC2) + $0.037 (fee) = $0.343/hr por esa instancia

A cambio, te ahorras gestionar LB Controller, Karpenter, EBS CSI, updates de nodos, etc.

---

## Comparación: las 3 opciones

| | Fargate | EC2 (Managed Nodes) | Auto Mode |
|---|---|---|---|
| Nodos visibles | No | Sí (EC2 instances) | No (ocultas desde abril 2026) |
| Tipo de instancia | No aplica | Tú eliges | AWS elige la óptima |
| LB Controller | Lo instalas tú | Opcional | Incluido |
| Storage (EBS) | No soporta EBS | Instalas EBS CSI Driver | Incluido |
| Escalado | Por pod (auto) | Manual/Cluster Autoscaler | Karpenter (auto) |
| SSH a nodos | No | Sí | No |
| Actualizaciones | N/A | Tú las aplicas | Automáticas (21 días máx) |
| Network Policies | Limitado | Instalas Calico o Cilium | Incluido |
| Complejidad setup | Alta | Media | Baja |

---

## Paso 1: Crear IAM Roles

Auto Mode necesita **2 roles** con policies diferentes a las de EC2/Fargate.

IAM → Roles → Create role

### Rol 1: Cluster Role (Auto Mode)

Este rol tiene MÁS permisos que el cluster role normal porque Auto Mode
necesita gestionar EC2, EBS, ELB, etc. en tu nombre.

1. Trusted entity type: **Custom trust policy**
2. Pegar:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
```

**Nota:** A diferencia del rol clásico, este incluye `sts:TagSession`.
Auto Mode usa session tags para rastrear qué recursos creó en tu cuenta.

3. Next → buscar y marcar estas policies:
   - **AmazonEKSClusterPolicy** — permisos base del cluster
   - **AmazonEKSComputePolicy** — gestionar instancias EC2 (lanzar, terminar)
   - **AmazonEKSBlockStoragePolicy** — gestionar volúmenes EBS
   - **AmazonEKSLoadBalancingPolicy** — crear y gestionar ALB/NLB
   - **AmazonEKSNetworkingPolicy** — gestionar ENIs y networking de pods

4. Role name: `eks-automode-lab-cluster-role` → Create role

#### ¿Por qué tantas policies?

En el modo clásico (EC2/Fargate), TÚ instalas cada controller y le das permisos
individualmente (LB Controller con su IAM role, EBS CSI con otro, etc.).

En Auto Mode, el CLUSTER MISMO hace todo eso. Por eso el cluster role necesita
todos esos permisos directamente.

### Rol 2: Node Role (Auto Mode)

Las instancias que Auto Mode lanza necesitan un rol mínimo.

1. Trusted entity type: **Custom trust policy**
2. Pegar:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```
3. Next → buscar y marcar:
   - **AmazonEKSWorkerNodeMinimalPolicy** — permisos mínimos para unirse al cluster
   - **AmazonEC2ContainerRegistryPullOnly** — descargar imágenes de ECR

**Nota:** Es `AmazonEKSWorkerNodeMinimalPolicy`, no `AmazonEKSWorkerNodePolicy`.
La "minimal" es específica de Auto Mode — tiene menos permisos porque el nodo
no necesita gestionar networking (eso lo hace el cluster role).

4. Role name: `eks-automode-lab-node-role` → Create role

---

## Paso 2: Crear VPC

1. VPC → Create VPC → **VPC and more**
2. Configurar:
   - Name tag: `automode-lab`
   - IPv4 CIDR: `10.0.0.0/16`
   - Number of AZs: **2**
   - Public subnets: **2**
   - Private subnets: **2**
   - NAT gateways: **In 1 AZ**
   - VPC endpoints: None
3. Create VPC

---

## Paso 3: Crear Cluster con Auto Mode

Hay dos caminos en la consola:
- **Quick configuration** — todo automático, AWS crea roles y VPC por ti
- **Custom configuration** — tú controlas cada parámetro

Usamos **Custom configuration** porque ya creamos los roles y VPC manualmente
(para entender qué hay por debajo).

### Opción A: Custom Configuration (recomendada para aprender)

1. EKS → Add cluster → Create
2. Configuration: **Configuración personalizada**
3. **Activar "Utilizar el modo automático de EKS"** ✅
4. Configurar:
   - Nombre: `automode-lab-cluster`
   - Rol del cluster: `eks-automode-lab-cluster-role`
   - Versión Kubernetes: la más reciente (1.36)
   - Política de actualización: Soporte estándar
   - Nivel de escalado: NO activar
   - Acceso administrador: Permitir
   - Modo de autenticación: API de EKS
   - Cifrado de sobre: NO
   - Cambio de zona ARC: Desactivado
   - Protección contra eliminaciones: NO

5. **Configuración de Auto Mode** (aparece al activar Auto Mode):
   - Node role: `eks-automode-lab-node-role`
   - NodePools habilitados:
     - ✅ **general-purpose** — para workloads normales (instancias tipo M, C, R)
     - ✅ **system** — para pods del sistema (CoreDNS, etc.)
   - Estos son los "built-in NodePools". Puedes crear custom después.

6. Next → Networking:
   - VPC: `automode-lab-vpc`
   - Subnets: **las 4** (2 públicas + 2 privadas)
   - Security groups: dejar vacío
   - Cluster endpoint access: **Público y privado**
   - Modo de salida: Administrado por AWS

7. Next → Observability: **todo desactivado**

8. Next → Add-ons:
   - En Auto Mode, los add-ons principales vienen integrados y NO aparecen como add-ons separados.
   - No necesitas CoreDNS, VPC CNI, ni kube-proxy como add-ons — Auto Mode los gestiona.
   - Si ves algún add-on listado, déjalo con la configuración por defecto.

9. Next → Review → Create

⏱️ **Tarda ~10-12 minutos en quedar Active.**

### Opción B: Quick Configuration (más rápido, menos control)

Si prefieres la vía rápida:
1. EKS → Add cluster → Create
2. Confirmar **Quick configuration** seleccionado
3. Nombre: `automode-lab-cluster`
4. Versión: la más reciente
5. Cluster IAM Role: Usar "Create recommended role" (crea `AmazonEKSAutoClusterRole`)
6. Node IAM Role: Usar "Create recommended role" (crea `AmazonEKSAutoNodeRole`)
7. VPC: Seleccionar tu VPC o crear una nueva
8. Create cluster

La diferencia es que Quick config crea los roles por ti con nombres predefinidos.

---

## Paso 4: Dar acceso al cluster

1. EKS → automode-lab-cluster → **Access**
2. Create access entry
3. IAM principal: tu usuario de CLI
4. Policy: **`AmazonEKSClusterAdminPolicy`**
5. Scope: Cluster

---

## Paso 5: Conectar kubectl

```bash
aws eks update-kubeconfig --name automode-lab-cluster --region us-east-1
```

Verificar:
```bash
kubectl get nodes
```

**Posiblemente no veas nodos todavía.** ¿Por qué?

Auto Mode usa Karpenter: los nodos se crean **bajo demanda** cuando hay pods
que necesitan correr. Si no hay pods (aparte de los del sistema), puede que
solo veas 1-2 nodos chicos para CoreDNS y componentes internos.

Verificar pods del sistema:
```bash
kubectl get pods -n kube-system
```

Deberían estar todos en Running. Auto Mode se encarga de todo.

---

## Paso 6: Entender NodePools

Los NodePools son el equivalente de los Node Groups en Auto Mode, pero dinámicos.

```bash
kubectl get nodepools
```

Verás algo como:
```
NAME              NODECLASS
general-purpose   default
system            default
```

#### ¿Qué hace cada NodePool?

| NodePool | Propósito | Instancias que usa |
|----------|-----------|-------------------|
| `system` | Pods del sistema (CoreDNS, etc.) | Instancias pequeñas |
| `general-purpose` | Tus workloads | AWS elige la más cost-effective |

#### ¿Cómo decide Auto Mode qué instancia lanzar?

Karpenter analiza los requirements de tus pods (CPU, RAM, GPU) y busca
la instancia EC2 más barata que satisfaga esos requisitos. Puede elegir
entre cientos de tipos de instancia automáticamente.

Si tienes un pod que pide 0.5 CPU y 512MB RAM, no va a lanzar un m5.xlarge.
Lanzará algo mínimo o agrupará varios pods en una instancia.

---

## Paso 7: Desplegar nginx

```bash
# Crear namespace
kubectl create namespace apps

# Crear Deployment
kubectl create deployment nginx --image=nginx:alpine --replicas=2 -n apps
```

Observar:
```bash
kubectl get pods -n apps -w
```

Lo que pasa por debajo:
1. Los pods quedan en `Pending` (no hay nodo con espacio)
2. Karpenter detecta los pods Pending (~5 seg)
3. Karpenter elige el tipo de instancia óptimo
4. Lanza la instancia EC2 (~30-60 seg)
5. El nodo se une al cluster
6. Los pods se schedulearon y pasan a `Running`

**Primera vez tarda ~1-2 min** (cold start del nodo). Después, si hay espacio
en nodos existentes, los pods inician en segundos.

```bash
kubectl get nodes
# Ahora deberías ver un nodo nuevo que Auto Mode creó para tus pods
```

---

## Paso 8: Exponer nginx con un Load Balancer

### ¡No necesitas instalar nada! El LB Controller ya está integrado.

Auto Mode incluye el AWS Load Balancer Controller como componente del cluster.
No necesitas OIDC, ni Helm, ni IAM policies adicionales.

Crea el archivo `nginx-service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: apps
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
```

```bash
kubectl apply -f nginx-service.yaml
```

Esperar ~2-3 min:
```bash
kubectl get svc nginx -n apps
```

El `EXTERNAL-IP` es la URL del NLB. Ábrelo en el navegador → nginx welcome page.

#### ¿Por qué en Auto Mode sí necesitas las anotaciones?

Las anotaciones le dicen al LB Controller integrado QUÉ tipo de LB crear.
Sin anotaciones, podría crear un CLB legacy. Con `nlb` + `ip` + `internet-facing`
le dices exactamente: "crea un NLB público con targets IP".

#### ¿Y ALB (Application Load Balancer)?

Si quieres un ALB (para routing HTTP por path/host), usas un Ingress:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  namespace: apps
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx
                port:
                  number: 80
```

Esto crea un ALB automáticamente. Todo sin instalar Helm ni nada.

---

## Paso 9: Observar el auto-scaling

Vamos a ver cómo Auto Mode escala automáticamente.

```bash
# Escalar a 10 réplicas
kubectl scale deployment nginx --replicas=10 -n apps
```

Observar:
```bash
kubectl get pods -n apps -w
kubectl get nodes -w  # en otra terminal
```

Verás que Auto Mode lanza más nodos automáticamente para acomodar los 10 pods.
Cuando reduces las réplicas, después de unos minutos consolida y elimina nodos vacíos.

```bash
# Reducir a 2 réplicas
kubectl scale deployment nginx --replicas=2 -n apps
```

Espera ~5-10 min y verás que Auto Mode termina los nodos que ya no necesita.
Esto es **Karpenter consolidation** — optimiza costos automáticamente.

---

## Paso 10: (Bonus) Volúmenes persistentes

Auto Mode incluye el EBS CSI Driver. Puedes crear PVCs directamente:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: apps
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl apply -f test-pvc.yaml
kubectl get pvc -n apps
```

En EC2/Fargate clásico, tendrías que instalar el EBS CSI Driver manualmente
(con OIDC + IAM role + Helm). En Auto Mode ya está listo.

---

## Conceptos clave

### NodePool vs NodeClass

| Concepto | Qué define | Ejemplo |
|----------|-----------|---------|
| **NodePool** | Restricciones de scheduling (qué pods van a qué nodos) | "Nodos para workloads general-purpose" |
| **NodeClass** | Configuración de la infra (AMI, subnets, storage) | "Usar subnets privadas, disco gp3 de 50GB" |

Los NodePools built-in (`general-purpose`, `system`) usan la NodeClass `default`.
Puedes crear custom NodePools si necesitas nodos GPU, nodos Spot, etc.

### ¿Por qué los nodos están ocultos?

Desde abril 2026, las instancias de Auto Mode no aparecen en la consola EC2 por defecto.
AWS las considera "managed instances" — tú no deberías interactuar con ellas directamente.
Puedes cambiar esto en la configuración de visibilidad de recursos administrados.

### Límites de Auto Mode

| Lo que NO puedes hacer | Alternativa |
|------------------------|-------------|
| SSH/SSM a los nodos | Usar `kubectl exec` para entrar a los pods |
| Instalar software en los nodos | Usar DaemonSets o sidecars |
| Elegir AMI custom | Crear un NodeClass custom (limitado a Bottlerocket) |
| Usar instancias GPU específicas | Crear un NodePool custom con constraints |
| Mantener nodos más de 21 días | No hay alternativa — es un requisito de seguridad |

---

## Errores comunes y soluciones

| Error | Causa | Solución |
|-------|-------|----------|
| Cluster role error al crear | Faltan policies (Compute, Storage, etc.) | Agregar las 5 policies al cluster role |
| "insufficient permissions" en cluster role | Falta `sts:TagSession` en trust policy | Agregar `sts:TagSession` a la trust policy |
| Pods en Pending por mucho tiempo | NodePool no matchea los requirements del pod | Verificar labels/taints del NodePool con `kubectl describe nodepool` |
| LB no se crea | Subnets no taggeadas correctamente | Auto Mode debería taggearlas, pero verificar tags `kubernetes.io/role/elb` en públicas |
| Nodos no se crean | Problemas de cuota EC2 o subnet sin IPs | Verificar Service Quotas y CIDR de subnets |

---

## 🔴 Destruir todo

Auto Mode hace la destrucción más simple porque hay menos cosas que creaste manualmente.
**No necesitas eliminar OIDC providers, Helm releases, ni service accounts IAM.**

### Ejecutar script de destrucción:

```powershell
.\destroy.ps1
```

El script se ejecuta de corrido sin intervención manual. Usa `aws eks wait` para
esperar a que los recursos se eliminen antes de continuar al siguiente paso.

---

## Lecciones aprendidas

1. **Auto Mode es el futuro de EKS** — AWS lo recomienda como método preferido para nuevos clusters.
   Elimina toda la complejidad de gestionar controllers, drivers, y nodos.

2. **Pero pierdes control** — no puedes hacer SSH, no eliges AMI, los nodos rotan cada 21 días.
   Para la mayoría de workloads esto está bien. Para casos edge (GPU custom, compliance especial)
   puede que necesites EC2 managed nodes.

3. **El pricing incluye un ~12% extra** — a cambio de que AWS gestione todo.
   Para equipos pequeños sin expertise en Kubernetes, esto es un ahorro neto
   (pagarías más en horas-ingeniero gestionando todo manualmente).

4. **Puedes mezclar** — un cluster puede tener Auto Mode + Managed Node Groups.
   Useful si necesitas Auto Mode para lo general y nodos custom para algo específico.

5. **La creación del cluster es casi idéntica** — la diferencia está en qué pasa DESPUÉS:
   con Auto Mode no instalas nada más. Con EC2/Fargate, el trabajo apenas empieza
   después de crear el cluster.

---

## Resumen: ¿Cuándo usar cada opción?

| Usa... | Cuando... |
|--------|-----------|
| **Fargate** | Quieres serverless puro, pods esporádicos, no quieres pagar por nodos idle |
| **EC2 (Managed Nodes)** | Necesitas control total: SSH, AMIs custom, GPUs específicas, compliance estricto |
| **Auto Mode** | Quieres la simplicidad de Fargate con la flexibilidad de EC2, sin gestionar nada |
