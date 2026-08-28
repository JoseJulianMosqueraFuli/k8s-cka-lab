# Lab 09: Infraestructura como código + GitOps + entrega

## Resumen

Tres mitades, aunque suene raro: infra con IaC (eksctl + Terraform), **empaquetado
de la app** (un chart de Helm escrito por ti y overlays de Kustomize), y apps con
GitOps (Argo CD + Argo Rollouts). El momento revelador: haces `kubectl scale` a mano
y Argo lo revierte. Declarativo significa que el repo es la fuente de verdad, no tu
terminal.

Además: CI/CD pipeline completa desde un commit hasta un canary deployment con
promoción automática basada en métricas.

**Se monta sobre:** el cluster del lab 03 (Auto Mode) o un cluster Terraform nuevo.
**Costo estimado adicional:** ~$0.05/hr (Argo CD es solo pods, pipeline usa GitHub Actions)
**Tiempo:** ~4h 30m (el lab más largo)

> **Se puede partir en dos sesiones.** Partes 1-3 (IaC + empaquetado) son offline
> casi por completo y no necesitan el cluster prendido más que para validar. Partes
> 4-6 (Argo CD, pipeline, canary) sí. Si lo cortas, córtalo ahí y destruye el
> cluster en el medio.

**Herramientas necesarias:**

- AWS CLI v2
- kubectl (trae Kustomize integrado: `kubectl -k`)
- helm, más el plugin [helm-diff](https://github.com/databus23/helm-diff)
- yq (para que el pipeline edite YAML sin `sed`)
- terraform (>= 1.5)
- argocd CLI
- Un repositorio Git (GitHub, GitLab, CodeCommit)

**Conexión CKA:** `domains/02-workloads` — Deployments, rolling updates, rollback (15%)

---

## Qué vas a construir

```
┌────────── IaC (Terraform) ──────────┐     ┌────── GitOps (Argo CD) ──────┐
│                                      │     │                               │
│  S3 backend → plan → PR review →    │     │  Git repo ──sync──→ cluster   │
│  apply → EKS cluster + add-ons      │     │       ↑                ↓      │
│                                      │     │  CI/CD builds    Argo detects │
└──────────────────────────────────────┘     │  push manifest   drift →      │
                                             │                   reverts      │
        ┌──── Empaquetado ────┐              │                               │
        │  chart Helm         │              │  Argo Rollouts: canary 10% →  │
        │  + values por amb.  │──apunta a───→│  metrics OK → promote 100%    │
        │  base/ + overlays/  │              └───────────────────────────────┘
        └─────────────────────┘
             un archivo por ambiente,
             no un manifest por ambiente
```

---

## Parte 1: IaC con eksctl (warm-up)

### ¿Por qué empezar con eksctl?

eksctl es declarativo a nivel archivo (`cluster.yaml`) pero imperativo en
ejecución (`eksctl create`). No tiene state file ni plan. Es perfecto para
entender que "declarativo" no es magia — es un archivo que describe el estado
deseado, pero la herramienta que lo aplica importa.

### El archivo del cluster

```yaml
# infra/eksctl/cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: eks-gitops-lab
  region: us-east-1
  version: "1.36"

managedNodeGroups:
  - name: workers
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 4
    volumeSize: 30
    iam:
      withAddonPolicies:
        ebs: true
        efs: true

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver

iam:
  withOIDC: true
```

```bash
eksctl create cluster -f infra/eksctl/cluster.yaml
```

### Limitaciones de eksctl como IaC

| Aspecto         | eksctl                         | Terraform                         |
| --------------- | ------------------------------ | --------------------------------- |
| State           | No tiene (lee de AWS cada vez) | State file (S3 + DynamoDB lock)   |
| Plan            | No existe                      | `terraform plan` antes de apply   |
| Dependencias    | Solo EKS                       | Cualquier recurso AWS             |
| Modules/reuse   | No                             | Sí (modules, workspaces)          |
| PR review       | Solo review del YAML           | Review del plan (cambios exactos) |
| Drift detection | `eksctl utils describe-stacks` | `terraform plan` muestra drift    |

eksctl es bueno para labs y clusters de un solo equipo. Terraform es para
producción multi-equipo con governance.

---

## Parte 2: IaC con Terraform

### Paso 2.1: Backend en S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="terraform-state-${ACCOUNT_ID}-us-east-1"

aws s3 mb s3://$BUCKET --region us-east-1
aws s3api put-bucket-versioning --bucket $BUCKET --versioning-configuration Status=Enabled

# DynamoDB para locking
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### ¿Por qué S3 + DynamoDB?

- **S3:** guarda el state file (qué recursos existen, su estado actual)
- **Versionado:** puedes recuperar un state anterior si se corrompe
- **DynamoDB:** locking — solo una persona puede hacer `apply` a la vez. Sin
  esto, dos applies simultáneos pueden crear recursos duplicados o corromper el state

### Paso 2.2: Configuración Terraform

```hcl
# infra/terraform/main.tf
terraform {
  required_version = ">= 1.5"

  backend "s3" {
    bucket         = "terraform-state-ACCOUNT_ID-us-east-1"
    key            = "eks/gitops-lab/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  default = "us-east-1"
}

variable "cluster_name" {
  default = "eks-gitops-lab"
}
```

```hcl
# infra/terraform/eks.tf
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.36"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    workers = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 4
      desired_size   = 2
    }
  }

  # Add-ons
  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
  }

  # Access Entries
  enable_cluster_creator_admin_permissions = true

  tags = {
    Environment = "lab"
    Lab         = "09-iac-gitops"
    ManagedBy   = "terraform"
  }
}
```

```hcl
# infra/terraform/vpc.tf
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true  # Solo 1 para el lab (ahorra $0.045/hr)
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
```

### Paso 2.3: Plan y Apply

```bash
cd infra/terraform

terraform init
terraform plan -out=tfplan

# REVISAR el plan — esto es lo que se revisa en un PR
# El plan muestra exactamente qué se va a crear/modificar/destruir

terraform apply tfplan
```

### ¿Por qué el plan se revisa en PR?

```
PR workflow:
1. Desarrollador modifica *.tf
2. CI ejecuta terraform plan
3. El plan se pega como comentario en el PR
4. Reviewer ve: "va a crear 1 VPC, 2 subnets, 1 cluster EKS, 2 node groups"
5. Aprueba → merge → CD ejecuta terraform apply
```

Sin plan review, un `terraform apply` puede destruir un cluster de producción
porque alguien cambió el nombre sin darse cuenta.

---

## Parte 3: Empaquetado — un chart propio y overlays de Kustomize

### El problema que ni Terraform ni Argo resuelven

Terraform ya dejó el cluster declarado. Argo CD (Parte 4) va a sincronizar lo que
haya en el repo. Pero entre las dos cosas queda una pregunta sin responder: **¿qué
hay exactamente en el repo?**

Si la respuesta es "manifests planos", el problema aparece con el segundo ambiente:

```
apps/
├── identity-api-dev/deployment.yaml      # replicas: 1, requests: 50m
├── identity-api-staging/deployment.yaml  # replicas: 2, requests: 100m
└── identity-api-prod/deployment.yaml     # replicas: 5, requests: 500m
```

Tres archivos casi idénticos. Cambias el puerto del contenedor y tienes que
acordarte de cambiarlo tres veces. A los seis meses divergieron y nadie sabe cuál
es el correcto.

Esto importa porque es **el drift del que GitOps no te protege**. Argo compara el
cluster contra el repo, y si el repo tiene tres archivos inconsistentes, Argo
sincroniza fielmente la inconsistencia. La fuente de verdad puede estar equivocada
y el sistema seguiría reportando `Synced`.

Hay dos respuestas en el ecosistema. Vale escribir las dos antes de elegir.

### Paso 3.1: Un chart de Helm escrito por ti

Hasta aquí usaste Helm solo como consumidor: `helm install argocd argo/argo-cd`.
Escribir uno cambia lo que entiendes de todos los demás — incluido por qué el
`--set` de los labs anteriores funciona como funciona.

```bash
helm create identity-api
```

El scaffold trae más de lo necesario. Lo que importa:

```
charts/identity-api/
├── Chart.yaml           # nombre, versión del chart, versión de la app
├── values.yaml          # los valores por defecto
├── values-dev.yaml      # sobrescribe lo que cambia en dev
├── values-prod.yaml     # sobrescribe lo que cambia en prod
└── templates/
    ├── _helpers.tpl     # funciones de nombres y labels reutilizables
    ├── deployment.yaml
    └── service.yaml
```

El template deja de ser YAML y pasa a ser un Go template que **produce** YAML:

```yaml
# charts/identity-api/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: { { include "identity-api.fullname" . } }
  labels: { { - include "identity-api.labels" . | nindent 4 } }
spec:
  replicas: { { .Values.replicaCount } }
  selector:
    matchLabels: { { - include "identity-api.selectorLabels" . | nindent 6 } }
  template:
    metadata:
      labels: { { - include "identity-api.selectorLabels" . | nindent 8 } }
    spec:
      containers:
        - name: { { .Chart.Name } }
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: { { .Values.service.targetPort } }
          resources: { { - toYaml .Values.resources | nindent 12 } }
```

```yaml
# charts/identity-api/values.yaml — los defaults
replicaCount: 2

image:
  repository: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/k8s-lab/identity-api
  tag: "" # lo inyecta el pipeline con el SHA del commit. Nunca "latest"

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

resources:
  requests:
    cpu: 50m
    memory: 32Mi
  limits:
    cpu: 200m
    memory: 64Mi
```

```yaml
# charts/identity-api/values-prod.yaml — solo lo que cambia
replicaCount: 5

resources:
  requests:
    cpu: 500m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 512Mi
```

Un archivo describe la forma, otro describe las diferencias. El puerto vive en un
solo lugar.

### Paso 3.2: Renderizar antes de aplicar

Esta es la herramienta que más vas a usar y la que no aparece en los tutoriales:

```bash
# Renderiza el YAML final sin tocar el cluster
helm template identity-api ./charts/identity-api -f charts/identity-api/values-prod.yaml

# Igual pero validando contra el API server (detecta CRDs faltantes, campos inválidos)
helm install identity-api ./charts/identity-api --dry-run --debug \
  -f charts/identity-api/values-prod.yaml
```

Un error de indentación en un template no produce "error de indentación": produce
YAML válido que significa otra cosa. `helm template` es donde lo ves.

### Paso 3.3: Instalar, actualizar y volver atrás

```bash
# Instalar
helm install identity-api ./charts/identity-api \
  -n apps --create-namespace \
  -f charts/identity-api/values-prod.yaml \
  --set image.tag=abc1234 \
  --atomic --timeout 5m

# Ver qué cambiaría antes de cambiarlo (requiere el plugin helm-diff)
helm plugin install https://github.com/databus23/helm-diff
helm diff upgrade identity-api ./charts/identity-api \
  -n apps -f charts/identity-api/values-prod.yaml --set image.tag=def5678

# Actualizar
helm upgrade identity-api ./charts/identity-api \
  -n apps -f charts/identity-api/values-prod.yaml \
  --set image.tag=def5678 --atomic --timeout 5m

# Historial y rollback
helm history identity-api -n apps
helm rollback identity-api 1 -n apps
```

**`--atomic` no es opcional.** Sin él, un `helm upgrade` que falla a mitad de camino
te deja el release en estado `failed` con parte de los recursos nuevos y parte
viejos. Con `--atomic`, Helm revierte solo. Es la diferencia entre un despliegue
fallido y un incidente.

Dos trampas de Helm que se pagan tarde:

- **Las listas se reemplazan, no se fusionan.** Si `values.yaml` define tres
  variables de entorno y `values-prod.yaml` define una, en prod queda **una**. Los
  mapas sí se fusionan. Es la causa número uno de "en prod le faltaba una variable".
- **`helm rollback` depende del historial en el cluster**, guardado en Secrets del
  namespace. Si alguien borra esos Secrets, el rollback no existe. Cuando Argo CD
  maneja el chart, el rollback real es un revert en Git.

### Paso 3.4: Lo mismo con Kustomize

Kustomize ataca el problema al revés: no hay lenguaje de templates. Hay YAML real
y **parches** encima.

```
gitops-repo/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml        # YAML de Kubernetes válido, aplicable tal cual
│   └── service.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        ├── kustomization.yaml
        └── resources-patch.yaml
```

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

commonLabels:
  app: identity-api
```

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: apps-prod

resources:
  - ../../base

# Transformers: cambian campos sin escribir un parche
replicas:
  - name: identity-api
    count: 5

images:
  - name: identity-api
    newName: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/k8s-lab/identity-api
    newTag: abc1234

# Parche para lo que no tiene transformer
patches:
  - path: resources-patch.yaml
    target:
      kind: Deployment
      name: identity-api

# Genera un ConfigMap con sufijo de hash del contenido
configMapGenerator:
  - name: identity-api-config
    literals:
      - LOG_LEVEL=info
```

```yaml
# overlays/prod/resources-patch.yaml — strategic merge patch
apiVersion: apps/v1
kind: Deployment
metadata:
  name: identity-api
spec:
  template:
    spec:
      containers:
        - name: api
          resources:
            requests:
              cpu: 500m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
```

```bash
# Renderizar (el equivalente de helm template) — kustomize viene dentro de kubectl
kubectl kustomize overlays/prod

# Aplicar
kubectl apply -k overlays/prod

# Diff contra el cluster antes de aplicar
kubectl diff -k overlays/prod
```

**El `configMapGenerator` merece atención aparte.** Genera
`identity-api-config-<hash>` donde el hash sale del contenido, y reescribe las
referencias en el Deployment para que apunten al nombre con hash. Consecuencia: si
cambias un valor del ConfigMap, cambia el nombre, cambia el pod template, y los
pods **se reinician solos**. Con manifests planos, editar un ConfigMap no reinicia
nada y la app sigue corriendo con la configuración vieja — un clásico de "lo
cambié y no pasó nada".

La disciplina con Kustomize es renderizar antes de confiar. Un parche cuyo `target`
apunta a un nombre que no coincide puede no aplicar nada, y el resultado se ve
igual de sano. `kubectl kustomize` y un diff entre overlays es cómo lo confirmas.

### Paso 3.5: Cuál usar

| Aspecto                               | Helm                             | Kustomize                     |
| ------------------------------------- | -------------------------------- | ----------------------------- |
| Modelo                                | Templates + valores              | YAML real + parches           |
| Instalación                           | Binario aparte                   | Integrado en `kubectl -k`     |
| ¿Cada archivo es YAML válido?         | No, es un Go template            | Sí, se aplica tal cual        |
| Condicionales y ciclos                | Sí                               | No, por diseño                |
| Distribuir software a terceros        | Es el estándar de facto          | No tiene registry             |
| Historial y rollback propio           | `helm history` / `helm rollback` | No, eso lo da Git             |
| Reinicio automático al cambiar config | Requiere un truco de checksum    | Nativo (`configMapGenerator`) |
| Curva de aprendizaje                  | Más empinada                     | Más suave                     |

La regla que uso: **Helm para consumir software de otros, Kustomize para tu propia
app en varios ambientes.** Un chart existe para ser redistribuido y parametrizado
por gente que no lo escribió; tu app no necesita eso, necesita tres variantes de lo
mismo. Muchos equipos usan Helm para ambas cosas y funciona — pero si te encuentras
escribiendo `{{- if .Values.enabled }}` alrededor de recursos enteros, estás
construyendo un lenguaje de programación en YAML y Kustomize era la respuesta.

También se combinan: Kustomize puede tomar la salida de `helm template` como base y
parchearla. Es como se ajusta un chart de un tercero sin forkearlo.

### Paso 3.6: Por qué esto va antes de Argo CD

Porque Argo consume las dos cosas de forma nativa, y la Parte 4 va a apuntar a una
de ellas en vez de a manifests planos:

```yaml
# Con Helm: valueFiles en cascada
source:
  repoURL: https://github.com/<TU_USUARIO>/gitops-repo.git
  targetRevision: main
  path: charts/identity-api
  helm:
    valueFiles:
      - values.yaml
      - values-prod.yaml

# Con Kustomize: solo la ruta del overlay.
# Argo detecta el kustomization.yaml y lo renderiza solo
source:
  repoURL: https://github.com/<TU_USUARIO>/gitops-repo.git
  targetRevision: main
  path: overlays/prod
```

Un detalle que cambia el modelo mental: Argo **renderiza** el chart y aplica el
resultado. No corre `helm install`, así que no hay release de Helm ni historial de
Helm en el cluster. El historial es el de Git. Por eso `helm rollback` y GitOps son
dos respuestas al mismo problema y solo se usa una.

---

## Parte 4: GitOps con Argo CD

### Paso 4.1: Instalar Argo CD

```bash
kubectl create namespace argocd

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=LoadBalancer \
  --set configs.params."server\.insecure"=true

# Esperar
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=120s

# Password inicial
ARGO_PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d)

# URL
ARGO_URL=$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Argo CD: http://$ARGO_URL"
echo "User: admin / Pass: $ARGO_PASS"
```

### Paso 4.2: Estructura del repo

El repo ya no guarda manifests planos: guarda lo que empaquetaste en la Parte 3.
Aquí aparecen las dos variantes para poder compararlas, pero **un repo real elige
una**. Tener las dos es garantizar que se desincronicen.

```
gitops-repo/
├── charts/
│   └── identity-api/            # variante Helm (Paso 3.1)
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-dev.yaml
│       ├── values-prod.yaml
│       └── templates/
├── base/                        # variante Kustomize (Paso 3.4)
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
├── overlays/
│   ├── dev/kustomization.yaml
│   └── prod/kustomization.yaml
└── argocd/
    ├── application-helm.yaml
    └── application-kustomize.yaml
```

El `base/deployment.yaml` de la variante Kustomize es YAML plano y aplicable tal
cual — sin réplicas ni recursos específicos de ambiente, porque eso lo pone el
overlay:

```yaml
# gitops-repo/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: identity-api
spec:
  selector:
    matchLabels:
      app: identity-api
  template:
    metadata:
      labels:
        app: identity-api
    spec:
      containers:
        - name: api
          image: identity-api # el overlay reescribe nombre y tag
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
```

### Paso 4.3: Crear la Application en Argo

```yaml
# argocd/application-helm.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: identity-api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<TU_USUARIO>/gitops-repo.git
    targetRevision: main
    path: charts/identity-api
    helm:
      valueFiles:
        - values.yaml
        - values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

La variante Kustomize es la misma Application cambiando el `source`. No hace falta
declarar el plugin: Argo detecta el `kustomization.yaml` y lo renderiza.

```yaml
# argocd/application-kustomize.yaml (fragmento)
source:
  repoURL: https://github.com/<TU_USUARIO>/gitops-repo.git
  targetRevision: main
  path: overlays/prod
```

```bash
kubectl apply -f argocd/application-helm.yaml
```

### ¿Qué hace `selfHeal: true`?

Argo CD compara el estado del cluster con el repo cada 3 minutos. Si alguien
hace un cambio manual (`kubectl scale`, `kubectl edit`), Argo lo **revierte**
al estado del repo.

### Paso 4.4: El momento revelador — kubectl scale y Argo revierte

```bash
# Escalar manualmente
kubectl scale deploy identity-api -n apps --replicas=1

# Ver en Argo que detecta "OutOfSync"
argocd app get identity-api
# Status: OutOfSync (replica mismatch)

# Esperar ~3 minutos (o forzar)
argocd app sync identity-api

# Vuelve a 3 réplicas
kubectl get deploy identity-api -n apps
# READY   3/3
```

**Esto es GitOps:** el repo es la fuente de verdad. Si quieres escalar, haces un
commit que cambia `replicaCount` en `values-prod.yaml` (o el `count` del transformer
`replicas` en el overlay). No usas kubectl.

Nota de la Parte 3 que ahora se vuelve concreta: el valor que editas vive en **un**
archivo por ambiente. Sin el empaquetado, "escalar prod" sería editar un manifest
que es copia de otros dos, y la próxima persona no sabría si los otros dos también
había que tocarlos.

---

## Parte 5: CI/CD Pipeline

### El flujo completo

```
1. Developer push code → trigger CI
2. CI: build → test → scan → push image to ECR (tag: commit SHA)
3. CI: actualiza el tag en el empaquetado (values-prod.yaml u overlay)
4. CI: commit + push to gitops repo
5. Argo CD detects change → syncs → new pods with new image
```

El paso 3 es la costura entre el pipeline y GitOps, y es donde el empaquetado de la
Parte 3 se paga solo: el pipeline modifica **un campo en un archivo**, no un
manifest por ambiente.

### Ejemplo con GitHub Actions

```yaml
# .github/workflows/deploy.yaml
name: Build and Deploy
on:
  push:
    branches: [main]
    paths: ["app/**"]

env:
  AWS_REGION: us-east-1
  ECR_REPO: k8s-lab/identity-api
  GITOPS_REPO: your-user/gitops-repo

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/github-actions-role
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push
        env:
          IMAGE_TAG: ${{ github.sha }}
        run: |
          IMAGE=${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.${{ env.AWS_REGION }}.amazonaws.com/${{ env.ECR_REPO }}:${IMAGE_TAG:0:7}
          docker build -t $IMAGE app/
          docker push $IMAGE
          echo "IMAGE=$IMAGE" >> $GITHUB_ENV

      - name: Update gitops repo
        env:
          GH_TOKEN: ${{ secrets.GITOPS_TOKEN }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          git clone https://x-access-token:${GH_TOKEN}@github.com/${{ env.GITOPS_REPO }}.git /tmp/gitops
          cd /tmp/gitops

          # Variante Helm: yq cambia solo el campo, sin tocar el resto del archivo
          yq -i ".image.tag = \"${IMAGE_TAG:0:7}\"" charts/identity-api/values-prod.yaml

          # Variante Kustomize: el comando existe justo para esto
          # cd overlays/prod && kustomize edit set image identity-api=${{ env.IMAGE }}

          git config user.email "ci@lab.local"
          git config user.name "CI Pipeline"
          git add .
          git commit -m "deploy: identity-api ${GITHUB_SHA:0:7}"
          git push
```

Por qué `yq` y `kustomize edit` en vez del `sed` que se ve en todas partes: un
`sed -i "s|image:.*|...|"` reemplaza **todas** las líneas que empiecen con `image:`
en el archivo. Con un solo contenedor no se nota; con un sidecar o un initContainer,
el pipeline le cambia la imagen a los tres. Es un bug que aparece meses después de
escrito.

---

## Parte 6: Progressive Delivery con Argo Rollouts

### Paso 6.1: Instalar Argo Rollouts

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Plugin kubectl
# (descarga según tu OS desde https://github.com/argoproj/argo-rollouts/releases)
```

### Paso 6.2: Convertir Deployment a Rollout

```yaml
# gitops-repo/base/rollout.yaml (reemplaza a deployment.yaml en el base)
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: identity-api
  namespace: apps
spec:
  replicas: 5
  selector:
    matchLabels:
      app: identity-api
  template:
    metadata:
      labels:
        app: identity-api
    spec:
      containers:
        - name: api
          image: <TU_IMAGE_NUEVA>
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
  strategy:
    canary:
      steps:
        - setWeight: 10 # 10% del tráfico a la nueva versión
        - pause: { duration: 60s } # Esperar 1 min para observar métricas
        - setWeight: 30
        - pause: { duration: 60s }
        - setWeight: 60
        - pause: { duration: 30s }
        - setWeight: 100 # Promover al 100%
      canaryService: identity-api-canary
      stableService: identity-api-stable
```

### Paso 6.3: Services para canary

```yaml
# gitops-repo/base/services.yaml
apiVersion: v1
kind: Service
metadata:
  name: identity-api-stable
  namespace: apps
spec:
  selector:
    app: identity-api
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: identity-api-canary
  namespace: apps
spec:
  selector:
    app: identity-api
  ports:
    - port: 80
      targetPort: 8080
```

### Paso 6.4: Observar el canary

```bash
# Ver el progreso
kubectl argo rollouts get rollout identity-api -n apps -w

# Output:
# Name:            identity-api
# Status:          ॥ Paused
# Strategy:        Canary
#   Step:          1/7
#   SetWeight:     10
#   ActualWeight:  10
```

### Paso 6.5: Rollback si algo falla

```bash
# Si la nueva versión tiene errores:
kubectl argo rollouts abort identity-api -n apps
# Revierte al 100% de la versión estable inmediatamente

# Para promover manualmente (saltar pauses):
kubectl argo rollouts promote identity-api -n apps
```

### ¿Por qué canary y no blue/green?

| Estrategia     | Riesgo                      | Costo                   | Rollback         |
| -------------- | --------------------------- | ----------------------- | ---------------- |
| Rolling update | 100% expuesto si hay bug    | Sin costo extra         | Lento (rollback) |
| Blue/Green     | 0% o 100% — switch atómico  | Doble capacidad         | Instantáneo      |
| Canary         | Solo 10% expuesto al inicio | Capacidad parcial extra | Casi instantáneo |

Canary es el equilibrio: expones poco tráfico primero, mides, y decides.

---

## Troubleshooting

| Síntoma                                                            | Causa probable                                    | Fix                                                               |
| ------------------------------------------------------------------ | ------------------------------------------------- | ----------------------------------------------------------------- |
| Argo muestra "Unknown" en repo                                     | Repo privado sin credenciales configuradas        | `argocd repo add <url> --password <token>`                        |
| App en "OutOfSync" pero no sincroniza                              | `automated` no configurado, sync manual           | Agregar `syncPolicy.automated`                                    |
| Rollout stuck en "Paused"                                          | Es el comportamiento normal (esperando)           | `kubectl argo rollouts promote` o esperar duration                |
| Terraform plan muestra destroy del cluster                         | State corrupto o drift manual                     | `terraform refresh` antes de plan                                 |
| Pipeline falla en ECR push                                         | Permisos del role de GitHub Actions               | Verificar trust policy con `token.actions.githubusercontent.com`  |
| Argo revierte cambios que quiero mantener                          | selfHeal activado                                 | Hacer el cambio en el repo, no con kubectl                        |
| En prod falta una variable de entorno que sí está en `values.yaml` | Las listas de Helm se reemplazan, no se fusionan  | Repetir la lista completa en `values-prod.yaml`, o pasarla a mapa |
| El overlay de Kustomize no refleja el parche                       | El `target` del parche no coincide con el recurso | `kubectl kustomize overlays/prod` y comparar contra el base       |
| `helm upgrade` dejó el release en `failed`                         | Se corrió sin `--atomic` y falló a mitad          | `helm rollback <release> <rev>`, y usar `--atomic` de aquí en más |
| Argo dice `Synced` pero la app está mal                            | El repo es la fuente de verdad y el repo está mal | GitOps no valida contenido: eso es el lab 11 (Kyverno)            |

---

## 🔴 Destruir recursos del lab

```bash
# 0. Si instalaste el chart a mano en la Parte 3 (fuera de Argo)
helm uninstall identity-api -n apps 2>/dev/null

# 1. Argo CD y aplicaciones
kubectl delete application identity-api -n argocd
helm uninstall argocd -n argocd
kubectl delete namespace argocd argo-rollouts apps

# 2. Si usaste Terraform:
cd infra/terraform
terraform destroy -auto-approve

# 3. Si usaste eksctl:
eksctl delete cluster --name eks-gitops-lab --region us-east-1

# 4. State backend (opcional — mantener si vas a seguir con Terraform)
aws s3 rb s3://$BUCKET --force
aws dynamodb delete-table --table-name terraform-locks --region us-east-1
```

---

## Lecciones aprendidas

1. **Declarativo no es magia — es disciplina.** Un archivo que describe el
   estado deseado solo sirve si la herramienta que lo aplica puede detectar drift
   y corregirlo. eksctl no detecta drift. Terraform sí. Argo CD sí.

2. **El repo es la fuente de verdad.** Si `selfHeal: true` revierte tus cambios
   manuales, el sistema funciona correctamente. El problema es que hiciste un
   cambio fuera del flujo. La disciplina es: todo cambio pasa por un commit.

3. **terraform plan es el review que importa.** No el código — el plan. Dos
   archivos .tf idénticos pueden producir planes distintos si el estado actual
   del mundo es distinto. El plan es la verdad.

4. **Canary con métricas elimina el "funciona en staging".** En vez de probar en
   un entorno falso, pruebas con tráfico real pero controlado (10%). Si la tasa de
   error sube, rollback automático. Es testing en producción hecho bien.

5. **CI/CD completo cierra el loop.** commit → build → test → push → manifest
   update → Argo sync → canary → promote. Cada paso es automatizable y auditable.
   Sin uno de los eslabones, el resto pierde valor.

6. **Infrastructure as Code es prerequisito de GitOps.** No puedes hacer GitOps de
   apps si el cluster se creó "a mano". Si el cluster no es reproducible, todo lo
   que corre encima tampoco lo es.

7. **GitOps sin empaquetado mueve el problema, no lo resuelve.** Argo sincroniza
   fielmente lo que haya en el repo, incluida la inconsistencia entre tres manifests
   copiados. El chart o el overlay es lo que hace que "el repo es la fuente de
   verdad" signifique algo: sin él la fuente de verdad puede estar equivocada y el
   sistema seguiría diciendo `Synced`.

8. **Renderizar es la disciplina que evita la mayoría de los incidentes de
   despliegue.** `helm template`, `helm diff`, `kubectl kustomize` y `kubectl diff -k`
   cuestan segundos y muestran el YAML que realmente va a llegar al cluster. Casi
   todo error de empaquetado es visible ahí, antes de que exista un pod.
