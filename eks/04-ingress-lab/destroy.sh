#!/usr/bin/env bash
# destroy.sh — Teardown del lab 04 (Ingress + ECR)
# Este lab se monta sobre el cluster del lab 02 o 03; NO borra el cluster.
# Solo limpia los recursos propios: Ingress, Service, Deployment, ECR, ACM cert.

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
REPO_NAME="k8s-lab/identity-api"
NAMESPACE="apps"

echo "=== DESTRUYENDO LAB 04 (Ingress + ECR) ==="

# 1. Kubernetes resources
echo "[1/4] Borrando Ingress, Service y Deployment..."
kubectl delete ingress identity-api -n "$NAMESPACE" 2>/dev/null
kubectl delete svc identity-api -n "$NAMESPACE" 2>/dev/null
kubectl delete deploy identity-api -n "$NAMESPACE" 2>/dev/null
kubectl delete pod identity-host -n "$NAMESPACE" 2>/dev/null

# Esperar a que el ALB se elimine
echo "  Esperando 60s para que el ALB se elimine..."
sleep 60

# 2. ECR (pregunta antes de borrar — se usa en labs 05-09)
read -rp "¿Borrar el repositorio ECR $REPO_NAME? (se usa en labs 05-09) [s/N]: " ans
if [[ "$ans" =~ ^[sS]$ ]]; then
  aws ecr delete-repository --repository-name "$REPO_NAME" --region "$REGION" --force 2>/dev/null \
    && echo "  ECR $REPO_NAME borrado" || echo "  ECR no existía"
else
  echo "  ECR conservado para los labs siguientes"
fi

# 3. ACM certificate (si existe)
echo "[3/4] Buscando certificados ACM del lab..."
for ARN in $(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?contains(DomainName,'lab')].CertificateArn" --output text 2>/dev/null); do
  [[ "$ARN" == "None" || -z "$ARN" ]] && continue
  echo "  Borrando certificado: $ARN"
  aws acm delete-certificate --certificate-arn "$ARN" --region "$REGION" 2>/dev/null
done

# 4. Namespace (solo si está vacío)
echo "[4/4] Verificando namespace..."
REMAINING=$(kubectl get all -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if (( REMAINING == 0 )); then
  kubectl delete namespace "$NAMESPACE" 2>/dev/null && echo "  Namespace $NAMESPACE borrado"
else
  echo "  Namespace $NAMESPACE tiene $REMAINING recursos; no se borra"
fi

echo ""
echo "=== Lab 04 limpio. El cluster base sigue activo ==="
