#!/usr/bin/env bash
# destroy.sh — Teardown del lab 06 (Storage + Scaling + Velero)

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="${EKS_CLUSTER:-automode-lab-cluster}"
NAMESPACE="apps"
VELERO_BUCKET="velero-backups-${ACCOUNT_ID}-${REGION}"

echo "=== DESTRUYENDO LAB 06 (Storage + Scaling) ==="

# 1. Kubernetes workloads
echo "[1/7] Borrando workloads..."
kubectl delete deploy cpu-burner writer-efs -n "$NAMESPACE" 2>/dev/null
kubectl delete statefulset data-store -n "$NAMESPACE" 2>/dev/null
kubectl delete hpa cpu-burner-hpa -n "$NAMESPACE" 2>/dev/null
kubectl delete pdb data-store-pdb -n "$NAMESPACE" 2>/dev/null

# 2. PVCs (esto borra los volúmenes EBS con reclaimPolicy Delete)
echo "[2/7] Borrando PVCs..."
kubectl delete pvc -l app=data-store -n "$NAMESPACE" 2>/dev/null
kubectl delete pvc shared-data -n "$NAMESPACE" 2>/dev/null
echo "  Esperando 30s para que el CSI borre los volúmenes..."
sleep 30

# 3. Velero
echo "[3/7] Desinstalando Velero..."
helm uninstall velero -n velero 2>/dev/null
kubectl delete namespace velero 2>/dev/null
aws s3 rb "s3://$VELERO_BUCKET" --force 2>/dev/null

# 4. EFS
echo "[4/7] Borrando EFS..."
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

# 5. Security group de EFS
echo "[5/7] Borrando security group de EFS..."
EFS_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=eks-lab-efs-sg" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
if [[ -n "$EFS_SG" && "$EFS_SG" != "None" ]]; then
  aws ec2 delete-security-group --group-id "$EFS_SG" --region "$REGION" 2>/dev/null \
    && echo "  SG $EFS_SG borrado"
fi

# 6. Volúmenes EBS huérfanos
echo "[6/7] Verificando volúmenes EBS huérfanos..."
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

# 7. Namespace
echo "[7/7] Borrando namespace..."
kubectl delete namespace "$NAMESPACE" 2>/dev/null

echo ""
echo "=== Lab 06 limpio ==="
