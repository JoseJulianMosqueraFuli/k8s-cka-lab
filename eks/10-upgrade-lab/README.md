# Lab 10: Upgrade sin downtime — in-place vs blue/green

## Resumen

Un upgrade de EKS no es un botón. Es una secuencia con orden estricto (control
plane → node groups → add-ons), preparación previa (APIs deprecadas, PDBs,
compatibilidad), y una asimetría fundamental: el control plane NO se puede
downgrade. Aquí practicas ambas estrategias: in-place (barato, sin rollback real)
y blue/green (caro, con rollback verdadero).

**Se monta sobre:** el cluster del lab 02 (EC2) o uno creado con Terraform (lab 09).
**Costo estimado adicional:** ~$0.20/hr para blue/green (segundo cluster temporal)
**Tiempo:** ~2h 30m

**Herramientas necesarias:**

- AWS CLI v2
- kubectl
- eksctl o terraform
- kubectl-convert (plugin)
- pluto (detector de APIs deprecadas)

**Conexión CKA:** `domains/01-cluster-architecture` — cluster upgrades, maintenance (25%)

---

## El principio fundamental

```
┌─────────────────────────────────────────────────────────┐
│  EKS Control Plane: SOLO PUEDE SUBIR de versión.       │
│  1.29 → 1.30 ✓                                         │
│  1.30 → 1.29 ✗ (IMPOSIBLE)                            │
│                                                         │
│  Esta asimetría justifica toda la preparación.          │
└─────────────────────────────────────────────────────────┘
```

Si algo sale mal después del upgrade del control plane, tu única opción con
in-place es "arreglar hacia adelante". Blue/green te da un rollback real:
apuntar el tráfico de vuelta al cluster viejo.

---

## Preparación (80% del trabajo)

### Paso 1: Detectar APIs deprecadas

```bash
# Instalar pluto
# https://github.com/FairwindsOps/pluto/releases
curl -L https://github.com/FairwindsOps/pluto/releases/latest/download/pluto_linux_amd64.tar.gz | tar xz
sudo mv pluto /usr/local/bin/

# Escanear el cluster
pluto detect-all-in-cluster --target-versions k8s=v1.30
```

Ejemplo de output:

```
NAME                          KIND                VERSION          REPLACEMENT        REMOVED   DEPRECATED
my-ingress                    Ingress             networking/v1beta1  networking.k8s.io/v1  true      true
my-pdb                        PodDisruptionBudget policy/v1beta1     policy/v1             true      true
```

### ¿Por qué es crítico?

Si un manifiesto usa una API que ya no existe en la nueva versión:

- No podrás crear ni modificar ese recurso después del upgrade
- Los objetos existentes siguen funcionando (stored version) pero no se pueden editar
- Argo CD marcará "OutOfSync" pero no podrá sincronizar

### Paso 2: Convertir manifiestos deprecados

```bash
# Instalar kubectl-convert
kubectl krew install convert 2>/dev/null || \
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl-convert"

# Convertir un manifiesto
kubectl convert -f old-ingress.yaml --output-version networking.k8s.io/v1
```

### Paso 3: Verificar compatibilidad de add-ons

```bash
CLUSTER_NAME=eks-ec2-lab
REGION=us-east-1
TARGET_VERSION="1.30"

# Ver add-ons actuales y sus versiones
aws eks list-addons --cluster-name $CLUSTER_NAME --region $REGION --output text

for ADDON in $(aws eks list-addons --cluster-name $CLUSTER_NAME --region $REGION --output text | tr '\t' '\n'); do
  echo "=== $ADDON ==="
  CURRENT=$(aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name $ADDON \
    --region $REGION --query "addon.addonVersion" --output text)
  echo "  Current: $CURRENT"

  COMPATIBLE=$(aws eks describe-addon-versions --addon-name $ADDON \
    --kubernetes-version $TARGET_VERSION --region $REGION \
    --query "addons[0].addonVersions[0].addonVersion" --output text)
  echo "  Compatible with $TARGET_VERSION: $COMPATIBLE"
done
```

### Paso 4: Verificar PDBs

```bash
# PDBs que podrían bloquear el drain durante el upgrade de nodos
kubectl get pdb -A -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
MIN_AVAILABLE:.spec.minAvailable,\
MAX_UNAVAILABLE:.spec.maxUnavailable,\
ALLOWED_DISRUPTIONS:.status.disruptionsAllowed

# Si disruptionsAllowed = 0, el upgrade de nodos se quedará colgado
```

### Paso 5: Verificar IPs libres en subnets

```bash
# El upgrade del control plane necesita hasta 5 IPs libres (para los nuevos ENIs del API server)
SUBNET_IDS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text)

for SUBNET in $SUBNET_IDS; do
  AVAILABLE=$(aws ec2 describe-subnets --subnet-ids $SUBNET --region $REGION \
    --query "Subnets[0].AvailableIpAddressCount" --output text)
  echo "$SUBNET: $AVAILABLE IPs available"
done

# Si alguna subnet tiene < 5 IPs, el upgrade puede fallar
```

### Checklist pre-upgrade

| Verificación                   | Comando/herramienta       | Riesgo si no se hace                   |
| ------------------------------ | ------------------------- | -------------------------------------- |
| APIs deprecadas                | `pluto detect-all`        | Manifiestos no editables post-upgrade  |
| Compatibilidad add-ons         | `describe-addon-versions` | CoreDNS CrashLoop (lab 08 escenario 5) |
| PDBs restrictivos              | `kubectl get pdb`         | Drain se cuelga, upgrade no termina    |
| IPs libres en subnets          | `describe-subnets`        | Control plane upgrade falla            |
| Aplicaciones con health checks | Review de deploys         | Pods marked unhealthy during rollout   |
| Backup (Velero o similar)      | `velero backup create`    | Sin rollback de datos                  |

---

## Estrategia A: Upgrade In-Place

### El orden es estricto

```
1. Control Plane (1.29 → 1.30)    ← ~20 min, no hay downtime del API server
2. Node Groups (1.29 → 1.30)      ← rolling update, respeta PDBs
3. Add-ons (actualizar versiones)  ← puede requerir restart de pods
```

**NUNCA** saltes pasos ni inviertas el orden. Los nodos no pueden estar en una
versión MAYOR que el control plane (n+1 nodes con n control plane está prohibido).

### Paso A.1: Upgrade del control plane

```bash
# Verificar versión actual
aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query "cluster.version" --output text
# "1.29"

# Iniciar upgrade
aws eks update-cluster-version \
  --name $CLUSTER_NAME \
  --kubernetes-version "1.30" \
  --region $REGION

# Esperar (~15-25 minutos)
aws eks wait cluster-active --name $CLUSTER_NAME --region $REGION
echo "Control plane upgrade complete"

# Verificar
aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query "cluster.version" --output text
# "1.30"
```

### ¿Qué pasa durante el upgrade del control plane?

- El API server sigue disponible (EKS lo actualiza rolling)
- Puede haber latencia breve (~1-2 min) en las respuestas de la API
- Los workloads siguen corriendo sin interrupción
- `kubectl` sigue funcionando

### Paso A.2: Upgrade de node groups

```bash
# Listar node groups
aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $REGION

NODEGROUP=workers

# Iniciar upgrade del node group
aws eks update-nodegroup-version \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $NODEGROUP \
  --kubernetes-version "1.30" \
  --region $REGION

# Esto hace un rolling update:
# 1. Lanza nuevos nodos con la nueva AMI
# 2. Cordons los nodos viejos
# 3. Drains los pods (respetando PDBs)
# 4. Termina los nodos viejos
```

### Observar el rolling update

```bash
# En otra terminal, observar nodos
kubectl get nodes -w
# Verás: nuevos nodos aparecen, viejos se marcan SchedulingDisabled, luego desaparecen

# Verificar que los pods se re-schedulean
kubectl get pods -A -o wide | grep -v Running
```

### Paso A.3: Upgrade de add-ons

```bash
# CoreDNS
aws eks update-addon --cluster-name $CLUSTER_NAME --addon-name coredns \
  --addon-version $(aws eks describe-addon-versions --addon-name coredns \
    --kubernetes-version "1.30" --region $REGION \
    --query "addons[0].addonVersions[0].addonVersion" --output text) \
  --resolve-conflicts OVERWRITE --region $REGION

# kube-proxy
aws eks update-addon --cluster-name $CLUSTER_NAME --addon-name kube-proxy \
  --addon-version $(aws eks describe-addon-versions --addon-name kube-proxy \
    --kubernetes-version "1.30" --region $REGION \
    --query "addons[0].addonVersions[0].addonVersion" --output text) \
  --resolve-conflicts OVERWRITE --region $REGION

# VPC CNI
aws eks update-addon --cluster-name $CLUSTER_NAME --addon-name vpc-cni \
  --addon-version $(aws eks describe-addon-versions --addon-name vpc-cni \
    --kubernetes-version "1.30" --region $REGION \
    --query "addons[0].addonVersions[0].addonVersion" --output text) \
  --resolve-conflicts OVERWRITE --region $REGION
```

### ¿Qué significa `--resolve-conflicts OVERWRITE`?

Si manualmente modificaste la configuración de un add-on (por ejemplo, editaste el
ConfigMap de CoreDNS), este flag sobreescribe tus cambios. Alternativas:

| Flag        | Comportamiento                                   |
| ----------- | ------------------------------------------------ |
| `NONE`      | Falla si hay conflictos (seguro pero manual)     |
| `OVERWRITE` | Sobreescribe cambios custom (rápido pero brusco) |
| `PRESERVE`  | Mantiene tus cambios custom donde sea posible    |

---

## Estrategia B: Upgrade Blue/Green

### ¿Cuándo elegir blue/green?

- Aplicaciones críticas donde 0 downtime es mandatorio
- Necesitas rollback instantáneo (no "arreglar hacia adelante")
- Tienes IaC (lab 09) que permite clonar el cluster
- El costo temporal de 2 clusters es aceptable

### El flujo

```
1. Cluster BLUE (1.29) — producción actual
2. Crear Cluster GREEN (1.30) con misma IaC
3. Desplegar apps en GREEN (Argo CD sync al nuevo cluster)
4. Validar en GREEN (smoke tests, canary)
5. Migrar tráfico: DNS/ALB → GREEN
6. Observar 24-48h
7. Destruir BLUE
```

### Paso B.1: Crear el cluster GREEN con Terraform

```hcl
# infra/terraform/green/main.tf
# Copia de la configuración del cluster BLUE pero con:
variable "cluster_name" {
  default = "eks-green-lab"  # Nombre distinto
}

variable "cluster_version" {
  default = "1.30"  # Nueva versión
}
```

```bash
cd infra/terraform/green
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Actualizar kubeconfig
aws eks update-kubeconfig --name eks-green-lab --region $REGION --alias green
```

### Paso B.2: Desplegar apps en GREEN

```bash
# Si usas Argo CD, agrega el nuevo cluster como destino
argocd cluster add green --name green-cluster

# Crear Applications apuntando a GREEN
# O simplemente: desplegar los mismos manifiestos
kubectl --context green apply -f gitops-repo/apps/
```

### Paso B.3: Migrar tráfico

```bash
# Opción 1: DNS weighted routing (Route 53)
# Cambiar peso gradualmente: BLUE 90% → GREEN 10% → ... → GREEN 100%

# Opción 2: ALB con target groups
# Registrar pods de GREEN en el mismo target group del ALB existente

# Opción 3: External DNS con switch
# Cambiar el registro DNS de BLUE_ALB a GREEN_ALB
```

### Paso B.4: Rollback si algo falla

```bash
# Simplemente apuntar tráfico de vuelta a BLUE
# El cluster BLUE sigue intacto en 1.29

# Si todo va bien después de 24-48h:
cd infra/terraform/blue
terraform destroy -auto-approve
```

### Comparación de estrategias

| Aspecto           | In-Place                           | Blue/Green                       |
| ----------------- | ---------------------------------- | -------------------------------- |
| **Costo**         | Sin costo extra                    | ~2x durante la migración         |
| **Tiempo total**  | ~45 min - 1h                       | ~2-4h (incluye validación)       |
| **Rollback**      | No existe (solo fix forward)       | Instantáneo (switch tráfico)     |
| **Complejidad**   | Baja (secuencia lineal)            | Alta (IaC, DNS, state migration) |
| **Downtime**      | Mínimo (~segundos durante drain)   | Zero (switch atómico)            |
| **Requisito IaC** | No estrictamente                   | Sí (necesitas clonar el cluster) |
| **Mejor para**    | Clusters no-prod, equipos pequeños | Producción crítica               |

---

## PDB en acción durante el upgrade

### Deploy con PDB correcto

```yaml
# manifests/pdb-upgrade-test.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: upgrade-test
  namespace: default
spec:
  replicas: 4
  selector:
    matchLabels:
      app: upgrade-test
  template:
    metadata:
      labels:
        app: upgrade-test
    spec:
      containers:
        - name: app
          image: nginx:alpine
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: upgrade-test-pdb
spec:
  maxUnavailable: 1 # Solo 1 pod puede estar abajo a la vez
  selector:
    matchLabels:
      app: upgrade-test
```

### ¿Qué pasa durante el drain de nodos?

```
Nodo A: [pod-1] [pod-2]     Nodo B: [pod-3] [pod-4]

1. Drain Nodo A:
   - Intenta evict pod-1 → PDB permite (solo 1 unavailable) → evicted
   - Espera a que pod-1 sea rescheduled en Nodo B → Running
   - Intenta evict pod-2 → PDB permite → evicted
   - Nodo A vacío → terminated

2. Nuevo Nodo C (1.30) se une
3. Drain Nodo B: mismo proceso
```

### PDB demasiado estricto bloquea el upgrade

```yaml
# ESTO BLOQUEA EL UPGRADE:
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: too-strict
spec:
  minAvailable: 4 # Con 4 réplicas, 0 disruptions allowed
  selector:
    matchLabels:
      app: upgrade-test
```

```bash
# El node group update se queda colgado:
# "Nodegroup update failed: PodEvictionFailure"

# Fix: relajar el PDB antes del upgrade
kubectl patch pdb too-strict -p '{"spec":{"minAvailable": 3}}'
```

---

## Troubleshooting

| Síntoma                                   | Causa probable                               | Fix                                               |
| ----------------------------------------- | -------------------------------------------- | ------------------------------------------------- |
| Control plane upgrade falla con "subnet"  | < 5 IPs libres en las subnets                | Liberar IPs o agregar subnets al cluster          |
| Node group update stuck > 30 min          | PDB bloqueando evictions                     | `kubectl get pdb` → relajar minAvailable          |
| Pods en CrashLoop después del upgrade     | Add-on incompatible con nueva versión        | Actualizar add-ons al paso 3                      |
| `kubectl` devuelve errores de API version | Manifiesto usa API removida en nueva versión | Usar `kubectl convert` o actualizar el YAML       |
| Nodos nuevos en NotReady                  | AMI no compatible o user-data error          | `kubectl describe node` → verificar condiciones   |
| Tráfico se pierde en blue/green           | DNS TTL aún apunta al cluster viejo          | Usar TTL bajo (60s) antes de empezar la migración |

---

## 🔴 Destruir recursos del lab

```bash
# Si hiciste in-place: no hay nada extra que destruir
# El cluster sigue vivo en la nueva versión

# Si hiciste blue/green:
# Destruir el cluster que ya no se usa (BLUE después de migrar, o GREEN si rollback)
cd infra/terraform/green  # o blue
terraform destroy -auto-approve

# Limpiar PDBs y deploys de prueba
kubectl delete deploy upgrade-test
kubectl delete pdb upgrade-test-pdb too-strict 2>/dev/null
```

---

## Lecciones aprendidas

1. **El upgrade del control plane no se puede deshacer.** Una vez que EKS pasa
   de 1.29 a 1.30, no hay vuelta atrás. Toda la preparación (APIs, add-ons,
   PDBs, IPs) existe para evitar tener que "rollback" algo que no se puede
   rollback.

2. **El orden importa: control plane → nodes → add-ons.** Los nodos pueden estar
   una versión minor por debajo del control plane (n-1), pero nunca por encima.
   Los add-ons deben ser compatibles con la versión del control plane.

3. **PDBs son amigos del upgrade si están bien configurados.** Un PDB con
   `maxUnavailable: 1` y réplicas suficientes permite drain sin downtime. Un PDB
   con `minAvailable >= replicas` bloquea todo.

4. **Blue/green solo es viable con IaC.** No puedes "clonar" un cluster creado
   a mano. Si tu infra no es código (lab 09), tu única opción es in-place.

5. **La preparación es el 80% del trabajo.** El `aws eks update-cluster-version`
   en sí toma 20 minutos. Las 2 horas anteriores de verificación de APIs,
   add-ons, PDBs y backups son lo que determina si esos 20 minutos van bien o
   se convierten en un incidente.

6. **pluto te salva de sorpresas.** Una API deprecada que no detectaste se
   convierte en un manifiesto no-editable post-upgrade. El recurso sigue
   funcionando pero no puedes actualizarlo — una bomba de tiempo.
