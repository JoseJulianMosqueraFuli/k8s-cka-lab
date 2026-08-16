# Lab 06: Estado y escala — storage persistente, autoscaling y backup

## Resumen

Despliegas workloads con estado (StatefulSet + EBS), comparas con storage
compartido (EFS), configuras autoscaling real de pods y nodos con carga
generada, y pruebas backup/restore con Velero.

La cadena completa: carga → métricas → HPA escala pods → pods Pending →
Karpenter/Cluster Autoscaler escala nodos → pods Running. Luego reduces la
carga y ves cómo Karpenter consolida nodos respetando PDBs.

**Se monta sobre:** el cluster del lab 03 (Auto Mode).
**Costo estimado adicional:** ~$0.15/hr (EBS volumes, EFS, nodos adicionales durante escalado)
**Tiempo:** ~2h 30m

**Herramientas necesarias:**

- AWS CLI v2
- kubectl
- helm
- Una herramienta de carga (hey, k6, o similar)

**Conexión CKA:** `domains/04-storage` (10%), `domains/02-workloads` — StatefulSets, scaling (15%)

---

## Qué vas a construir

```
                         ┌─── EBS CSI ───── PVC (gp3) ── atado a una AZ
StatefulSet (3 réplicas) ┤
                         └─── Pod-0, Pod-1, Pod-2 (cada uno con su PVC)

Deployment (sin estado)  ── EFS CSI ── PVC ReadWriteMany ── montado en pods de múltiples AZs

HPA ←── metrics-server ←── CPU/memory del pod
         ↓
Pods Pending → Karpenter crea nodos → pods schedulados

Velero → snapshot EBS + manifiestos → restore completo
```

---

## Parte 1: Storage con EBS (StatefulSet)

### Paso 1.1: Verificar que el EBS CSI driver está activo

```bash
CLUSTER_NAME=eks-automode-lab
REGION=us-east-1

# En Auto Mode, el EBS CSI ya viene como add-on
aws eks describe-addon --cluster-name $CLUSTER_NAME \
  --addon-name aws-ebs-csi-driver --region $REGION \
  --query "addon.status"
# "ACTIVE"

# Verificar la StorageClass
kubectl get storageclass
# NAME            PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# gp3 (default)   ebs.csi.aws.com         Delete          WaitForFirstConsumer
```

### ¿Por qué `WaitForFirstConsumer`?

| volumeBindingMode      | Comportamiento                                            | Problema                              |
| ---------------------- | --------------------------------------------------------- | ------------------------------------- |
| `Immediate`            | Crea el volumen EBS en cuanto se crea el PVC              | Puede elegir una AZ donde no hay nodo |
| `WaitForFirstConsumer` | Espera a que un pod use el PVC, lo crea en la AZ del nodo | Siempre hay un nodo en esa AZ         |

Con `Immediate` + topología de múltiples AZs, puedes terminar con un volumen en
`us-east-1a` y todos los nodos en `us-east-1b`. El pod queda en `Pending`
indefinidamente.

### Paso 1.2: StatefulSet con volumeClaimTemplates

```yaml
# manifests/statefulset-ebs.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: data-store
  namespace: apps
spec:
  serviceName: data-store
  replicas: 3
  selector:
    matchLabels:
      app: data-store
  template:
    metadata:
      labels:
        app: data-store
    spec:
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c"]
          args:
            - |
              echo "Pod $(hostname) escribiendo en /data" >> /data/log.txt
              while true; do
                echo "$(date) - heartbeat from $(hostname)" >> /data/log.txt
                sleep 10
              done
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3
        resources:
          requests:
            storage: 5Gi
```

```bash
kubectl create namespace apps 2>/dev/null || true
kubectl apply -f manifests/statefulset-ebs.yaml
```

### Paso 1.3: Observar la topología

```bash
# Ver que cada pod tiene su PVC
kubectl get pvc -n apps
# data-data-store-0   Bound   pvc-xxx   5Gi   gp3
# data-data-store-1   Bound   pvc-yyy   5Gi   gp3
# data-data-store-2   Bound   pvc-zzz   5Gi   gp3

# Ver en qué AZ cayó cada volumen
kubectl get pv -o custom-columns=\
NAME:.metadata.name,\
ZONE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0],\
CLAIM:.spec.claimRef.name
```

### ¿Qué pasa si un pod se muere?

```bash
# Borrar el pod 0
kubectl delete pod data-store-0 -n apps

# El StatefulSet lo recrea con el MISMO PVC
kubectl get pod data-store-0 -n apps -w
# Pending → Running (se ata al mismo volumen, misma AZ)

# Los datos persisten
kubectl exec data-store-0 -n apps -- cat /data/log.txt
# Verás los heartbeats anteriores + los nuevos
```

**El PVC sobrevive al pod.** Eso es el punto de un StatefulSet. Pero el pod queda
atado a la AZ de su volumen — no puede migrar a otra AZ.

---

## Parte 2: Storage con EFS (ReadWriteMany)

### Paso 2.1: Crear el filesystem EFS

```bash
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

# Security group que permite NFS desde el CIDR del VPC
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION \
  --query "Vpcs[0].CidrBlock" --output text)

EFS_SG=$(aws ec2 create-security-group \
  --group-name eks-lab-efs-sg \
  --description "Allow NFS from VPC" \
  --vpc-id $VPC_ID \
  --region $REGION \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $EFS_SG \
  --protocol tcp --port 2049 \
  --cidr $VPC_CIDR \
  --region $REGION

# Crear filesystem
EFS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value=eks-lab-efs \
  --region $REGION \
  --query FileSystemId --output text)

echo "EFS: $EFS_ID"

# Mount targets en cada subnet privada
SUBNET_IDS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text)

for SUBNET in $SUBNET_IDS; do
  aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $SUBNET \
    --security-groups $EFS_SG \
    --region $REGION 2>/dev/null || true
done

# Esperar hasta que estén available
echo "Esperando mount targets..."
sleep 30
```

### Paso 2.2: Instalar el EFS CSI driver (si no está)

```bash
# En Auto Mode puede no estar preinstalado
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-efs-csi-driver \
  --region $REGION 2>/dev/null || echo "Ya existe"
```

### Paso 2.3: StorageClass y PVC para EFS

```yaml
# manifests/efs-storage.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: <EFS_ID>
  directoryPerms: "700"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-data
  namespace: apps
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 5Gi # EFS es elástico, esto es solo metadata
```

### Paso 2.4: Deployment multi-AZ con EFS

```yaml
# manifests/deploy-efs.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: writer-efs
  namespace: apps
spec:
  replicas: 3
  selector:
    matchLabels:
      app: writer-efs
  template:
    metadata:
      labels:
        app: writer-efs
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: writer-efs
      containers:
        - name: writer
          image: busybox:1.36
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                echo "$(date) - $(hostname)" >> /shared/writes.log
                sleep 5
              done
          volumeMounts:
            - name: shared
              mountPath: /shared
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
      volumes:
        - name: shared
          persistentVolumeClaim:
            claimName: shared-data
```

```bash
kubectl apply -f manifests/efs-storage.yaml
kubectl apply -f manifests/deploy-efs.yaml
```

### Comparación EBS vs EFS

| Aspecto               | EBS (gp3)                      | EFS                              |
| --------------------- | ------------------------------ | -------------------------------- |
| **AccessMode**        | ReadWriteOnce                  | ReadWriteMany                    |
| **Topología**         | Atado a una AZ                 | Multi-AZ                         |
| **Latencia**          | ~1ms                           | ~5-10ms                          |
| **Costo (us-east-1)** | $0.08/GB/mes                   | $0.30/GB/mes (estándar)          |
| **Escalabilidad**     | Fijo (debes resize)            | Elástico (crece automáticamente) |
| **Caso de uso**       | Bases de datos, un solo writer | Archivos compartidos, CMS, logs  |
| **Backup**            | EBS Snapshot (AZ-bound)        | EFS backup (cross-region capaz)  |

### ¿Por qué EFS cuesta más pero a veces vale la pena?

Si tienes un Deployment que necesita leer los mismos archivos estáticos en 3 AZs,
con EBS necesitarías 3 copias sincronizadas (complejo). Con EFS, un solo PVC
ReadWriteMany y listo. Pagas 4x más por GB pero eliminas complejidad.

---

## Parte 3: Autoscaling — HPA + nodos

### Paso 3.1: Verificar metrics-server

```bash
kubectl top nodes
# Si falla: metrics-server no está instalado

# En Auto Mode ya debería estar. Si no:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

### Paso 3.2: Deployment para carga

```yaml
# manifests/deploy-loadtest.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cpu-burner
  namespace: apps
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cpu-burner
  template:
    metadata:
      labels:
        app: cpu-burner
    spec:
      containers:
        - name: burner
          image: busybox:1.36
          command: ["sh", "-c", "while true; do :; done"]
          resources:
            requests:
              cpu: 100m
            limits:
              cpu: 200m
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cpu-burner-hpa
  namespace: apps
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cpu-burner
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

```bash
kubectl apply -f manifests/deploy-loadtest.yaml
```

### Paso 3.3: Observar el escalado

```bash
# Ver el HPA reaccionar
kubectl get hpa cpu-burner-hpa -n apps -w
# TARGETS    MINPODS   MAXPODS   REPLICAS
# 200%/50%   1         10        1          ← detecta exceso
# 200%/50%   1         10        4          ← escala a 4
# ...

# Cuando los pods queden Pending (no caben en nodos actuales):
kubectl get pods -n apps | grep Pending

# Karpenter/Cluster Autoscaler crea un nodo nuevo:
kubectl get nodes -w
# Un nuevo nodo aparece en 60-90 segundos
```

### ¿Por qué la cadena no es instantánea?

```
t=0    CPU > 50%         → HPA calcula réplicas deseadas
t=15s  HPA escala        → nuevos pods creados, estado Pending
t=30s  Scheduler intenta → no hay capacidad, marca pods como unschedulable
t=45s  Karpenter detecta → solicita instancia EC2
t=90s  Nodo ready        → pods se scheduleean y pasan a Running
```

El HPA tiene un cooldown de ~15s por defecto. Karpenter tarda ~60s en aprovisionar.
La cadena completa: **~2 minutos desde que la CPU subió** hasta que los pods
nuevos están sirviendo tráfico.

### Paso 3.4: Reducir carga y ver consolidación

```bash
# Escalar a 0 para simular caída de carga
kubectl scale deploy cpu-burner -n apps --replicas=0

# El HPA NO puede escalar a 0 (minReplicas=1)
# Pero con replicas=0 manual, los pods desaparecen

# Karpenter (con consolidation habilitado) detecta nodos subutilizados
# Esperar 30-60s → el nodo extra se drainea y termina
kubectl get nodes -w
```

### PDB: proteger la disponibilidad durante el drain

```yaml
# manifests/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: data-store-pdb
  namespace: apps
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: data-store
```

```bash
kubectl apply -f manifests/pdb.yaml

# Ahora si Karpenter intenta drenar un nodo con pods de data-store,
# solo lo hará si al menos 2 de 3 réplicas siguen disponibles.
```

---

## Parte 4: reclaimPolicy y el volumen fantasma

### ¿Qué pasa cuando borras un PVC?

```bash
# StorageClass con reclaimPolicy: Delete (el default)
kubectl get sc gp3 -o yaml | grep reclaimPolicy
# reclaimPolicy: Delete

# Si borras un PVC, el PV y el EBS volume se borran automáticamente.
# PERO si el PVC pertenece a un StatefulSet y borras el StatefulSet sin borrar PVCs:
kubectl delete statefulset data-store -n apps
kubectl get pvc -n apps
# Los PVCs siguen ahí. Los volúmenes EBS siguen cobrando.
```

### ¿Por qué esto es un problema de costos?

Los `volumeClaimTemplates` de un StatefulSet crean PVCs que NO se borran con el
StatefulSet. Debes borrarlos explícitamente:

```bash
kubectl delete pvc -l app=data-store -n apps
```

Si olvidas esto, los volúmenes EBS siguen cobrando ~$0.08/GB/mes indefinidamente.
En el lab 13 (FinOps) verás cómo detectar estos volúmenes huérfanos.

---

## Parte 5: Backup con Velero

### Paso 5.1: Instalar Velero

```bash
# Bucket para backups
VELERO_BUCKET="velero-backups-${ACCOUNT_ID}-${REGION}"
aws s3 mb s3://$VELERO_BUCKET --region $REGION

# Instalar con Helm
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

helm install velero vmware-tanzu/velero \
  --namespace velero --create-namespace \
  --set configuration.provider=aws \
  --set configuration.backupStorageLocation.bucket=$VELERO_BUCKET \
  --set configuration.backupStorageLocation.config.region=$REGION \
  --set configuration.volumeSnapshotLocation.config.region=$REGION \
  --set initContainers[0].name=velero-plugin-for-aws \
  --set initContainers[0].image=velero/velero-plugin-for-aws:v1.9.0 \
  --set initContainers[0].volumeMounts[0].name=plugins \
  --set initContainers[0].volumeMounts[0].mountPath=/target \
  --set credentials.useSecret=false \
  --set serviceAccount.server.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${ACCOUNT_ID}:role/velero-role"
```

> **Nota:** Necesitas crear el role `velero-role` con permisos de S3 + EC2 snapshots.
> Sigue el mismo patrón de IRSA del lab 05.

### Paso 5.2: Hacer backup del namespace

```bash
velero backup create apps-backup --include-namespaces apps --wait
velero backup describe apps-backup
```

### Paso 5.3: Destruir y recuperar

```bash
# Simular desastre
kubectl delete namespace apps

# Verificar que todo desapareció
kubectl get all -n apps
# No resources found

# Restaurar
velero restore create --from-backup apps-backup --wait

# Verificar
kubectl get all -n apps
kubectl get pvc -n apps
# Todo de vuelta, incluyendo los volúmenes
```

### EBS snapshot vs Velero backup

| Aspecto             | EBS Snapshot directo        | Velero backup                        |
| ------------------- | --------------------------- | ------------------------------------ |
| **Qué incluye**     | Solo el volumen (datos)     | Manifiestos YAML + datos (snapshots) |
| **Portabilidad**    | Misma AZ/región             | Cross-región con bucket replication  |
| **Granularidad**    | Por volumen                 | Por namespace, por label, completo   |
| **Restaurar**       | Manual (crear PV, PVC, pod) | Un comando (`velero restore`)        |
| **App consistency** | Crash-consistent            | Puede usar hooks pre/post            |

---

## Troubleshooting

| Síntoma                            | Causa probable                            | Fix                                                    |
| ---------------------------------- | ----------------------------------------- | ------------------------------------------------------ |
| PVC en estado `Pending`            | StorageClass no existe o CSI no instalado | `kubectl describe pvc` → ver evento                    |
| Pod Pending por volumen en otra AZ | `Immediate` binding eligió AZ incorrecta  | Usar `WaitForFirstConsumer`                            |
| HPA muestra `<unknown>/50%`        | metrics-server no instalado o no reporta  | `kubectl top pods` — si falla, instalar metrics-server |
| Nodos nuevos no aparecen           | Karpenter sin NodePool o sin capacidad    | `kubectl logs -n kube-system deploy/karpenter`         |
| Velero backup en PartiallyFailed   | Permisos de S3 o snapshot insuficientes   | `velero backup logs apps-backup`                       |
| EBS volume no se borra con PVC     | `reclaimPolicy: Retain` en StorageClass   | Borrar PV manualmente + volumen en EC2                 |

---

## 🔴 Destruir recursos del lab

```bash
# Kubernetes
kubectl delete namespace apps

# PVCs huérfanos (verificar)
kubectl get pvc --all-namespaces

# Velero
helm uninstall velero -n velero
kubectl delete namespace velero
aws s3 rb s3://$VELERO_BUCKET --force

# EFS
for MT in $(aws efs describe-mount-targets --file-system-id $EFS_ID --region $REGION \
  --query "MountTargets[].MountTargetId" --output text); do
  aws efs delete-mount-target --mount-target-id $MT --region $REGION
done
sleep 30
aws efs delete-file-system --file-system-id $EFS_ID --region $REGION

# Security group
aws ec2 delete-security-group --group-id $EFS_SG --region $REGION

# Verificar volúmenes EBS huérfanos
aws ec2 describe-volumes --filters Name=status,Values=available --region $REGION \
  --query "Volumes[?Tags[?Key=='kubernetes.io/created-for/pvc/namespace']].[VolumeId,Size,CreateTime]" \
  --output table

# Borrar si hay
# aws ec2 delete-volume --volume-id vol-xxx --region $REGION
```

---

## Lecciones aprendidas

1. **EBS ata un pod a una AZ.** No hay magia — un volumen de bloque es físico y
   está en un datacenter específico. Tu pod va a donde está su disco. Diseña con
   esto en mente.

2. **El HPA no escala nodos.** Solo crea pods. Los pods quedan en Pending hasta
   que Karpenter/CA reacciona. Son dos controladores distintos con loops distintos.

3. **`WaitForFirstConsumer` no es un default arbitrario.** Resuelve el problema
   más común de storage en multi-AZ. Cambiarlo a `Immediate` casi siempre es un
   error.

4. **Los PVCs de StatefulSets son huérfanos silenciosos.** Borrar el StatefulSet
   no borra sus PVCs. Es por diseño (protege datos), pero si no lo sabes, pagas
   por volúmenes que nadie usa.

5. **Velero resuelve el "borré el namespace por accidente".** Un snapshot de EBS
   te devuelve los datos pero no los manifiestos. Velero te devuelve todo: el
   namespace, los deployments, los services, Y los datos.

6. **El autoscaling real tarda 2 minutos.** No es instantáneo. Si tu aplicación
   tiene picos repentinos, necesitas réplicas mínimas suficientes para absorber
   el inicio del pico mientras el sistema escala.
