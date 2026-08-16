#!/usr/bin/env bash
# destroy.sh — Teardown del lab 13 (FinOps)

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"

echo "=== DESTRUYENDO LAB 13 (FinOps) ==="

# 1. OpenCost / Kubecost
echo "[1/4] Desinstalando herramientas de costos..."
helm uninstall opencost -n opencost 2>/dev/null
helm uninstall kubecost -n kubecost 2>/dev/null
kubectl delete namespace opencost kubecost 2>/dev/null

# 2. VPA
echo "[2/4] Desinstalando VPA..."
if [[ -d "/tmp/autoscaler/vertical-pod-autoscaler" ]]; then
  cd /tmp/autoscaler/vertical-pod-autoscaler && ./hack/vpa-down.sh 2>/dev/null && cd -
  echo "  VPA desinstalado"
else
  kubectl delete vpa --all -A 2>/dev/null
  kubectl delete deployment vpa-recommender vpa-updater vpa-admission-controller -n kube-system 2>/dev/null
  echo "  VPA recursos borrados (script no encontrado)"
fi

# 3. Deployments de prueba
echo "[3/4] Borrando workloads de prueba..."
kubectl delete deploy consolidation-test 2>/dev/null
kubectl delete nodepool mixed-pool 2>/dev/null

# 4. Verificación de waste
echo "[4/4] Ejecutando verificación de waste residual..."
echo ""
echo "--- Volúmenes EBS sin usar ---"
aws ec2 describe-volumes --region "$REGION" \
  --filters Name=status,Values=available \
  --query "Volumes[].[VolumeId,Size,CreateTime]" --output table 2>/dev/null

echo ""
echo "--- Elastic IPs sin asociar ---"
aws ec2 describe-addresses --region "$REGION" \
  --query "Addresses[?AssociationId==null].[PublicIp,AllocationId]" --output table 2>/dev/null

echo ""
echo "=== Lab 13 limpio ==="
echo "Para auditoría completa: ../scripts/verify-clean.sh"
