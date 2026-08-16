# Lab Manual: EKS + EC2 Managed Node Groups en Virginia (us-east-1)

## Resumen
Cluster EKS con nodos EC2 (Managed Node Group), desplegar nginx público.
Es el camino más clásico y sencillo: no necesitas instalar AWS LB Controller para lo básico.
Todo desde la consola de AWS + CLI.

**Costo estimado:** ~$0.20/hr (EKS $0.10 + 2x t3.medium $0.0416 cada una + NAT $0.045)

**Herramientas necesarias en tu PC:**
- AWS CLI v2
- kubectl
- eksctl (opcional, pero útil)

---

## Diferencias clave con Fargate

| Aspecto | Fargate | EC2 (este lab) |
|---------|---------|----------------|
| Nodos | No existen (invisible) | Instancias EC2 que puedes ver en la consola EC2 |
| Escalado | Automático por pod | Manual (o con Cluster Autoscaler) |
| LB Controller | Obligatorio | Opcional — funciona sin él usando el cloud-controller-manager integrado |
| Cold start | 30-60 seg por pod | Pods inician en segundos (nodo ya existe) |
| SSH a nodos | No | Sí (si configuras key pair) |
| Fargate Profiles | Necesarios | No aplica |
| Costo | Por vCPU+RAM del pod | Por instancia EC2 completa (aunque no la llenes de pods) |

---

## Paso 1: Crear IAM Roles

Necesitas **2 roles**: uno para el cluster y otro para los nodos EC2.

IAM → Roles → Create role

### Rol 1: Cluster EKS
Igual que en Fargate — el cluster necesita un rol para gestionar recursos.

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
      "Action": "sts:AssumeRole"
    }
  ]
}
```
3. Next → buscar y marcar **AmazonEKSClusterPolicy** → Next
4. Role name: `eks-ec2-lab-cluster-role` → Create role

### Rol 2: Nodos EC2 (Node Role)

Este rol es diferente al de Fargate. Los nodos EC2 necesitan permisos para:
- Registrarse en el cluster (`AmazonEKSWorkerNodePolicy`)
- Descargar imágenes de ECR (`AmazonEC2ContainerRegistryPullOnly`)
- Gestionar interfaces de red para pods (`AmazonEKS_CNI_Policy`)

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
3. Next → buscar y marcar estas **3 policies**:
   - **AmazonEKSWorkerNodePolicy** — permite al nodo comunicarse con el API server de EKS
   - **AmazonEC2ContainerRegistryPullOnly** — permite descargar imágenes Docker de ECR
   - **AmazonEKS_CNI_Policy** — permite al VPC CNI plugin asignar IPs a los pods
4. Role name: `eks-ec2-lab-node-role` → Create role

#### ¿Por qué el trusted entity es `ec2.amazonaws.com`?

Porque los nodos son instancias EC2. Cuando una instancia EC2 arranca,
puede "asumir" el rol que tiene asignado via su Instance Profile.
Es como decir "confío en que cualquier instancia EC2 pueda usar este rol".

#### ¿Por qué en Fargate era `eks-fargate-pods.amazonaws.com`?

Porque en Fargate no hay instancias EC2. El servicio de Fargate es quien
ejecuta los pods directamente, así que es el servicio `eks-fargate-pods`
quien necesita asumir el rol.

---

## Paso 2: Crear VPC

Misma VPC que en Fargate. EC2 nodes pueden correr en subnets públicas o privadas,
pero lo recomendado es privadas con NAT.

1. VPC → Create VPC → **VPC and more**
2. Configurar:
   - Name tag: `ec2-lab`
   - IPv4 CIDR: `10.0.0.0/16`
   - Number of AZs: **2**
   - Public subnets: **2**
   - Private subnets: **2**
   - NAT gateways: **In 1 AZ**
   - VPC endpoints: None
3. Create VPC

**¿Pueden los nodos EC2 ir en subnets públicas?** Sí, pero:
- Cada nodo obtiene una IP pública (expuesta a internet)
- Los pods también quedan más expuestos
- En producción siempre se usan privadas

Para este lab usamos privadas (igual que Fargate) por buenas prácticas.

---

## Paso 3: Crear Cluster EKS

1. EKS → Add cluster → Create
2. Configuration: **Configuración personalizada**
3. **Desactivar "Utilizar el modo automático de EKS"**
4. Configurar:
   - Nombre: `ec2-lab-cluster`
   - Rol: `eks-ec2-lab-cluster-role`
   - Versión Kubernetes: la más reciente (1.36)
   - Política de actualización: Soporte estándar
   - Nivel de escalado: NO activar
   - Acceso administrador: Permitir
   - Modo de autenticación: API de EKS
   - Cifrado de sobre: NO
   - Cambio de zona ARC: Desactivado
   - Protección contra eliminaciones: NO
5. Next → Networking:
   - VPC: `ec2-lab-vpc`
   - Subnets: **las 4** (2 públicas + 2 privadas)
   - Security groups: dejar vacío (EKS crea uno automáticamente)
   - Cluster endpoint access: **Público y privado**
   - Modo de salida: Administrado por AWS
6. Next → Observability: **todo desactivado**
7. Next → Add-ons: los 3 básicos:
   - **CoreDNS**
   - **Amazon VPC CNI**
   - **kube-proxy**
8. Next → Review → Create

⏱️ **Tarda ~10 minutos en quedar Active.**

---

## Paso 4: Dar acceso al cluster

Si tu usuario de CLI es diferente al que creó el cluster:

1. EKS → ec2-lab-cluster → **Access**
2. Create access entry
3. IAM principal: tu usuario de CLI
4. Policy: **`AmazonEKSClusterAdminPolicy`**
5. Scope: Cluster

---

## Paso 5: Crear Managed Node Group

Este es el paso que reemplaza los Fargate Profiles. En vez de decir "corre pods
en Fargate", le dices "lanza instancias EC2 para correr pods".

EKS → ec2-lab-cluster → **Compute** → Node Groups → **Add node group**

### Configuración del Node Group:
1. **Configure node group:**
   - Name: `ec2-lab-nodes`
   - Node IAM role: `eks-ec2-lab-node-role`
   - Launch template: NO usar (dejar por defecto)
   - Labels: (dejar vacío)
   - Taints: (dejar vacío)
   - Tags: (dejar vacío)
   - Next

2. **Set compute and scaling configuration:**
   - AMI type: **Amazon Linux 2023 (AL2023_x86_64_STANDARD)**
   - Capacity type: **On-Demand** (para el lab; Spot es más barato pero puede interrumpirse)
   - Instance types: **t3.medium** (2 vCPU, 4 GB RAM — suficiente para un lab)
   - Disk size: **20 GiB**
   - Desired size: **2** (número actual de nodos)
   - Minimum size: **2**
   - Maximum size: **3** (para que el cluster pueda crecer si necesita)
   - Node auto repair: Activado (reemplaza nodos que fallen)
   - Next

3. **Specify networking:**
   - Subnets: las 2 **privadas** (recomendado)
   - Configure SSH access: Opcional — si quieres entrar por SSH selecciona un key pair
   - Next

4. **Review → Create**

⏱️ **Tarda ~3-5 minutos en crear las instancias y unirlas al cluster.**

#### ¿Qué es un Managed Node Group?

Es un grupo de instancias EC2 gestionado por EKS. EKS se encarga de:
- Crear las instancias con la AMI correcta (optimizada para EKS)
- Registrarlas automáticamente en el cluster
- Manejar actualizaciones del SO y Kubernetes version de los nodos
- Reemplazar nodos que fallen (drain + terminate + launch nuevo)

Tú solo defines: tipo de instancia, cantidad deseada/mín/máx, y subnets.

#### ¿Qué es AMI type?

AMI = Amazon Machine Image. Es la "imagen de disco" con la que arrancan las instancias.
Amazon Linux 2023 es la más reciente y recomendada. También puedes elegir Bottlerocket
(SO minimalista solo para contenedores) o Ubuntu.

#### ¿On-Demand vs Spot?

| Tipo | Precio | Riesgo |
|------|--------|--------|
| On-Demand | Precio completo (~$0.0416/hr para t3.medium) | Ninguno — la instancia es tuya |
| Spot | Hasta 90% de descuento | AWS puede quitártela con 2 min de aviso si necesita la capacidad |

Para un lab usa On-Demand. En producción se mezclan ambos.

---

## Paso 6: Conectar kubectl y verificar nodos

```bash
aws eks update-kubeconfig --name ec2-lab-cluster --region us-east-1
```

Verificar que los nodos se unieron:
```bash
kubectl get nodes
```

Debes ver algo como:
```
NAME                            STATUS   ROLES    AGE   VERSION
ip-10-0-1-50.ec2.internal      Ready    <none>   2m    v1.36.0-eks-...
ip-10-0-2-30.ec2.internal      Ready    <none>   2m    v1.36.0-eks-...
```

**A diferencia de Fargate**, aquí sí ves nodos. Son instancias EC2 reales
que puedes encontrar en la consola EC2 → Instances.

Verificar pods del sistema:
```bash
kubectl get pods -n kube-system
```

CoreDNS debería estar en Running directamente (no necesitas el workaround de Fargate).

---

## Paso 7: Desplegar nginx

```bash
# Crear namespace
kubectl create namespace apps

# Crear Deployment
kubectl create deployment nginx --image=nginx:alpine --replicas=2 -n apps
```

Verificar:
```bash
kubectl get pods -n apps
```

Los pods deberían pasar a Running en **segundos** (no 30-60 seg como Fargate).
¿Por qué? Porque el nodo ya existe y tiene la imagen lista o la descarga rápido.

---

## Paso 8: Exponer nginx con un Load Balancer

### La forma simple (sin instalar nada)

Con EC2 nodes, el cloud-controller-manager integrado en EKS sabe crear
un Classic Load Balancer automáticamente:

```bash
kubectl expose deployment nginx --type=LoadBalancer --port=80 --target-port=80 -n apps
```

Esperar ~2-3 min:
```bash
kubectl get svc nginx -n apps
```

Verás un `EXTERNAL-IP` con la URL del Classic Load Balancer.

#### ¿Cómo funciona sin instalar el AWS LB Controller?

EKS tiene un **cloud-controller-manager** integrado que:
1. Detecta Services de tipo `LoadBalancer`
2. Crea un Classic Load Balancer en AWS
3. Registra las instancias EC2 (los nodos) como targets
4. El tráfico va: Internet → CLB → Nodo EC2 → kube-proxy → Pod

Esto funciona porque hay instancias EC2 reales a las que apuntar.
En Fargate NO funciona porque no hay instancias.

#### ¿Classic LB vs NLB vs ALB?

| Tipo | Capa | Cuándo usar |
|------|------|-------------|
| Classic (CLB) | 4/7 | Legacy, no se recomienda para nuevo | 
| Network (NLB) | 4 | TCP/UDP de alto rendimiento, IPs estáticas |
| Application (ALB) | 7 | HTTP/HTTPS, routing por path/host, WebSockets |

El método simple crea un CLB. Si quieres NLB o ALB, necesitas el AWS LB Controller
(mismo que usamos en Fargate). Pero para un lab con nginx, el CLB funciona perfecto.

### (Opcional) La forma avanzada con NLB

Si quieres un NLB en vez de CLB, crea el archivo `nginx-service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-nlb
  namespace: apps
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
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

**Nota:** con EC2 puedes usar `target-type: instance` (no necesitas `ip` como en Fargate).
Esto registra los nodos como targets y kube-proxy se encarga del routing interno.

Para usar esto SÍ necesitas instalar el AWS LB Controller (mismos pasos que en el lab Fargate: OIDC + IAM policy + eksctl create iamserviceaccount + Helm).

---

## Paso 9: Verificar en el navegador

Copia el `EXTERNAL-IP` del Service:
```bash
kubectl get svc nginx -n apps
```

Pégalo en el navegador → debes ver la página de bienvenida de NGINX.

**Si no carga:** Espera 2-3 min más. El CLB tarda en registrar los targets como "healthy".

---

## Conceptos clave

### ¿Qué es kube-proxy?

Es un componente que corre en cada nodo. Mantiene las reglas de red (iptables/IPVS)
para que cuando el tráfico llegue a un nodo, se redirija al pod correcto
— aunque el pod esté en otro nodo.

Flujo con CLB:
```
Internet → CLB → Nodo EC2 (cualquiera) → kube-proxy → Pod (puede estar en otro nodo)
```

Flujo con NLB target-type IP:
```
Internet → NLB → Pod directamente (sin pasar por kube-proxy)
```

### ¿Qué es el VPC CNI?

CNI = Container Network Interface. Es el plugin que le asigna una IP del VPC
a cada pod. En AWS, cada pod obtiene una IP real del VPC (no una IP virtual).
Esto permite que los pods se comuniquen directamente con otros recursos del VPC
(RDS, ElastiCache, etc.) sin NAT ni proxies.

### Instance Profile vs IAM Role

- **IAM Role:** Define los permisos (qué puede hacer)
- **Instance Profile:** Es un "envoltorio" que permite asignar el rol a una instancia EC2

Cuando creas un node group y seleccionas el "Node IAM role", EKS crea automáticamente
un Instance Profile y lo asigna a las instancias del grupo.

---

## Errores comunes y soluciones

| Error | Causa | Solución |
|-------|-------|----------|
| Nodos en NotReady | El nodo no puede comunicarse con el API server | Verificar que los nodos están en subnets con salida a internet (NAT) |
| Nodos no aparecen | Node role no tiene las policies correctas | Verificar AmazonEKSWorkerNodePolicy + AmazonEC2ContainerRegistryPullOnly |
| Pods en Pending | No hay suficientes recursos (CPU/RAM) en los nodos | Aumentar desired size del node group o usar instancias más grandes |
| Service sin EXTERNAL-IP | Security group del nodo bloquea el tráfico | Verificar que el SG permite tráfico del LB |
| "0/2 nodes are available" | Los nodos están llenos o tienen taints | `kubectl describe pod <pod-name> -n apps` para ver el motivo |

---

## 🔴 Destruir todo

### Ejecutar script de destrucción:

```powershell
.\destroy.ps1
```

El script se ejecuta de corrido sin intervención manual. Usa `aws eks wait` para
esperar a que los recursos se eliminen de verdad antes de continuar al siguiente paso.

### Contenido del script (`destroy.ps1`):

```powershell
# 1. Eliminar recursos de Kubernetes
kubectl delete svc nginx -n apps
kubectl delete deployment nginx -n apps
kubectl delete namespace apps

# 2. Esperar que AWS borre el CLB (~60 seg)
# Importante: si borras el node group antes de borrar el LB,
# el LB queda con targets "draining" y tarda más en limpiarse
Write-Host "Esperando 60s para que AWS elimine el Load Balancer..."
Start-Sleep -Seconds 60

# 3. Eliminar Node Group
aws eks delete-nodegroup --cluster-name ec2-lab-cluster --nodegroup-name ec2-lab-nodes --region us-east-1
Write-Host "Esperando 5 min para que el Node Group se elimine..."
Start-Sleep -Seconds 300

# 4. Eliminar el cluster
aws eks delete-cluster --name ec2-lab-cluster --region us-east-1
Write-Host "Esperando 10 min para que el cluster se elimine..."
Start-Sleep -Seconds 600

# 5. Obtener VPC ID
$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=ec2-lab-vpc" --region us-east-1 --query "Vpcs[0].VpcId" --output text
Write-Host "VPC encontrada: $vpcId"

# 6. Eliminar NAT Gateway (debe eliminarse antes de liberar la EIP y borrar la VPC)
$natId = aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpcId" --region us-east-1 --query "NatGateways[?State!='deleted'].NatGatewayId" --output text
Write-Host "Eliminando NAT Gateway: $natId"
aws ec2 delete-nat-gateway --nat-gateway-id $natId --region us-east-1
Write-Host "Esperando 60s para que el NAT Gateway se elimine..."
Start-Sleep -Seconds 60

# 7. Liberar Elastic IP asociada al NAT
$eipAllocId = aws ec2 describe-addresses --filters "Name=tag:Name,Values=*ec2-lab*" --region us-east-1 --query "Addresses[0].AllocationId" --output text
if ($eipAllocId -ne "None") {
    Write-Host "Liberando Elastic IP: $eipAllocId"
    aws ec2 release-address --allocation-id $eipAllocId --region us-east-1
}

# 8. Eliminar VPC desde la consola (borra subnets, IGW, route tables automáticamente)
Write-Host "Ahora ve a la consola: VPC -> $vpcId -> Actions -> Delete VPC"
Write-Host "(La consola elimina subnets, IGW y route tables automaticamente)"

# 9. Eliminar IAM roles
aws iam detach-role-policy --role-name eks-ec2-lab-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam detach-role-policy --role-name eks-ec2-lab-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly
aws iam detach-role-policy --role-name eks-ec2-lab-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam delete-role --role-name eks-ec2-lab-node-role

aws iam detach-role-policy --role-name eks-ec2-lab-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam delete-role --role-name eks-ec2-lab-cluster-role

Write-Host "Listo! Solo queda borrar la VPC desde la consola si no lo hiciste."
```

---

## Lecciones aprendidas

1. **EC2 es el camino más simple para empezar** — Service tipo LoadBalancer funciona
   sin instalar nada extra. El cloud-controller-manager integrado se encarga.

2. **Pero tú gestionas los nodos** — tienes que elegir tipo de instancia, cantidad,
   actualizar AMIs, y estar pendiente del sizing. Con Fargate o Auto Mode no.

3. **El costo es por instancia, no por pod** — si tienes un t3.medium con 2 pods chiquitos,
   estás pagando toda la instancia aunque la mitad de la RAM esté vacía.

4. **Managed Node Groups simplifican mucho** — antes se hacían "self-managed" con
   CloudFormation y un Launch Template manual. Managed hace eso automáticamente.

5. **No necesitas OIDC ni Helm para lo básico** — eso solo lo necesitas si quieres
   el AWS LB Controller (para NLB/ALB) u otros controllers que hablan con APIs de AWS.
