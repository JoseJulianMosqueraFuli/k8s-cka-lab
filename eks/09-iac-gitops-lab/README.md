# Lab 09: Infraestructura como código + GitOps + entrega

## Resumen

Dos mitades: infra con IaC (eksctl + Terraform) y apps con GitOps (Argo CD +
Argo Rollouts). El momento revelador: haces `kubectl scale` a mano y Argo lo
revierte. Declarativo significa que el repo es la fuente de verdad, no tu terminal.

Además: CI/CD pipeline completa desde un commit hasta un canary deployment con
promoción automática basada en métricas.

**Se monta sobre:** el cluster del lab 03 (Auto Mode) o un cluster Terraform nuevo.
**Costo estimado adicional:** ~$0.05/hr (Argo CD es solo pods, pipeline usa GitHub Actions)
**Tiempo:** ~3h 30m (el lab más largo)

**Herramientas necesarias:**

- AWS CLI v2
- kubectl
- helm
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
                                             │                               │
                                             │  Argo Rollouts: canary 10% →  │
                                             │  metrics OK → promote 100%    │
                                             └───────────────────────────────┘
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
  version: "1.30"

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
  cluster_version = "1.30"

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

## Parte 3: GitOps con Argo CD

### Paso 3.1: Instalar Argo CD

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

### Paso 3.2: Estructura del repo de manifiestos

```
gitops-repo/
├── apps/
│   └── identity-api/
│       ├── deployment.yaml
│       ├── service.yaml
│       └── ingress.yaml
└── argocd/
    └── application.yaml
```

```yaml
# gitops-repo/apps/identity-api/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: identity-api
  namespace: apps
spec:
  replicas: 3
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
          image: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/k8s-lab/identity-api:abc1234
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

### Paso 3.3: Crear la Application en Argo

```yaml
# argocd/application.yaml
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
    path: apps/identity-api
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

```bash
kubectl apply -f argocd/application.yaml
```

### ¿Qué hace `selfHeal: true`?

Argo CD compara el estado del cluster con el repo cada 3 minutos. Si alguien
hace un cambio manual (`kubectl scale`, `kubectl edit`), Argo lo **revierte**
al estado del repo.

### Paso 3.4: El momento revelador — kubectl scale y Argo revierte

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
commit que cambia `replicas: 3` a `replicas: 5`. No usas kubectl.

---

## Parte 4: CI/CD Pipeline

### El flujo completo

```
1. Developer push code → trigger CI
2. CI: build → test → scan → push image to ECR (tag: commit SHA)
3. CI: update deployment.yaml with new image tag
4. CI: commit + push to gitops repo
5. Argo CD detects change → syncs → new pods with new image
```

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
        run: |
          git clone https://x-access-token:${GH_TOKEN}@github.com/${{ env.GITOPS_REPO }}.git /tmp/gitops
          cd /tmp/gitops
          sed -i "s|image:.*|image: ${{ env.IMAGE }}|" apps/identity-api/deployment.yaml
          git config user.email "ci@lab.local"
          git config user.name "CI Pipeline"
          git add .
          git commit -m "deploy: identity-api ${GITHUB_SHA:0:7}"
          git push
```

---

## Parte 5: Progressive Delivery con Argo Rollouts

### Paso 5.1: Instalar Argo Rollouts

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Plugin kubectl
# (descarga según tu OS desde https://github.com/argoproj/argo-rollouts/releases)
```

### Paso 5.2: Convertir Deployment a Rollout

```yaml
# gitops-repo/apps/identity-api/rollout.yaml
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

### Paso 5.3: Services para canary

```yaml
# gitops-repo/apps/identity-api/services.yaml
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

### Paso 5.4: Observar el canary

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

### Paso 5.5: Rollback si algo falla

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

| Síntoma                                    | Causa probable                             | Fix                                                              |
| ------------------------------------------ | ------------------------------------------ | ---------------------------------------------------------------- |
| Argo muestra "Unknown" en repo             | Repo privado sin credenciales configuradas | `argocd repo add <url> --password <token>`                       |
| App en "OutOfSync" pero no sincroniza      | `automated` no configurado, sync manual    | Agregar `syncPolicy.automated`                                   |
| Rollout stuck en "Paused"                  | Es el comportamiento normal (esperando)    | `kubectl argo rollouts promote` o esperar duration               |
| Terraform plan muestra destroy del cluster | State corrupto o drift manual              | `terraform refresh` antes de plan                                |
| Pipeline falla en ECR push                 | Permisos del role de GitHub Actions        | Verificar trust policy con `token.actions.githubusercontent.com` |
| Argo revierte cambios que quiero mantener  | selfHeal activado                          | Hacer el cambio en el repo, no con kubectl                       |

---

## 🔴 Destruir recursos del lab

```bash
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
