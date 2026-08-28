#!/usr/bin/env bash
# destroy.sh — Teardown del lab 04 (Ingress + ECR + Gateway API + cert-manager)
# Este lab se monta sobre el cluster del lab 02 o 03; NO borra el cluster.
# Solo limpia los recursos propios: Ingress, Gateway, Service, Deployment,
# cert-manager, ECR y el certificado de ACM.

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
REPO_NAME="k8s-lab/identity-api"
NAMESPACE="apps"

echo "=== DESTRUYENDO LAB 04 (Ingress + ECR) ==="

# 1. Gateway API (Paso 8), si se probó.
# Las rutas van antes del Gateway: el Gateway es el dueño del ALB, y borrarlo
# con rutas colgando puede dejar el balanceador atrás.
echo "[1/6] Borrando recursos de Gateway API..."
kubectl delete httproute --all -n "$NAMESPACE" 2>/dev/null
kubectl delete grpcroute --all -n "$NAMESPACE" 2>/dev/null
kubectl delete tcproute --all -n "$NAMESPACE" 2>/dev/null
kubectl delete gateway --all -n "$NAMESPACE" 2>/dev/null
kubectl delete gatewayclass alb 2>/dev/null

# 2. Kubernetes resources
echo "[2/6] Borrando Ingress, Service y Deployment..."
kubectl delete ingress identity-api -n "$NAMESPACE" 2>/dev/null
kubectl delete svc identity-api -n "$NAMESPACE" 2>/dev/null
kubectl delete deploy identity-api -n "$NAMESPACE" 2>/dev/null
kubectl delete pod identity-host -n "$NAMESPACE" 2>/dev/null

# Esperar a que los balanceadores se eliminen
echo "  Esperando 60s para que los ALB se eliminen..."
sleep 60

# Verificar que no quedó ningún ALB del lab cobrando
LEFTOVER_LB=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-${NAMESPACE}')].LoadBalancerName" \
  --output text 2>/dev/null)
if [[ -n "$LEFTOVER_LB" && "$LEFTOVER_LB" != "None" ]]; then
  echo "  ⚠️  Quedan balanceadores del lab: $LEFTOVER_LB"
  echo "     Revisa si el Ingress/Gateway se borró correctamente antes de seguir."
fi

# 3. cert-manager (Paso 5, Opción C), si se instaló
echo "[3/6] Desinstalando cert-manager..."
kubectl delete certificate --all -A 2>/dev/null
kubectl delete clusterissuer --all 2>/dev/null
kubectl delete issuer --all -A 2>/dev/null
helm uninstall cert-manager -n cert-manager 2>/dev/null
kubectl delete namespace cert-manager 2>/dev/null

# 4. ECR (pregunta antes de borrar — se usa en labs 05-09)
echo "[4/6] Repositorio ECR..."
read -rp "¿Borrar el repositorio ECR $REPO_NAME? (se usa en labs 05-09) [s/N]: " ans
if [[ "$ans" =~ ^[sS]$ ]]; then
  aws ecr delete-repository --repository-name "$REPO_NAME" --region "$REGION" --force 2>/dev/null \
    && echo "  ECR $REPO_NAME borrado" || echo "  ECR no existía"
else
  echo "  ECR conservado para los labs siguientes"
fi

# 5. ACM certificate (si existe)
echo "[5/6] Buscando certificados ACM del lab..."
for ARN in $(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?contains(DomainName,'lab')].CertificateArn" --output text 2>/dev/null); do
  [[ "$ARN" == "None" || -z "$ARN" ]] && continue
  echo "  Borrando certificado: $ARN"
  aws acm delete-certificate --certificate-arn "$ARN" --region "$REGION" 2>/dev/null
done

# 6. Namespace (solo si está vacío)
echo "[6/6] Verificando namespace..."
REMAINING=$(kubectl get all -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if (( REMAINING == 0 )); then
  kubectl delete namespace "$NAMESPACE" 2>/dev/null && echo "  Namespace $NAMESPACE borrado"
else
  echo "  Namespace $NAMESPACE tiene $REMAINING recursos; no se borra"
fi

echo ""
echo "=== Lab 04 limpio. El cluster base sigue activo ==="
echo "Nota: las CRDs de Gateway API y cert-manager siguen en el cluster."
echo "Helm no las borra a propósito. Si el cluster sobrevive y quieres limpiarlas:"
echo "  kubectl delete crd -l app.kubernetes.io/name=cert-manager"
echo "  kubectl delete crd -l gateway.networking.k8s.io/policy-attachment"
