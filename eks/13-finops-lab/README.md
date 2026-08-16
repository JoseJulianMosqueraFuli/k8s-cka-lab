# Lab 13: Costo y eficiencia — FinOps sobre Kubernetes

## Resumen

FinOps en Kubernetes no es "gastar menos" — es gastar con datos. Instalas
herramientas de atribución de costos, usas VPA para right-sizing basado en
evidencia, configuras Spot con Karpenter, y entiendes cuándo los commitments
(Savings Plans, Reserved Instances) tienen sentido.

El círculo se cierra: los labels que Kyverno inyecta (lab 11) son los que
aquí te dicen qué equipo gasta cuánto.

**Se monta sobre:** el cluster del lab 03 (Auto Mode) o cualquier cluster con Karpenter.
**Costo estimado adicional:** ~$0.00 (OpenCost/Kubecost son pods, VPA en modo Off no actúa)
**Tiempo:** ~2h

**Herramientas necesarias:**

- AWS CLI v2
- kubectl
- helm

**Conexión con otros labs:** Lab 06 (autoscaling), Lab 11 (labels de ownership)

---

## Los costos ocultos de Kubernetes

Antes de optimizar, identifica de dónde viene el gasto:

| Recurso           | Cómo se acumula                        | Visible en         |
| ----------------- | -------------------------------------- | ------------------ |
| Nodos EC2         | Por hora, según instance type          | EC2 billing        |
| NAT Gateway       | $0.045/hr + $0.045/GB procesado        | VPC billing        |
| Load Balancers    | $0.0225/hr + LCUs/NLCUs                | ELB billing        |
| EBS volumes       | Por GB/mes, incluso si no se usa       | EC2/EBS billing    |
| CloudWatch Logs   | $0.50/GB ingestión + storage           | CloudWatch billing |
| ECR storage       | $0.10/GB/mes                           | ECR billing        |
| EKS control plane | $0.10/hr ($73/mes) — fijo              | EKS billing        |
| Data transfer     | $0.09/GB cross-AZ, $0.09/GB a internet | EC2 billing        |

### Lo que ya aprendiste en labs anteriores

| Costo oculto                         | Lab donde lo viste      |
| ------------------------------------ | ----------------------- |
| NAT Gateway olvidado                 | Lab 01-03 (destroy)     |
| EBS volumes de StatefulSets borrados | Lab 06 (reclaimPolicy)  |
| Load Balancers sin Service           | Lab 04 (destroy)        |
| Control plane logs excesivos         | Lab 12 (observabilidad) |

---

## Parte 1: Atribución — ¿quién gasta qué?

### Instalar OpenCost

```bash
helm repo add opencost https://opencost.github.io/opencost-helm-chart
helm repo update

helm install opencost opencost/opencost \
  --namespace opencost --create-namespace \
  --set opencost.ui.enabled=true \
  --set opencost.exporter.defaultClusterId=$CLUSTER_NAME \
  --set opencost.prometheus.internal.enabled=true
```

### Alternativa: Kubecost (versión free)

```bash
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm repo update

helm install kubecost kubecost/cost-analyzer \
  --namespace kubecost --create-namespace \
  --set kubecostToken="" \
  --set persistentVolume.enabled=false
```

### Ver costos por namespace/deployment

```bash
# Acceder a la UI
kubectl port-forward -n opencost svc/opencost 9090:9090 &

# O por API:
kubectl port-forward -n opencost svc/opencost 9003:9003 &
curl -s "http://localhost:9003/allocation/compute?window=24h&aggregate=namespace" | jq .
```

### ¿Por qué los labels de ownership importan?

Sin labels:

```
Namespace: apps → $X/día
  ¿De quién es? No sé. ¿Quién aprueba el gasto? Nadie.
```

Con labels (inyectados por Kyverno en lab 11):

```
Namespace: apps, team: backend, cost-center: engineering → $X/día
  Owner claro → puede tomar decisiones de optimización.
```

---

## Parte 2: Right-sizing con VPA (modo recomendación)

### ¿Qué es right-sizing?

Poner los requests/limits correctos basándose en uso real, no en intuición:

| Situación           | Problema                                           | Solución          |
| ------------------- | -------------------------------------------------- | ----------------- |
| Requests muy altos  | Reservas CPU/mem que no usas → nodos subutilizados | Reducir requests  |
| Requests muy bajos  | Pod throttled → lento para el usuario              | Aumentar requests |
| Limits muy altos    | Un pod con bug consume todo el nodo                | Ajustar limits    |
| Sin requests/limits | Scheduler vuela ciego, no hay garantías            | Definir ambos     |

### Instalar VPA

```bash
# Clonar el repo de autoscaler
git clone https://github.com/kubernetes/autoscaler.git /tmp/autoscaler
cd /tmp/autoscaler/vertical-pod-autoscaler

# Instalar solo en modo recomendación (no actuará)
./hack/vpa-up.sh
```

### VPA en modo Off (solo recomienda)

```yaml
# manifests/vpa-identity-api.yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: identity-api-vpa
  namespace: apps
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: identity-api
  updatePolicy:
    updateMode: "Off" # ← SOLO RECOMIENDA, no toca nada
```

```bash
kubectl apply -f manifests/vpa-identity-api.yaml

# Esperar ~5-10 minutos para que recolecte datos
kubectl describe vpa identity-api-vpa -n apps
```

### Interpretar las recomendaciones

```
Recommendation:
  Container Recommendations:
    Container Name: api
    Lower Bound:    Cpu: 10m,  Memory: 20Mi
    Target:         Cpu: 25m,  Memory: 30Mi   ← usar esto como requests
    Uncapped Target: Cpu: 25m, Memory: 30Mi
    Upper Bound:    Cpu: 100m, Memory: 60Mi   ← usar esto como limits
```

### ¿Por qué modo Off y no Auto?

| Modo   | Comportamiento                              | Riesgo                   |
| ------ | ------------------------------------------- | ------------------------ |
| `Off`  | Solo genera recomendaciones                 | Ninguno                  |
| `Auto` | Reinicia pods para aplicar nuevos resources | Disrupciones inesperadas |

En producción: `Off` → revisar recomendaciones → aplicar manualmente con
confianza → repetir. `Auto` es tentador pero puede reiniciar pods en momentos
inoportunos.

---

## Parte 3: Spot con Karpenter

### ¿Qué es Spot?

Instancias EC2 con hasta 90% de descuento. AWS puede reclamarlas con 2 minutos
de aviso. Perfectas para workloads que toleran interrupciones.

### ¿Qué workloads toleran Spot?

| Tolera Spot ✓                          | NO tolera Spot ✗                         |
| -------------------------------------- | ---------------------------------------- |
| Stateless con múltiples réplicas       | Bases de datos (StatefulSets)            |
| Workers de procesamiento batch         | Servicios singleton sin reemplazo rápido |
| Pods que el HPA puede reescalar rápido | Pods con startup time > 2 min            |
| CI/CD runners                          | Pods con PVCs EBS (atados a AZ)          |

### Configurar NodePool con Spot + On-Demand

```yaml
# manifests/nodepool-mixed.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: mixed-pool
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"] # Ambos tipos
        - key: node.kubernetes.io/instance-type
          operator: In
          values:
            - t3.medium
            - t3.large
            - m5.large
            - m5.xlarge
            - c5.large # Diversificación = menos interrupciones
            - c5.xlarge
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
  limits:
    cpu: "100"
    memory: 200Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s
```

```bash
kubectl apply -f manifests/nodepool-mixed.yaml
```

### ¿Por qué diversificar instance types?

Con un solo instance type (e.g., solo `m5.large`), si AWS reclama Spot de ese
tipo en tu AZ, pierdes todos tus nodos Spot. Con 6+ instance types, la
probabilidad de interrupción simultánea es mucho menor.

### Indicar qué pods van a Spot

```yaml
# En el Deployment:
spec:
  template:
    spec:
      nodeSelector:
        karpenter.sh/capacity-type: spot # Forzar Spot
      tolerations:
        - key: "karpenter.sh/capacity-type"
          value: "spot"
          effect: "NoSchedule"
```

O dejar que Karpenter decida (sin nodeSelector): pondrá pods en Spot si hay
capacidad disponible, On-Demand si no.

---

## Parte 4: Consolidación con Karpenter

### ¿Qué es consolidación?

Karpenter detecta nodos subutilizados y mueve los pods a otros nodos para
terminar los nodos vacíos. Menos nodos = menos costo.

### Observar consolidación en acción

```bash
# Crear carga
kubectl create deployment consolidation-test --image=nginx:alpine --replicas=10 \
  --dry-run=client -o yaml | \
  kubectl patch -f - --type='merge' --local -o yaml \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","resources":{"requests":{"cpu":"100m","memory":"64Mi"}}}]}}}}' | \
  kubectl apply -f -

# Esperar a que Karpenter cree nodos para los 10 pods
kubectl get nodes -w

# Ahora reducir
kubectl scale deploy consolidation-test --replicas=2

# Observar consolidación (nodos subutilizados se drenan y terminan)
kubectl get nodes -w
# Nodos desaparecen en ~60-120s
```

### `consolidateAfter` y `ttlSecondsAfterEmpty`

| Setting                 | Comportamiento                               |
| ----------------------- | -------------------------------------------- |
| `consolidateAfter: 30s` | Espera 30s de subutilización antes de actuar |
| `consolidateAfter: 0s`  | Agresivo — consolida inmediatamente          |
| `consolidateAfter: 5m`  | Conservador — espera 5 min (evita flapping)  |

Para un lab: `30s-60s`. Para producción: `5m-15m` (evitar consolidar si la carga
vuelve pronto).

---

## Parte 5: Commitments — Savings Plans y Reserved Instances

### ¿Cuándo comprar commitments?

```
1. PRIMERO: Right-size (VPA, datos reales)
2. DESPUÉS: Eliminar waste (nodos vacíos, EBS huérfanos)
3. FINALMENTE: Comprar commitments para la base estable

NUNCA al revés. Un Savings Plan sobre instancias sobredimensionadas
es pagar menos por algo que no necesitas.
```

### Savings Plans vs Reserved Instances

| Aspecto       | Savings Plans                   | Reserved Instances               |
| ------------- | ------------------------------- | -------------------------------- |
| Flexibilidad  | Instance family, región, OS     | Instance type fijo, AZ fija      |
| Descuento     | Hasta 72%                       | Hasta 75%                        |
| Compromiso    | $/hr por 1 o 3 años             | Instancia específica             |
| Mejor para    | Workloads que cambian de tamaño | Workloads completamente estables |
| Con Karpenter | Funciona bien (Karpenter elige) | Funciona si fijas instance type  |

### ¿Cómo calcular la base estable?

```bash
# Usar Cost Explorer para ver el uso mínimo constante en los últimos 30 días
# La "base" es el mínimo — lo que SIEMPRE estás usando
# El "pico" se cubre con On-Demand o Spot
```

```
Costo típico sin optimización:
  5 nodos m5.large × 24/7 × 30 días = $623/mes (On-Demand)

Con optimización:
  2 nodos m5.large On-Demand (base) × Savings Plan 1yr = $182/mes (-66%)
  3 nodos Spot (pico) × costo Spot = ~$56/mes (-90% sobre On-Demand)
  Total: $238/mes (vs $623 = 62% ahorro)
```

---

## Parte 6: Detectar waste — los sospechosos habituales

```bash
# 1. Volúmenes EBS sin usar (estado: available)
echo "=== EBS sin usar ==="
aws ec2 describe-volumes \
  --filters Name=status,Values=available \
  --region $REGION \
  --query "Volumes[].[VolumeId,Size,CreateTime]" --output table

# 2. Elastic IPs sin asociar
echo "=== EIPs sin usar ==="
aws ec2 describe-addresses \
  --filters Name=association-id,Values="" \
  --region $REGION \
  --query "Addresses[].[PublicIp,AllocationId]" --output table 2>/dev/null

# 3. Load Balancers sin targets
echo "=== LBs potencialmente huérfanos ==="
for LB_ARN in $(aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[].LoadBalancerArn" --output text); do
  TG_COUNT=$(aws elbv2 describe-target-groups --load-balancer-arn $LB_ARN \
    --region $REGION --query "length(TargetGroups)" --output text)
  if [ "$TG_COUNT" = "0" ]; then
    echo "  Sin target groups: $LB_ARN"
  fi
done

# 4. NAT Gateways (verifica que los necesitas)
echo "=== NAT Gateways activos ==="
aws ec2 describe-nat-gateways --filter Name=state,Values=available \
  --region $REGION \
  --query "NatGateways[].[NatGatewayId,SubnetId]" --output table
echo "  Cada uno cuesta ~$32/mes + data processing"

# 5. CloudWatch Log Groups con retención infinita
echo "=== Log Groups sin retención (retención infinita) ==="
aws logs describe-log-groups --region $REGION \
  --query "logGroups[?retentionInDays==null].[logGroupName,storedBytes]" --output table
```

### Script de limpieza seguro

```bash
# Solo muestra — no borra nada sin confirmación
echo ""
echo "=== RESUMEN DE WASTE POTENCIAL ==="
echo "Revisa manualmente antes de borrar."
echo "Comandos de borrado (NO ejecutar sin revisar):"
echo ""
echo "# Borrar volumen:  aws ec2 delete-volume --volume-id vol-xxx"
echo "# Borrar EIP:      aws ec2 release-address --allocation-id eipalloc-xxx"
echo "# Borrar LB:       aws elbv2 delete-load-balancer --load-balancer-arn arn:..."
echo "# Borrar NAT GW:   aws ec2 delete-nat-gateway --nat-gateway-id nat-xxx"
echo "# Set retención:   aws logs put-retention-policy --log-group-name X --retention-in-days 7"
```

---

## Parte 7: Tags obligatorios con Kyverno (cierra el círculo)

Del lab 11, la política de mutación ya inyecta `cost-center` y `team` en los
Deployments. Pero ¿qué pasa con los recursos de AWS (nodos, volúmenes)?

### Tags propagados por Karpenter

```yaml
# En el NodePool:
spec:
  template:
    metadata:
      labels:
        team: "{{nodePool.metadata.labels.team}}" # Propagado al nodo EC2
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
```

```yaml
# En EC2NodeClass:
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  tags:
    ManagedBy: karpenter
    Environment: lab
    CostCenter: engineering
```

Estos tags aparecen en el Cost Explorer de AWS, permitiendo filtrar costos por
equipo/entorno sin herramientas externas.

---

## Troubleshooting

| Síntoma                              | Causa probable                               | Fix                                           |
| ------------------------------------ | -------------------------------------------- | --------------------------------------------- |
| OpenCost muestra $0 para todo        | No tiene acceso a pricing o métricas         | Verificar que prometheus scraping funciona    |
| VPA no genera recomendaciones        | Menos de 5 min de datos                      | Esperar ~10-15 min con el pod corriendo       |
| Spot interruptions causan downtime   | Pod sin réplicas o sin PDB                   | Usar replicas >= 2 + PDB + spread constraints |
| Karpenter no consolida               | `consolidateAfter` muy alto o PDB bloqueando | Verificar disruption policy                   |
| Tags no aparecen en Cost Explorer    | Toma 24h en reflejarse                       | Esperar — Cost Explorer no es real-time       |
| NAT Gateway cuesta más que los nodos | Muchos pods descargando de internet          | Usar VPC endpoints para ECR/S3                |

---

## 🔴 Destruir recursos del lab

```bash
# OpenCost/Kubecost
helm uninstall opencost -n opencost 2>/dev/null
helm uninstall kubecost -n kubecost 2>/dev/null
kubectl delete namespace opencost kubecost 2>/dev/null

# VPA
cd /tmp/autoscaler/vertical-pod-autoscaler
./hack/vpa-down.sh

# Deployments de prueba
kubectl delete deploy consolidation-test 2>/dev/null

# NodePools custom
kubectl delete nodepool mixed-pool 2>/dev/null

# Verificar waste residual
echo "Ejecuta el script de detección de waste (Parte 6) para verificar que no queda nada"
```

---

## Lecciones aprendidas

1. **Right-size antes de comprar commitments.** Un Savings Plan sobre instancias
   sobredimensionadas es pagar un descuento sobre un desperdicio. VPA en modo Off
   te da los datos para decidir con evidencia.

2. **Los labels son la moneda de FinOps.** Sin labels de ownership, no puedes
   atribuir costos. Sin atribución, nadie es responsable. Sin responsable, nadie
   optimiza. Kyverno (lab 11) resuelve esto con mutación automática.

3. **Spot + diversificación = ahorro real sin drama.** Un solo instance type en
   Spot es frágil. 6+ instance types con Karpenter distribuye el riesgo de
   interrupción. Para workloads stateless con réplicas, Spot es casi gratis.

4. **El NAT Gateway es el costo invisible más común.** $0.045/hr parece poco.
   $32/mes por gateway × 3 AZs = ~$96/mes haciendo nada útil. En labs, un solo
   NAT Gateway es suficiente (lab 09, Terraform: `single_nat_gateway = true`).

5. **Consolidación sin PDBs es peligroso.** Karpenter consolida agresivamente
   — puede terminar un nodo con tus pods si no hay PDB que lo detenga. PDB +
   consolidation = ahorro sin disrupciones.

6. **El verdadero ahorro viene de no crear.** Cada recurso que no creas es un
   costo que no tienes. Un cluster de lab que no destruyes a tiempo, un LB que
   nadie usa, un volumen EBS de un StatefulSet borrado — el ahorro real es
   disciplina de cleanup, no de pricing.
