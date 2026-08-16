#!/usr/bin/env bash
# destroy.sh — Teardown del lab EKS Auto Mode (bash / WSL / CloudShell)
#
# Uso:
#   ./destroy.sh              # pide confirmación
#   ./destroy.sh --yes        # sin preguntar
#   AWS_REGION=us-west-2 ./destroy.sh
#
# Auto Mode termina sus propios nodos al borrar el cluster, pero los PVC
# de EBS NO se van solos: hay que borrarlos antes o quedan volúmenes
# cobrando. Por eso este script borra los PVC explícitamente.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/eks-teardown-lib.sh"

CLUSTER="automode-lab-cluster"
NAMESPACE="apps"
CLUSTER_ROLE="eks-automode-lab-cluster-role"
NODE_ROLE="eks-automode-lab-node-role"

require_tools || exit 1

printf '\n%s=== DESTRUYENDO LAB EKS AUTO MODE (%s) ===%s\n' "$_c_red" "$CLUSTER" "$_c_off"
if [[ "${1:-}" != "--yes" ]]; then
  confirm "Se borrarán el cluster, los PVC, la VPC y los roles IAM." || { echo "Cancelado."; exit 0; }
fi

step "Resolviendo la VPC del cluster"
VPC_ID="$(eks_vpc_id "$CLUSTER")"
if [[ -n "$VPC_ID" ]]; then
  ok "VPC del cluster: $VPC_ID"
else
  warn "El cluster no existe. Busco la VPC por tag:Name=automode-lab-vpc como fallback."
  VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
            --filters "Name=tag:Name,Values=automode-lab-vpc" \
            --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep '^vpc-' || true)"
fi

# Los PVC primero: el EBS CSI de Auto Mode borra el volumen cuando borras el
# PVC (reclaimPolicy Delete). Si borras el cluster antes, el volumen se queda.
step "Borrando PersistentVolumeClaims (para que el EBS CSI borre los volúmenes)"
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  pvcs="$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pvcs" ]]; then
    kubectl delete deployment,statefulset --all -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1
    for pvc in $pvcs; do
      kubectl delete pvc "$pvc" -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 \
        && ok "PVC $pvc borrado" || warn "PVC $pvc no se borró (¿pod aún montándolo?)"
    done
    dim "Esperando 30s a que el CSI driver borre los volúmenes EBS..."
    sleep 30
  else
    dim "Sin PVCs."
  fi
else
  dim "Namespace '$NAMESPACE' no existe. Salto."
fi

step "Borrando Service y Namespace de Kubernetes"
k8s_teardown "$NAMESPACE"
[[ -n "$VPC_ID" ]] && wait_load_balancers_gone "$VPC_ID"

step "Borrando el cluster EKS (Auto Mode termina sus nodos solo)"
eks_delete_cluster "$CLUSTER"
logs_delete_cluster_groups "$CLUSTER"

vpc_delete_full "$VPC_ID"

step "Borrando IAM"
iam_delete_role "$NODE_ROLE"
iam_delete_role "$CLUSTER_ROLE"

finish_banner
