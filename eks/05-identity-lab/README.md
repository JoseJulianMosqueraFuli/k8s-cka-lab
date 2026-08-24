# Lab 05: Identidad y permisos — IRSA vs EKS Pod Identity

## Resumen

Tu pod necesita leer un objeto de S3. Lo logras de dos formas: IRSA (el método
clásico con OIDC) y EKS Pod Identity (el nuevo método sin OIDC). Comparas ambos
lado a lado: qué escribes, qué se rompe, qué es más fácil de auditar.

Además, configuras Access Entries para gestionar quién puede usar `kubectl` contra
el cluster — el reemplazo del infame `aws-auth` ConfigMap.

**Se monta sobre:** el cluster del lab 02 (EC2).
**Costo estimado adicional:** ~$0.01/hr (S3 negligible, no hay infra nueva)
**Tiempo:** ~1h 30m

**Herramientas necesarias:**

- AWS CLI v2
- kubectl
- La imagen `identity-api` del lab 04 ya en ECR

**Conexión CKA:** `domains/01-cluster-architecture` — RBAC, ServiceAccounts (25% del examen)

---

## Qué vas a construir

```
Pod (identity-api)
  ├─ ServiceAccount con anotación (IRSA)     → AssumeRoleWithWebIdentity → IAM Role → S3
  └─ ServiceAccount con asociación (Pod Identity) → AssumeRole → IAM Role → S3

Bucket S3
  └─ lab-data/
       └─ secret.txt   ← el pod lo lee y devuelve el contenido
```

---

## Paso 1: Crear el bucket S3 y el objeto de prueba

```bash
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="k8s-lab-identity-${ACCOUNT_ID}-${REGION}"

aws s3 mb s3://$BUCKET_NAME --region $REGION

echo "Este texto lo leyó el pod desde S3" | \
  aws s3 cp - s3://$BUCKET_NAME/lab-data/secret.txt
```

### ¿Por qué un bucket con el Account ID en el nombre?

Los nombres de bucket S3 son globales. Incluir el Account ID evita colisiones si
alguien más sigue este lab.

---

## Paso 2: Crear la política IAM de mínimo privilegio

```bash
cat > s3-read-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/lab-data/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["lab-data/*"]
        }
      }
    }
  ]
}
EOF

POLICY_ARN=$(aws iam create-policy \
  --policy-name eks-lab-s3-reader \
  --policy-document file://s3-read-policy.json \
  --query Policy.Arn --output text)

echo "Policy: $POLICY_ARN"
```

### ¿Por qué no `s3:*` o `Resource: "*"`?

| Política                               | Riesgo                                                       |
| -------------------------------------- | ------------------------------------------------------------ |
| `s3:*` sobre `*`                       | El pod puede borrar cualquier bucket de la cuenta            |
| `s3:GetObject` sobre `bucket/*`        | El pod lee cualquier carpeta del bucket                      |
| `s3:GetObject` sobre `bucket/prefix/*` | El pod solo lee lo que necesita — **mínimo privilegio real** |

Un principio es que si un atacante compromete el pod, solo puede leer archivos
bajo `lab-data/`. No el bucket entero, no otros buckets.

---

## Paso 3: Método A — IRSA (IAM Roles for Service Accounts)

### 3.1 Verificar el OIDC Provider

```bash
CLUSTER_NAME=eks-ec2-lab

# El OIDC provider ya existe si creaste el cluster con eksctl o lo habilitaste
OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

echo "OIDC: $OIDC_ID"

# Verificar que existe en IAM
aws iam list-open-id-connect-providers | grep $(echo $OIDC_ID | cut -d'/' -f2)
```

Si no aparece:

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster $CLUSTER_NAME --region $REGION --approve
```

### 3.2 Crear el IAM Role con trust policy IRSA

```bash
NAMESPACE=apps
SERVICE_ACCOUNT=identity-api-irsa

cat > trust-policy-irsa.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ID}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}",
          "${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

ROLE_IRSA=eks-lab-s3-reader-irsa

aws iam create-role \
  --role-name $ROLE_IRSA \
  --assume-role-policy-document file://trust-policy-irsa.json

aws iam attach-role-policy \
  --role-name $ROLE_IRSA \
  --policy-arn $POLICY_ARN
```

### ¿Por qué la condición `sub` es tan específica?

La condición `system:serviceaccount:apps:identity-api-irsa` garantiza que **solo**
ese ServiceAccount en ese namespace puede asumir el rol. Sin esa condición,
cualquier ServiceAccount del cluster podría hacerlo.

### 3.3 Crear el ServiceAccount anotado

```yaml
# manifests/sa-irsa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: identity-api-irsa
  namespace: apps
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/eks-lab-s3-reader-irsa
```

```bash
# Reemplaza <ACCOUNT_ID> con tu valor
sed -i "s/<ACCOUNT_ID>/$ACCOUNT_ID/" manifests/sa-irsa.yaml
kubectl apply -f manifests/sa-irsa.yaml
```

### 3.4 Deploy usando IRSA

```yaml
# manifests/deploy-irsa.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: identity-api-irsa
  namespace: apps
spec:
  replicas: 1
  selector:
    matchLabels:
      app: identity-api-irsa
  template:
    metadata:
      labels:
        app: identity-api-irsa
    spec:
      serviceAccountName: identity-api-irsa
      containers:
        - name: api
          image: <TU_IMAGE>
          ports:
            - containerPort: 8080
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: S3_BUCKET
              value: <TU_BUCKET>
            - name: S3_KEY
              value: lab-data/secret.txt
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
```

```bash
kubectl apply -f manifests/deploy-irsa.yaml
```

### ¿Cómo funciona IRSA por dentro?

1. El mutating webhook de EKS inyecta un token JWT projected volume en el pod
2. El pod envía ese token a STS con `AssumeRoleWithWebIdentity`
3. STS valida el token contra el OIDC provider del cluster
4. Si la condición `sub` coincide, STS devuelve credenciales temporales

```bash
# Ver las variables inyectadas
kubectl exec -n apps deploy/identity-api-irsa -- env | grep AWS
# AWS_ROLE_ARN=arn:aws:iam::...:role/eks-lab-s3-reader-irsa
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

---

## Paso 4: Método B — EKS Pod Identity

### 4.1 Instalar el add-on (si no está)

```bash
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name eks-pod-identity-agent \
  --region $REGION

# Esperar
aws eks wait addon-active \
  --cluster-name $CLUSTER_NAME \
  --addon-name eks-pod-identity-agent \
  --region $REGION
```

### 4.2 Crear el IAM Role con trust policy para Pod Identity

```bash
ROLE_POD_ID=eks-lab-s3-reader-podid

cat > trust-policy-podid.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF

aws iam create-role \
  --role-name $ROLE_POD_ID \
  --assume-role-policy-document file://trust-policy-podid.json

aws iam attach-role-policy \
  --role-name $ROLE_POD_ID \
  --policy-arn $POLICY_ARN
```

### ¿Por qué la trust policy es más simple?

Con Pod Identity, no necesitas el OIDC provider en la trust policy. El principal
es `pods.eks.amazonaws.com` — un servicio de AWS que gestiona la asociación. La
granularidad (qué ServiceAccount puede asumir qué rol) se define en la
**asociación**, no en la trust policy.

### 4.3 Crear la asociación

```bash
SERVICE_ACCOUNT_POD_ID=identity-api-podid

aws eks create-pod-identity-association \
  --cluster-name $CLUSTER_NAME \
  --namespace $NAMESPACE \
  --service-account $SERVICE_ACCOUNT_POD_ID \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_POD_ID} \
  --region $REGION
```

### 4.4 Deploy usando Pod Identity

```yaml
# manifests/sa-podid.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: identity-api-podid
  namespace: apps
---
# manifests/deploy-podid.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: identity-api-podid
  namespace: apps
spec:
  replicas: 1
  selector:
    matchLabels:
      app: identity-api-podid
  template:
    metadata:
      labels:
        app: identity-api-podid
    spec:
      serviceAccountName: identity-api-podid
      containers:
        - name: api
          image: <TU_IMAGE>
          ports:
            - containerPort: 8080
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: S3_BUCKET
              value: <TU_BUCKET>
            - name: S3_KEY
              value: lab-data/secret.txt
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
```

```bash
kubectl apply -f manifests/sa-podid.yaml
kubectl apply -f manifests/deploy-podid.yaml
```

---

## Paso 5: Verificar ambos métodos

```bash
# IRSA
kubectl port-forward -n apps deploy/identity-api-irsa 8080:8080 &
curl -s http://localhost:8080/identity | jq .
# → ARN del rol eks-lab-s3-reader-irsa, sin error
curl -s http://localhost:8080/s3 | jq .
# → content: "Este texto lo leyó el pod desde S3"
kill %1

# Pod Identity
kubectl port-forward -n apps deploy/identity-api-podid 8080:8080 &
curl -s http://localhost:8080/identity | jq .
curl -s http://localhost:8080/s3 | jq .
kill %1
```

Ambos métodos deben devolver el ARN del rol correspondiente sin error, y `/s3`
debe devolver el contenido del objeto que subiste en el paso 1. Ahí se ejercita de
verdad la policy de mínimo privilegio: el pod hizo `s3:GetObject` sobre
`lab-data/secret.txt` con su rol acotado, no con las credenciales del nodo.

---

## Paso 6: Comparación lado a lado

| Aspecto                 | IRSA                                   | EKS Pod Identity                         |
| ----------------------- | -------------------------------------- | ---------------------------------------- |
| **OIDC provider**       | Necesario (uno por cluster)            | No necesario                             |
| **Trust policy**        | Referencia al OIDC con condición `sub` | Principal `pods.eks.amazonaws.com`       |
| **Granularidad**        | En la trust policy (condición)         | En la asociación (API de EKS)            |
| **Anotación en SA**     | `eks.amazonaws.com/role-arn`           | No necesaria                             |
| **Cross-account**       | Complejo (OIDC trusts)                 | Más simple                               |
| **Auditoría**           | Leer trust policies de cada rol        | `aws eks list-pod-identity-associations` |
| **Antigüedad**          | GA desde 2019                          | GA desde 2023                            |
| **Requiere add-on**     | No (webhook viene con EKS)             | Sí (`eks-pod-identity-agent`)            |
| **Funciona en Fargate** | Sí                                     | Sí (desde 2024)                          |

### ¿Cuál usar?

- **Cluster nuevo:** Pod Identity. Más simple, la auditoría está centralizada.
- **Cluster existente con IRSA:** No hay urgencia de migrar. Ambos coexisten.
- **Cross-account complejo:** Pod Identity simplifica los trusts.

---

## Paso 7: Romper cosas a propósito

### 7.1 Trust policy con `sub` incorrecto (IRSA)

```bash
# Cambiar el namespace en la trust policy
aws iam update-assume-role-policy \
  --role-name $ROLE_IRSA \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Federated": "arn:aws:iam::'$ACCOUNT_ID':oidc-provider/'$OIDC_ID'"},
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "'$OIDC_ID':sub": "system:serviceaccount:wrong-namespace:identity-api-irsa",
          "'$OIDC_ID':aud": "sts.amazonaws.com"
        }
      }
    }]
  }'
```

Reinicia el pod y verifica:

```bash
kubectl rollout restart deploy/identity-api-irsa -n apps
kubectl port-forward -n apps deploy/identity-api-irsa 8080:8080 &
curl -s http://localhost:8080/identity | jq .
curl -s http://localhost:8080/s3 | jq .
kill %1
```

Verás en `/identity`: `"error": "sts:AssumeRoleWithWebIdentity failed: AccessDenied"`.
Y en `/s3`: `"error": "s3:GetObject failed: ... AccessDenied"`. El `sub` bloqueó
la obtención de credenciales, así que S3 ni siquiera llega a intentarse.

**Lección:** el `sub` actúa como una llave. Si no coincide exactamente
(namespace + nombre del SA), no hay credenciales.

### 7.2 Pod sin ServiceAccount

```bash
kubectl run naked-pod --image=<TU_IMAGE> -n apps \
  --env="POD_NAME=naked" --env="NODE_NAME=test" --env="POD_NAMESPACE=apps" \
  --env="S3_BUCKET=$BUCKET_NAME" --env="S3_KEY=lab-data/secret.txt"

kubectl port-forward -n apps pod/naked-pod 8080:8080 &
curl -s http://localhost:8080/identity | jq .
curl -s http://localhost:8080/s3 | jq .
kill %1
kubectl delete pod naked-pod -n apps
```

Resultado: `"error": "no credentials available"` en ambos endpoints. Un pod sin
ServiceAccount específico usa el SA `default`, que no tiene ninguna asociación.

### 7.3 Leer el error STS completo

```bash
# Forzar un error de permisos en S3 (si agregaste un endpoint de lectura S3)
# O verificar con AWS CLI desde tu máquina:
aws sts assume-role-with-web-identity \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_IRSA} \
  --role-session-name test \
  --web-identity-token "invalid-token"
```

El error incluye: `An error occurred (InvalidIdentityToken)`. Aprender a leer estos
mensajes es la habilidad real — no solo copiar comandos.

---

## Paso 8: Access Entries — la gestión humana

### ¿Por qué ya no `aws-auth` ConfigMap?

| Aspecto             | `aws-auth` ConfigMap         | Access Entries (API)           |
| ------------------- | ---------------------------- | ------------------------------ |
| **Dónde vive**      | Dentro del cluster           | API de EKS (fuera del cluster) |
| **Si borras el CM** | Te quedas fuera del cluster  | No aplica — es API de AWS      |
| **Auditoría**       | `kubectl get cm` (si puedes) | CloudTrail                     |
| **Automatización**  | Editar YAML manualmente      | `aws eks create-access-entry`  |
| **Riesgo**          | Alto (un typo = lockout)     | Bajo (la API valida)           |

### Crear un Access Entry

```bash
# Dar acceso a un rol IAM como admin del cluster
USER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/mi-rol-de-admin"

aws eks create-access-entry \
  --cluster-name $CLUSTER_NAME \
  --principal-arn $USER_ROLE_ARN \
  --type STANDARD \
  --region $REGION

aws eks associate-access-policy \
  --cluster-name $CLUSTER_NAME \
  --principal-arn $USER_ROLE_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region $REGION
```

### Políticas disponibles

| Política EKS                  | Equivale a (Kubernetes) |
| ----------------------------- | ----------------------- |
| `AmazonEKSClusterAdminPolicy` | `cluster-admin`         |
| `AmazonEKSAdminPolicy`        | `admin` (namespaced)    |
| `AmazonEKSEditPolicy`         | `edit`                  |
| `AmazonEKSViewPolicy`         | `view`                  |

---

## Troubleshooting

| Síntoma                                | Causa probable                                  | Fix                                                          |
| -------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------ |
| `AccessDenied` en STS                  | Trust policy `sub` no coincide                  | Verificar namespace y nombre del SA exacto                   |
| `/s3` da AccessDenied pero `/identity` funciona | La policy `s3-read-policy.json` no cubre el bucket/prefix | Revisar `Resource` y la condición `s3:prefix`     |
| Pod no tiene variables `AWS_*`         | ServiceAccount sin anotación (IRSA)             | Agregar `eks.amazonaws.com/role-arn`                         |
| `could not get token` con Pod Identity | Add-on no instalado                             | `aws eks describe-addon --addon-name eks-pod-identity-agent` |
| Credenciales del nodo en vez del rol   | `hostNetwork: true` o IMDS hop limit incorrecto | Verificar spec del pod y node metadata options               |
| "the server has asked for credentials" | Access Entry faltante para tu usuario IAM       | `aws eks list-access-entries --cluster-name ...`             |

---

## 🔴 Destruir recursos del lab

```bash
# Kubernetes
kubectl delete -f manifests/
kubectl delete namespace apps 2>/dev/null

# Asociación Pod Identity
aws eks delete-pod-identity-association \
  --cluster-name $CLUSTER_NAME \
  --association-id $(aws eks list-pod-identity-associations \
    --cluster-name $CLUSTER_NAME --region $REGION \
    --query "associations[0].associationId" --output text) \
  --region $REGION

# Roles IAM
aws iam detach-role-policy --role-name $ROLE_IRSA --policy-arn $POLICY_ARN
aws iam delete-role --role-name $ROLE_IRSA
aws iam detach-role-policy --role-name $ROLE_POD_ID --policy-arn $POLICY_ARN
aws iam delete-role --role-name $ROLE_POD_ID
aws iam delete-policy --policy-arn $POLICY_ARN

# S3
aws s3 rb s3://$BUCKET_NAME --force

# Add-on (opcional — dejarlo si vas a usar Pod Identity en otros labs)
aws eks delete-addon --cluster-name $CLUSTER_NAME \
  --addon-name eks-pod-identity-agent --region $REGION

# Restaurar trust policy si la rompiste en paso 7
```

---

## Lecciones aprendidas

1. **IRSA y Pod Identity resuelven el mismo problema de formas distintas.** IRSA
   usa OIDC federation (estándar abierto). Pod Identity usa un servicio AWS nativo.
   El resultado es el mismo: credenciales temporales y acotadas en el pod.

2. **La trust policy es la defensa real.** Sin la condición `sub` correcta (IRSA)
   o sin la asociación (Pod Identity), no hay credenciales. Es mejor que IMDS
   porque el blast radius es un ServiceAccount, no un nodo entero.

3. **Access Entries eliminan el riesgo de lockout.** Con `aws-auth`, un error de
   edición te dejaba fuera del cluster. Con Access Entries, la gestión está fuera
   del cluster — no puedes romper tu propio acceso editando un ConfigMap.

4. **Mínimo privilegio no es `s3:*`.** Es `s3:GetObject` sobre un prefix
   específico. Si te cuesta escribirlo, herramientas como IAM Access Analyzer
   generan la política basándose en actividad real.

5. **Aprender a leer errores STS es más valioso que memorizar comandos.** El
   mensaje `AccessDenied` + el contexto del trust te dice exactamente qué
   condición falló. Es debugging real.
