#!/usr/bin/env bash
# destroy.sh — Teardown del lab 10 (Upgrade)
# Este lab no crea infra nueva: usa el cluster existente y lo sube de versión.
# Solo limpia los recursos de prueba (PDBs, deploys de test).
# Si hiciste blue/green, también destruye el cluster GREEN.

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
GREEN_CLUSTER="${EKS_GREEN_CLUSTER:-eks-green-lab}"

echo "=== DESTRUYENDO LAB 10 (Upgrade) ==="

# 1. Recursos de prueba
echo "[1/3] Borrando deploys y PDBs de prueba..."
kubectl delete deploy upgrade-test 2>/dev/null
kubectl delete pdb upgrade-test-pdb too-strict pdb-strict 2>/dev/null

# 2. Cluster GREEN (blue/green strategy)
echo "[2/3] Verificando cluster GREEN..."
if aws eks describe-cluster --name "$GREEN_CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  read -rp "¿Borrar el cluster GREEN ($GREEN_CLUSTER)? [s/N]: " ans
  if [[ "$ans" =~ ^[sS]$ ]]; then
    if [[ -d "infra/terraform/green" ]]; then
      echo "  Destruyendo con Terraform..."
      cd infra/terraform/green && terraform destroy -auto-approve && cd ../../..
    else
      echo "  Sin Terraform state. Borrando con AWS CLI..."
      aws eks delete-cluster --name "$GREEN_CLUSTER" --region "$REGION"
      echo "  Esperando... (puede tardar ~10 min)"
      aws eks wait cluster-deleted --name "$GREEN_CLUSTER" --region "$REGION" 2>/dev/null
    fi
  fi
else
  echo "  No hay cluster GREEN"
fi

# 3. Herramientas temporales
echo "[3/3] Limpiando herramientas descargadas..."
[[ -f /usr/local/bin/pluto ]] && sudo rm /usr/local/bin/pluto && echo "  pluto removido"

echo ""
echo "=== Lab 10 limpio ==="
echo "Nota: el cluster principal sigue activo en la nueva versión"
