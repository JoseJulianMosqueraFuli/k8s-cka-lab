#!/usr/bin/env bash
# destroy.sh — Teardown del lab EKS + Fargate (bash / WSL / CloudShell)
#
# Uso:
#   ./destroy.sh              # pide confirmación
#   ./destroy.sh --yes        # sin preguntar
#   AWS_REGION=us-west-2 ./destroy.sh
#
# Equivalente a destroy.ps1 pero:
#   - borra la VPC completa (el .ps1 lo dejaba como paso manual)
#   - descubre recursos por relación, no por tag:Name con wildcards
#   - suelta las IAM policies que estén adjuntas, sin ARNs hardcodeados

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/eks-teardown-lib.sh"

CLUSTER="lab-cluster"
NAMESPACE="apps"
CLUSTER_ROLE="eks-lab-cluster-role"
FARGATE_ROLE="eks-lab-fargate-role"
LB_POLICY="AWSLoadBalancerControllerIAMPolicy"

require_tools || exit 1

printf '\n%s=== DESTRUYENDO LAB EKS FARGATE (%s) ===%s\n' "$_c_red" "$CLUSTER" "$_c_off"
if [[ "${1:-}" != "--yes" ]]; then
  confirm "Se borrarán el cluster, la VPC y los roles IAM del lab." || { echo "Cancelado."; exit 0; }
fi

# La VPC hay que resolverla ANTES de borrar el cluster: después de borrarlo
# ya no hay de dónde sacar el VPC ID sin adivinar por nombre.
step "Resolviendo la VPC del cluster"
VPC_ID="$(eks_vpc_id "$CLUSTER")"
OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
               --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)"
if [[ -n "$VPC_ID" ]]; then
  ok "VPC del cluster: $VPC_ID"
else
  warn "El cluster no existe. Busco la VPC por tag:Name=lab-vpc como fallback."
  VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
            --filters "Name=tag:Name,Values=lab-vpc" \
            --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep '^vpc-' || true)"
fi

step "Borrando Service y Namespace de Kubernetes"
k8s_teardown "$NAMESPACE"

step "Desinstalando el AWS Load Balancer Controller"
if command -v helm >/dev/null 2>&1; then
  helm uninstall aws-load-balancer-controller -n kube-system >/dev/null 2>&1 \
    && ok "Helm release desinstalado" || dim "No había release de Helm."
else
  dim "helm no está instalado; salto este paso."
fi

# El IAM service account de eksctl es en realidad un stack de CloudFormation.
# Borrarlo con eksctl es lo limpio; si no está, se borra el stack directo.
step "Borrando el IAM Service Account (IRSA)"
if command -v eksctl >/dev/null 2>&1; then
  eksctl delete iamserviceaccount --cluster="$CLUSTER" --namespace=kube-system \
    --name=aws-load-balancer-controller --region "$REGION" --wait >/dev/null 2>&1 \
    && ok "IAM service account eliminado" || dim "eksctl no encontró el service account."
fi
cfn_delete_eksctl_stacks "$CLUSTER"

[[ -n "$VPC_ID" ]] && wait_load_balancers_gone "$VPC_ID"

step "Borrando los Fargate profiles"
eks_delete_fargate_profiles "$CLUSTER"

step "Borrando el cluster EKS"
eks_delete_cluster "$CLUSTER"
logs_delete_cluster_groups "$CLUSTER"

vpc_delete_full "$VPC_ID"

step "Borrando IAM"
iam_delete_policy "$LB_POLICY"
iam_delete_role "$CLUSTER_ROLE"
iam_delete_role "$FARGATE_ROLE"
iam_delete_oidc_provider "$OIDC_ISSUER"

finish_banner
