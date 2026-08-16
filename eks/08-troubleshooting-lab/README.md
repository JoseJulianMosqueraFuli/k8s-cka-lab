# Lab 08: Troubleshooting — romper a propósito y diagnosticar

## Resumen

Creas 7 escenarios rotos a propósito, cada uno con un síntoma distinto. El
objetivo no es "arreglar cosas" — es desarrollar el método de diagnóstico:
observar el síntoma, formular hipótesis, buscar evidencia, confirmar y corregir.

Este lab es el más relevante para el CKA: troubleshooting es el 30% del examen.

**Se monta sobre:** un cluster desechable creado con eksctl (se destruye al final).
**Costo estimado adicional:** ~$0.15/hr (cluster pequeño de 2 nodos t3.medium)
**Tiempo:** ~2h 30m

**Herramientas necesarias:**

- AWS CLI v2
- kubectl
- eksctl

**Conexión CKA:** `domains/05-troubleshooting` (30% del examen)

---

## Preparación: cluster desechable

```yaml
# cluster-troubleshoot.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: eks-troubleshoot-lab
  region: us-east-1
  version: "1.30"

managedNodeGroups:
  - name: workers
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 3
    volumeSize: 20

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
```

```bash
eksctl create cluster -f cluster-troubleshoot.yaml
```

---

## El método de diagnóstico

Antes de cada escenario, este es el flujo:

```
1. Observar el síntoma       → kubectl get, kubectl describe
2. Buscar eventos            → kubectl events, kubectl describe (Events section)
3. Logs de componentes       → kubectl logs, CloudWatch
4. Correlacionar con AWS     → aws ec2, aws elbv2, aws eks
5. Formular hipótesis        → "creo que es X porque..."
6. Verificar y corregir      → cambiar una cosa, observar resultado
```

---

## Escenario 1: Service LoadBalancer en `<pending>` eterno

### Síntoma

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: stuck-lb
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
    - port: 80
EOF

kubectl get svc stuck-lb
# NAME       TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)
# stuck-lb   LoadBalancer   10.100.x.y     <pending>     80:31234/TCP
```

El EXTERNAL-IP nunca aparece.

### Causa

Las subnets públicas no tienen el tag `kubernetes.io/role/elb: 1`.

### Cómo diagnosticar

```bash
# 1. Ver si el LB controller está corriendo
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50

# 2. Buscar el error específico
kubectl logs -n kube-system deploy/aws-load-balancer-controller | grep -i "subnet"
# "failed to resolve subnets: no subnets found matching tags"

# 3. Verificar los tags de las subnets
VPC_ID=$(aws eks describe-cluster --name eks-troubleshoot-lab \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query "Subnets[?MapPublicIpOnLaunch==\`true\`].[SubnetId,Tags[?Key=='kubernetes.io/role/elb'].Value]" \
  --output table
```

### Fix

```bash
# Obtener subnets públicas
PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC_ID Name=map-public-ip-on-launch,Values=true \
  --query "Subnets[].SubnetId" --output text)

# Agregar el tag
for SUBNET in $PUBLIC_SUBNETS; do
  aws ec2 create-tags --resources $SUBNET \
    --tags Key=kubernetes.io/role/elb,Value=1
done

# Borrar y recrear el service para que el controller reintente
kubectl delete svc stuck-lb
kubectl apply -f <(cat el manifiesto anterior)

# Esperar ~2 min
kubectl get svc stuck-lb -w
```

### Lección

El AWS Load Balancer Controller usa tags para descubrir subnets. Sin el tag
correcto, no sabe dónde crear el ALB/NLB. El error no aparece en `kubectl
describe svc` — hay que ir a los logs del controller.

---

## Escenario 2: LB creado pero targets unhealthy (503)

### Síntoma

```bash
# Crear deployment + service
kubectl create deployment healthy-app --image=nginx:alpine --replicas=2
kubectl expose deployment healthy-app --port=80 --type=LoadBalancer

# El LB se crea, pero:
curl http://<LB_DNS>
# 503 Service Unavailable
```

### Causa

El Security Group del nodo no permite tráfico del LB en el puerto del NodePort.

### Cómo diagnosticar

```bash
# 1. Verificar targets en el target group
LB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName,'<partial-dns>')].LoadBalancerArn" --output text)

TG_ARN=$(aws elbv2 describe-target-groups \
  --load-balancer-arn $LB_ARN --query "TargetGroups[0].TargetGroupArn" --output text)

aws elbv2 describe-target-health --target-group-arn $TG_ARN
# "State": "unhealthy", "Reason": "Target.Timeout"

# 2. El health check no llega al nodo → SG
NODE_SG=$(aws ec2 describe-instances \
  --filters Name=tag:eks:cluster-name,Values=eks-troubleshoot-lab \
  --query "Reservations[].Instances[0].SecurityGroups[0].GroupId" --output text)

aws ec2 describe-security-group-rules --filters Name=group-id,Values=$NODE_SG \
  --query "SecurityGroupRules[?IsEgress==\`false\`].[IpProtocol,FromPort,ToPort,CidrIpv4]" \
  --output table
```

### Fix

```bash
# Obtener el NodePort
NODE_PORT=$(kubectl get svc healthy-app -o jsonpath='{.spec.ports[0].nodePort}')

# Obtener el CIDR del VPC (de donde viene el LB)
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query "Vpcs[0].CidrBlock" --output text)

# Agregar regla
aws ec2 authorize-security-group-ingress \
  --group-id $NODE_SG \
  --protocol tcp --port $NODE_PORT \
  --cidr $VPC_CIDR

# Esperar ~30s y verificar targets
aws elbv2 describe-target-health --target-group-arn $TG_ARN
# "State": "healthy"
```

### Lección

Un 503 con LB creado significa que el balanceador existe pero no puede alcanzar
los targets. Siempre verifica el target health — es el primer lugar donde mirar.

---

## Escenario 3: "the server has asked for the client to provide credentials"

### Síntoma

```bash
# Simular: un compañero intenta acceder al cluster
# Crear un rol IAM sin Access Entry
TEMP_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/developer-role"

# Configurar kubectl con ese rol
aws eks update-kubeconfig --name eks-troubleshoot-lab --role-arn $TEMP_ROLE

kubectl get pods
# error: You must be logged in to the server (the server has asked for the client
# to provide credentials that it does not have)
```

### Cómo diagnosticar

```bash
# 1. Verificar quién soy
aws sts get-caller-identity
# Confirmar que estoy asumiendo el rol correcto

# 2. Listar Access Entries (desde un usuario que SÍ tiene acceso)
aws eks list-access-entries --cluster-name eks-troubleshoot-lab

# 3. El rol no aparece → no tiene acceso al cluster
```

### Fix

```bash
# Agregar Access Entry
aws eks create-access-entry \
  --cluster-name eks-troubleshoot-lab \
  --principal-arn $TEMP_ROLE \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name eks-troubleshoot-lab \
  --principal-arn $TEMP_ROLE \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy \
  --access-scope type=cluster

# Reintentar
kubectl get pods
# Ahora funciona (con permisos de view)
```

### Lección

Este error es engañoso: parece un problema de autenticación pero realmente es
de autorización (el cluster no reconoce al principal). Con Access Entries, la
solución es agregar el ARN. Con el viejo `aws-auth`, era editar un ConfigMap.

---

## Escenario 4: Subnet CIDR exhausted — Pods en Pending

### Síntoma

```bash
# Crear muchos pods para agotar IPs
kubectl create deployment ip-eater --image=nginx:alpine --replicas=50

kubectl get pods | grep Pending
# ip-eater-xxx   0/1   Pending   0   10s  (muchos)

kubectl describe pod <uno-pending>
# Events:
#   Warning  FailedScheduling  default-scheduler  0/2 nodes are available:
#     2 node(s) had untolerable taint {node.kubernetes.io/network-unavailable}
```

### Cómo diagnosticar

```bash
# 1. Verificar si es un problema de IPs
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.pods}{"\n"}{end}'

# 2. Ver cuántas IPs quedan en las subnets
SUBNET_IDS=$(aws eks describe-cluster --name eks-troubleshoot-lab \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text)

for SUBNET in $SUBNET_IDS; do
  aws ec2 describe-subnets --subnet-ids $SUBNET \
    --query "Subnets[].[SubnetId,AvailableIpAddressCount,CidrBlock]" --output text
done

# 3. Si AvailableIpAddressCount es muy bajo, las IPs se agotaron
```

### Fix

```bash
# Opción 1: Reducir réplicas
kubectl scale deploy ip-eater --replicas=5

# Opción 2: Habilitar prefix delegation (más pods por nodo)
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true

# Opción 3: Usar subnets más grandes (requiere recrear el cluster o agregar subnets)
```

### Lección

El mensaje "network unavailable" o pods Pending sin razón clara suele ser
agotamiento de IPs. EKS con VPC CNI consume una IP por pod — un subnet /24
(251 IPs usables) se agota rápido con clusters densos.

---

## Escenario 5: CoreDNS en CrashLoopBackOff después de upgrade

### Síntoma

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
# coredns-xxx   0/1   CrashLoopBackOff   5   3m

# Ningún pod puede resolver DNS
kubectl exec deploy/ip-eater -- nslookup kubernetes.default
# ;; connection timed out; no servers could be reached
```

### Cómo diagnosticar

```bash
# 1. Logs de CoreDNS
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20
# "plugin/loop: Loop ... detected for zone '.'"
# O: incompatible plugin version

# 2. Verificar versión del add-on vs versión del cluster
aws eks describe-addon --cluster-name eks-troubleshoot-lab \
  --addon-name coredns --query "[addon.addonVersion,addon.status]" --output text

# 3. Ver compatibilidad
aws eks describe-addon-versions --addon-name coredns \
  --kubernetes-version 1.30 \
  --query "addons[0].addonVersions[].addonVersion" --output text
```

### Fix

```bash
# Actualizar a una versión compatible
COMPATIBLE_VERSION=$(aws eks describe-addon-versions --addon-name coredns \
  --kubernetes-version 1.30 \
  --query "addons[0].addonVersions[0].addonVersion" --output text)

aws eks update-addon \
  --cluster-name eks-troubleshoot-lab \
  --addon-name coredns \
  --addon-version $COMPATIBLE_VERSION \
  --resolve-conflicts OVERWRITE

# Esperar
kubectl rollout status deploy/coredns -n kube-system
```

### Lección

CoreDNS caído = cluster efectivamente muerto (nada puede resolver nombres de
Services). Después de un upgrade de cluster, SIEMPRE verificar la compatibilidad
de los add-ons. El control plane puede estar en 1.30 pero los add-ons seguir en
versiones de 1.29.

---

## Escenario 6: PDB demasiado estricto — drain se cuelga

### Síntoma

```bash
# Deploy con 2 réplicas y PDB que pide 2 mínimo available
kubectl create deployment pdb-test --image=nginx:alpine --replicas=2
kubectl apply -f - <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-strict
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: pdb-test
EOF

# Intentar drenar un nodo
NODE=$(kubectl get pods -l app=pdb-test -o jsonpath='{.items[0].spec.nodeName}')
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
# Se queda colgado indefinidamente...
# "Cannot evict pod as it would violate the pod's disruption budget"
```

### Cómo diagnosticar

```bash
# 1. Ver por qué el drain no avanza
# (En otra terminal)
kubectl get events --field-selector reason=EvictionBlocked

# 2. Ver el PDB
kubectl get pdb pdb-strict -o yaml
# minAvailable: 2, currentHealthy: 2, disruptionsAllowed: 0

# 3. disruptionsAllowed: 0 significa "no puedo quitar ningún pod"
# Con 2 réplicas y minAvailable: 2, NUNCA puedes drenar ningún nodo
```

### Fix

```bash
# Ctrl+C para cancelar el drain

# Opción 1: Reducir minAvailable
kubectl patch pdb pdb-strict -p '{"spec":{"minAvailable": 1}}'

# Opción 2: Aumentar réplicas (si minAvailable tiene sentido)
kubectl scale deploy pdb-test --replicas=3

# Ahora sí:
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
# Funciona — puede quitar 1 pod y mantener 2 (o 1) disponibles

# Limpiar
kubectl uncordon $NODE
```

### Lección

Un PDB con `minAvailable >= replicas` crea un deadlock: nunca se puede drenar
ningún nodo que tenga esos pods. Karpenter tampoco puede consolidar. Es el
error más común con PDBs y bloquea upgrades enteros.

---

## Escenario 7: Impossible resource request — insufficient cpu

### Síntoma

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: greedy-pod
spec:
  containers:
    - name: greedy
      image: nginx:alpine
      resources:
        requests:
          cpu: "16"
          memory: 64Gi
EOF

kubectl get pod greedy-pod
# greedy-pod   0/1   Pending   0   30s

kubectl describe pod greedy-pod
# Events:
#   Warning  FailedScheduling  0/2 nodes are available: 2 Insufficient cpu,
#     2 Insufficient memory
```

### Cómo diagnosticar

```bash
# 1. Ver qué pide el pod vs qué hay disponible
kubectl describe pod greedy-pod | grep -A5 "Requests:"
# cpu: 16, memory: 64Gi

# 2. Ver capacidad de los nodos
kubectl describe nodes | grep -A5 "Allocatable"
# cpu: 2 (t3.medium tiene 2 vCPUs)
# memory: ~3.5Gi

# 3. 16 CPUs > 2 CPUs disponibles. Ningún nodo actual puede schedulear esto.
```

### Fix

```bash
# Opción 1: Reducir el request a algo razonable
kubectl delete pod greedy-pod
kubectl run greedy-pod --image=nginx:alpine \
  --requests='cpu=100m,memory=64Mi' --limits='cpu=200m,memory=128Mi'

# Opción 2: Si realmente necesitas 16 CPUs, necesitas un nodo más grande
# (Karpenter o Cluster Autoscaler lo crearía si hay un NodePool con instancias grandes)
```

### Lección

"Insufficient cpu" no siempre significa que el cluster está lleno. A veces
significa que el pod pide más que lo que cualquier nodo individual puede ofrecer.
Un request de 16 CPUs necesita un nodo con al menos 16 CPUs — no se puede
dividir entre nodos.

---

## Resumen del método de diagnóstico

| Paso | Herramienta                                   | Qué buscar                            |
| ---- | --------------------------------------------- | ------------------------------------- |
| 1    | `kubectl get`                                 | Estado general (Pending, Error, etc.) |
| 2    | `kubectl describe`                            | Events al final del output            |
| 3    | `kubectl logs`                                | Errores en el pod o controller        |
| 4    | `aws elbv2/ec2/eks`                           | Estado de recursos AWS                |
| 5    | CloudWatch Logs (si habilitado)               | Logs del control plane                |
| 6    | `kubectl get events --sort-by=.lastTimestamp` | Timeline de eventos                   |

### Comandos que deberías tener en muscle memory

```bash
# Estado rápido
kubectl get pods -A | grep -v Running
kubectl get events --sort-by='.lastTimestamp' -A | tail -20

# Nodos
kubectl describe node <name> | grep -A10 "Conditions"
kubectl top nodes

# Networking
kubectl get svc -A | grep pending
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=20

# Storage
kubectl get pvc -A | grep -v Bound
kubectl describe pv <name>

# DNS
kubectl exec <pod> -- nslookup kubernetes.default
```

---

## Troubleshooting del troubleshooting

| Problema                          | Causa                                   | Fix                                        |
| --------------------------------- | --------------------------------------- | ------------------------------------------ |
| `kubectl` no responde             | kubeconfig apunta al cluster incorrecto | `kubectl config current-context`           |
| No puedo ver logs de kube-system  | RBAC insuficiente                       | Usar un rol con permisos cluster-admin     |
| `describe` no muestra eventos     | Los eventos expiraron (default 1h)      | Verificar en CloudWatch si está habilitado |
| El fix no funciona inmediatamente | Controllers tienen reconciliation loops | Esperar 30-60s y verificar de nuevo        |

---

## 🔴 Destruir recursos del lab

```bash
# Este cluster es desechable — borrarlo completo
eksctl delete cluster --name eks-troubleshoot-lab --region us-east-1

# Verificar que no quedó nada
aws ec2 describe-vpcs --filters Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=eks-troubleshoot-lab \
  --query "Vpcs[].VpcId"
# Debería estar vacío
```

---

## Lecciones aprendidas

1. **Los logs del controller importan más que los logs del pod.** Cuando un
   Service está en `<pending>`, el pod está perfecto — el problema está en el
   controller que debería crear el LB. Mira los logs correctos.

2. **Los tags de AWS son configuración invisible.** Un subnet sin
   `kubernetes.io/role/elb` se ve igual en `kubectl` pero el LB controller lo
   ignora completamente. La causa del problema está en AWS, no en Kubernetes.

3. **"Insufficient cpu" es aritmética, no magia.** Requests de un pod se suman.
   Si la suma excede la capacidad de cualquier nodo individual, no hay donde
   schedulear. No se fragmenta entre nodos.

4. **PDB + replicas son una ecuación.** `minAvailable >= replicas` = deadlock.
   Siempre verifica que `replicas - minAvailable >= 1` (o que haya nodos donde
   reschedulear).

5. **El 30% del CKA es esto.** No memorizar — desarrollar el flujo:
   síntoma → describe → events → logs → API de AWS → hipótesis → fix. Repetirlo
   hasta que sea automático.

6. **Cada escenario tiene una pista en los Events.** Kubernetes te dice qué
   falló — solo que a veces el mensaje es críptico. Aprender a leer esos mensajes
   es la habilidad real del troubleshooting.
