#!/usr/bin/env bash
# destroy.sh — Teardown del lab 09 (IaC + GitOps)

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_BUCKET="terraform-state-${ACCOUNT_ID}-us-east-1"

echo "=== DESTRUYENDO LAB 09 (IaC + GitOps) ==="

# 1. Argo CD y apps
echo "[1/5] Borrando Argo CD..."
kubectl delete application --all -n argocd 2>/dev/null
helm uninstall argocd -n argocd 2>/dev/null
kubectl delete namespace argocd argo-rollouts apps 2>/dev/null

# 2. Cluster eksctl (si se creó)
echo "[2/5] Buscando cluster eksctl..."
if aws eks describe-cluster --name eks-gitops-lab --region "$REGION" >/dev/null 2>&1; then
  if command -v eksctl >/dev/null 2>&1; then
    echo "  Borrando cluster eksctl (eks-gitops-lab)..."
    eksctl delete cluster --name eks-gitops-lab --region "$REGION" --wait
  else
    echo "  eksctl no instalado. Borra manualmente el cluster eks-gitops-lab"
  fi
fi

# 3. Terraform (si se usó)
echo "[3/5] Buscando infraestructura Terraform..."
if [[ -d "infra/terraform" && -f "infra/terraform/.terraform/terraform.tfstate" ]]; then
  echo "  Encontrado estado Terraform local. Ejecutando destroy..."
  cd infra/terraform
  terraform destroy -auto-approve
  cd ../..
elif [[ -d "infra/terraform" ]]; then
  echo "  Directorio Terraform existe pero sin state local."
  echo "  Si usaste backend S3, ejecuta manualmente:"
  echo "    cd infra/terraform && terraform init && terraform destroy"
fi

# 4. Terraform state backend (pregunta)
echo "[4/5] Terraform state backend..."
read -rp "¿Borrar el bucket de state S3 ($TF_BUCKET) y DynamoDB? [s/N]: " ans
if [[ "$ans" =~ ^[sS]$ ]]; then
  aws s3 rb "s3://$TF_BUCKET" --force 2>/dev/null \
    && echo "  Bucket $TF_BUCKET borrado"
  aws dynamodb delete-table --table-name terraform-locks --region "$REGION" 2>/dev/null \
    && echo "  DynamoDB terraform-locks borrada"
fi

# 5. Verificar
echo "[5/5] Verificando..."
echo "  Ejecuta ../scripts/verify-clean.sh para confirmar"

echo ""
echo "=== Lab 09 limpio ==="
