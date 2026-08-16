#!/usr/bin/env bash
# destroy.sh — Teardown del lab 05 (Identity: IRSA + Pod Identity)

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="${EKS_CLUSTER:-ec2-lab-cluster}"
NAMESPACE="apps"
ROLE_IRSA="eks-lab-s3-reader-irsa"
ROLE_POD_ID="eks-lab-s3-reader-podid"
POLICY_NAME="eks-lab-s3-reader"
BUCKET_NAME="k8s-lab-identity-${ACCOUNT_ID}-${REGION}"

echo "=== DESTRUYENDO LAB 05 (Identity) ==="

# 1. Kubernetes
echo "[1/5] Borrando deployments y service accounts..."
kubectl delete deploy identity-api-irsa identity-api-podid -n "$NAMESPACE" 2>/dev/null
kubectl delete sa identity-api-irsa identity-api-podid -n "$NAMESPACE" 2>/dev/null
kubectl delete pod naked-pod -n "$NAMESPACE" 2>/dev/null

# 2. Pod Identity association
echo "[2/5] Borrando Pod Identity association..."
ASSOC_ID=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --query "associations[?serviceAccount=='identity-api-podid'].associationId" --output text 2>/dev/null)
if [[ -n "$ASSOC_ID" && "$ASSOC_ID" != "None" ]]; then
  aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
    --association-id "$ASSOC_ID" --region "$REGION" 2>/dev/null
  echo "  Association $ASSOC_ID borrada"
fi

# 3. IAM Roles
echo "[3/5] Borrando IAM roles..."
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

for ROLE in "$ROLE_IRSA" "$ROLE_POD_ID"; do
  if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" 2>/dev/null
    aws iam delete-role --role-name "$ROLE" 2>/dev/null \
      && echo "  Rol $ROLE borrado" || echo "  No pude borrar $ROLE"
  fi
done

# 4. IAM Policy
echo "[4/5] Borrando IAM policy..."
aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null \
  && echo "  Policy borrada" || echo "  Policy no existía"

# 5. S3 bucket
echo "[5/5] Borrando bucket S3..."
aws s3 rb "s3://$BUCKET_NAME" --force 2>/dev/null \
  && echo "  Bucket borrado" || echo "  Bucket no existía"

echo ""
echo "=== Lab 05 limpio ==="
