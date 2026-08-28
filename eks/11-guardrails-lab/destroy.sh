#!/usr/bin/env bash
# destroy.sh — Teardown del lab 11 (Guardrails / Kyverno)

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== DESTRUYENDO LAB 11 (Guardrails) ==="

# 1. Políticas de Kyverno
echo "[1/6] Borrando políticas y excepciones..."
kubectl delete clusterpolicy --all 2>/dev/null
kubectl delete policyexception -n kyverno --all 2>/dev/null

# 2. Kyverno
echo "[2/6] Desinstalando Kyverno..."
helm uninstall kyverno -n kyverno 2>/dev/null
kubectl delete namespace kyverno 2>/dev/null

# 3. Namespaces de prueba
echo "[3/6] Borrando namespaces de prueba..."
kubectl delete namespace team-alpha 2>/dev/null
kubectl delete pod test-tagged test-latest test-latest2 with-resources 2>/dev/null

# 4. kube-bench (Paso 9) — un Job completado no se limpia solo
echo "[4/6] Borrando Job de kube-bench..."
kubectl delete job kube-bench 2>/dev/null
kubectl delete job kube-bench-node 2>/dev/null

# 5. KMS key (schedule deletion)
echo "[5/6] Buscando KMS key del lab..."
KMS_KEY=$(aws kms list-aliases --region "$REGION" \
  --query "Aliases[?AliasName=='alias/eks-secrets'].TargetKeyId" --output text 2>/dev/null)
if [[ -n "$KMS_KEY" && "$KMS_KEY" != "None" ]]; then
  read -rp "¿Programar borrado de KMS key $KMS_KEY en 7 días? [s/N]: " ans
  if [[ "$ans" =~ ^[sS]$ ]]; then
    aws kms schedule-key-deletion --key-id "$KMS_KEY" \
      --pending-window-in-days 7 --region "$REGION" 2>/dev/null
    aws kms delete-alias --alias-name alias/eks-secrets --region "$REGION" 2>/dev/null
    echo "  KMS key programada para borrado en 7 días"
  fi
fi

# 6. PSS labels (revertir)
echo "[6/6] Removiendo labels PSS de namespaces..."
for NS in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
  kubectl label namespace "$NS" pod-security.kubernetes.io/enforce- \
    pod-security.kubernetes.io/warn- pod-security.kubernetes.io/audit- 2>/dev/null
done

echo ""
echo "=== Lab 11 limpio ==="
