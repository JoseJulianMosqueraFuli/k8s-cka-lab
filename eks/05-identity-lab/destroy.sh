#!/usr/bin/env bash
# destroy.sh — Teardown del lab 05 (Identity: IRSA + Pod Identity + External Secrets)

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="${EKS_CLUSTER:-ec2-lab-cluster}"
NAMESPACE="apps"
ROLE_IRSA="eks-lab-s3-reader-irsa"
ROLE_POD_ID="eks-lab-s3-reader-podid"
ROLE_ESO="eks-lab-external-secrets"
POLICY_NAME="eks-lab-s3-reader"
POLICY_ESO_NAME="eks-lab-eso-read"
BUCKET_NAME="k8s-lab-identity-${ACCOUNT_ID}-${REGION}"
SECRET_NAME="k8s-lab/identity-api/db"

echo "=== DESTRUYENDO LAB 05 (Identity) ==="

# 1. Kubernetes
echo "[1/7] Borrando deployments y service accounts..."
kubectl delete deploy identity-api-irsa identity-api-podid -n "$NAMESPACE" 2>/dev/null
kubectl delete sa identity-api-irsa identity-api-podid -n "$NAMESPACE" 2>/dev/null
kubectl delete pod naked-pod -n "$NAMESPACE" 2>/dev/null

# 2. External Secrets Operator (Paso 9)
# Los ExternalSecret van primero: si se va el operator antes, los finalizers
# de las CRDs pueden dejar los objetos colgados
echo "[2/7] Desinstalando External Secrets Operator..."
kubectl delete externalsecret --all -A 2>/dev/null
kubectl delete clustersecretstore --all 2>/dev/null
kubectl delete secretstore --all -A 2>/dev/null
helm uninstall external-secrets -n external-secrets 2>/dev/null
kubectl delete namespace external-secrets 2>/dev/null
# Secrets Store CSI Driver, si se probó la alternativa del Paso 9.7
helm uninstall csi-secrets-store -n kube-system 2>/dev/null

# 3. Pod Identity associations (la de la app y la del operator)
echo "[3/7] Borrando Pod Identity associations..."
for SA in "identity-api-podid" "external-secrets"; do
  ASSOC_ID=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --query "associations[?serviceAccount=='${SA}'].associationId" --output text 2>/dev/null)
  if [[ -n "$ASSOC_ID" && "$ASSOC_ID" != "None" ]]; then
    for ID in $ASSOC_ID; do
      aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
        --association-id "$ID" --region "$REGION" 2>/dev/null \
        && echo "  Association $ID ($SA) borrada"
    done
  fi
done

# 4. IAM Roles — se sueltan TODAS las policies adjuntas, no una lista fija
echo "[4/7] Borrando IAM roles..."
for ROLE in "$ROLE_IRSA" "$ROLE_POD_ID" "$ROLE_ESO"; do
  if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    for PA in $(aws iam list-attached-role-policies --role-name "$ROLE" \
      --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$PA" 2>/dev/null
    done
    aws iam delete-role --role-name "$ROLE" 2>/dev/null \
      && echo "  Rol $ROLE borrado" || echo "  No pude borrar $ROLE"
  fi
done

# 5. IAM Policies
echo "[5/7] Borrando IAM policies..."
for P in "$POLICY_NAME" "$POLICY_ESO_NAME"; do
  ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${P}"
  aws iam delete-policy --policy-arn "$ARN" 2>/dev/null \
    && echo "  Policy $P borrada" || echo "  Policy $P no existía"
done

# 6. Secreto de Secrets Manager
# Sin --force-delete-without-recovery queda 30 días "scheduled for deletion",
# ocupando el nombre y facturando
echo "[6/7] Borrando secreto de Secrets Manager..."
aws secretsmanager delete-secret --secret-id "$SECRET_NAME" \
  --force-delete-without-recovery --region "$REGION" 2>/dev/null \
  && echo "  Secreto borrado" || echo "  Secreto no existía"

# 7. S3 bucket
echo "[7/7] Borrando bucket S3..."
aws s3 rb "s3://$BUCKET_NAME" --force 2>/dev/null \
  && echo "  Bucket borrado" || echo "  Bucket no existía"

echo ""
echo "=== Lab 05 limpio ==="
echo "Nota: las CRDs de external-secrets.io siguen en el cluster (Helm no las borra)."
echo "Si el cluster sobrevive al lab: kubectl delete crd -l app.kubernetes.io/name=external-secrets"
