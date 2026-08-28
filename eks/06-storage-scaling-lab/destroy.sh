#!/usr/bin/env bash
# destroy.sh — Teardown del lab 06 (Storage + Scaling + KEDA + Velero)

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="${EKS_CLUSTER:-automode-lab-cluster}"
NAMESPACE="apps"
VELERO_BUCKET="velero-backups-${ACCOUNT_ID}-${REGION}"
QUEUE_NAME="k8s-lab-jobs"
ROLE_KEDA="eks-lab-keda-sqs"
POLICY_KEDA_NAME="eks-lab-keda-sqs-read"

echo "=== DESTRUYENDO LAB 06 (Storage + Scaling) ==="

# 1. KEDA (Parte 4) — va PRIMERO: el ScaledObject controla el Deployment del worker
# y es dueño de un HPA generado. Si se desinstala KEDA antes de borrar los
# ScaledObject, ese keda-hpa-* queda huérfano en el namespace.
echo "[1/9] Desinstalando KEDA..."
kubectl delete scaledobject --all -n "$NAMESPACE" 2>/dev/null
kubectl delete scaledjob --all -n "$NAMESPACE" 2>/dev/null
kubectl delete triggerauthentication --all -n "$NAMESPACE" 2>/dev/null
helm uninstall keda -n keda 2>/dev/null
kubectl delete namespace keda 2>/dev/null

LEFTOVER_HPA=$(kubectl get hpa -n "$NAMESPACE" -o name 2>/dev/null | grep 'keda-hpa-' || true)
if [[ -n "$LEFTOVER_HPA" ]]; then
  echo "  HPA huérfanos de KEDA, borrando: $LEFTOVER_HPA"
  kubectl delete $LEFTOVER_HPA -n "$NAMESPACE" 2>/dev/null
fi

# 2. Kubernetes workloads
echo "[2/9] Borrando workloads..."
kubectl delete deploy cpu-burner writer-efs queue-worker -n "$NAMESPACE" 2>/dev/null
kubectl delete sa queue-worker -n "$NAMESPACE" 2>/dev/null
kubectl delete statefulset data-store -n "$NAMESPACE" 2>/dev/null
kubectl delete hpa cpu-burner-hpa -n "$NAMESPACE" 2>/dev/null
kubectl delete pdb data-store-pdb -n "$NAMESPACE" 2>/dev/null

# 3. PVCs (esto borra los volúmenes EBS con reclaimPolicy Delete)
echo "[3/9] Borrando PVCs..."
kubectl delete pvc -l app=data-store -n "$NAMESPACE" 2>/dev/null
kubectl delete pvc shared-data -n "$NAMESPACE" 2>/dev/null
echo "  Esperando 30s para que el CSI borre los volúmenes..."
sleep 30

# 4. Velero
echo "[4/9] Desinstalando Velero..."
helm uninstall velero -n velero 2>/dev/null
kubectl delete namespace velero 2>/dev/null
aws s3 rb "s3://$VELERO_BUCKET" --force 2>/dev/null

# 5. EFS
echo "[5/9] Borrando EFS..."
EFS_ID=$(aws efs describe-file-systems --region "$REGION" \
  --query "FileSystems[?Name=='eks-lab-efs'].FileSystemId" --output text 2>/dev/null)
if [[ -n "$EFS_ID" && "$EFS_ID" != "None" ]]; then
  for MT in $(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$REGION" \
    --query "MountTargets[].MountTargetId" --output text 2>/dev/null); do
    aws efs delete-mount-target --mount-target-id "$MT" --region "$REGION" 2>/dev/null
  done
  echo "  Esperando 30s para que se borren los mount targets..."
  sleep 30
  aws efs delete-file-system --file-system-id "$EFS_ID" --region "$REGION" 2>/dev/null \
    && echo "  EFS $EFS_ID borrado"
fi

# 6. Security group de EFS
echo "[6/9] Borrando security group de EFS..."
EFS_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=eks-lab-efs-sg" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
if [[ -n "$EFS_SG" && "$EFS_SG" != "None" ]]; then
  aws ec2 delete-security-group --group-id "$EFS_SG" --region "$REGION" 2>/dev/null \
    && echo "  SG $EFS_SG borrado"
fi

# 7. Volúmenes EBS huérfanos
echo "[7/9] Verificando volúmenes EBS huérfanos..."
ORPHANS=$(aws ec2 describe-volumes --region "$REGION" \
  --filters Name=status,Values=available \
  --query "Volumes[?Tags[?Key=='kubernetes.io/created-for/pvc/namespace' && Value=='$NAMESPACE']].VolumeId" \
  --output text 2>/dev/null)
if [[ -n "$ORPHANS" ]]; then
  for VOL in $ORPHANS; do
    aws ec2 delete-volume --volume-id "$VOL" --region "$REGION" 2>/dev/null \
      && echo "  Volumen $VOL borrado"
  done
else
  echo "  Sin volúmenes huérfanos"
fi

# 8. SQS + IAM de KEDA y del worker
echo "[8/9] Borrando cola SQS e IAM de KEDA..."
for SA in "keda-operator" "queue-worker"; do
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

if aws iam get-role --role-name "$ROLE_KEDA" >/dev/null 2>&1; then
  for PA in $(aws iam list-attached-role-policies --role-name "$ROLE_KEDA" \
    --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE_KEDA" --policy-arn "$PA" 2>/dev/null
  done
  aws iam delete-role --role-name "$ROLE_KEDA" 2>/dev/null \
    && echo "  Rol $ROLE_KEDA borrado"
fi
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_KEDA_NAME}" 2>/dev/null \
  && echo "  Policy $POLICY_KEDA_NAME borrada"

QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$REGION" \
  --query QueueUrl --output text 2>/dev/null)
if [[ -n "$QUEUE_URL" && "$QUEUE_URL" != "None" ]]; then
  aws sqs delete-queue --queue-url "$QUEUE_URL" --region "$REGION" 2>/dev/null \
    && echo "  Cola $QUEUE_NAME borrada"
fi

# 9. Namespace
echo "[9/9] Borrando namespace..."
kubectl delete namespace "$NAMESPACE" 2>/dev/null

echo ""
echo "=== Lab 06 limpio ==="
echo "Nota: las CRDs de keda.sh siguen en el cluster (Helm no las borra)."
