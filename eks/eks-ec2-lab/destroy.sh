#!/usr/bin/env bash
# destroy.sh — Teardown del lab EKS + EC2 Managed Node Groups (bash / WSL / CloudShell)
#
# Uso:
#   ./destroy.sh              # pide confirmación
#   ./destroy.sh --yes        # sin preguntar
#   AWS_REGION=us-west-2 ./destroy.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/eks-teardown-lib.sh"

CLUSTER="ec2-lab-cluster"
NAMESPACE="apps"
CLUSTER_ROLE="eks-ec2-lab-cluster-role"
NODE_ROLE="eks-ec2-lab-node-role"

require_tools || exit 1

printf '\n%s=== DESTRUYENDO LAB EKS EC2 (%s) ===%s\n' "$_c_red" "$CLUSTER" "$_c_off"
if [[ "${1:-}" != "--yes" ]]; then
  confirm "Se borrarán el node group, el cluster, la VPC y los roles IAM." || { echo "Cancelado."; exit 0; }
fi

step "Resolviendo la VPC del cluster"
VPC_ID="$(eks_vpc_id "$CLUSTER")"
OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
               --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)"
if [[ -n "$VPC_ID" ]]; then
  ok "VPC del cluster: $VPC_ID"
else
  warn "El cluster no existe. Busco la VPC por tag:Name=ec2-lab-vpc como fallback."
  VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
            --filters "Name=tag:Name,Values=ec2-lab-vpc" \
            --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep '^vpc-' || true)"
fi

# El Service tipo LoadBalancer creó un Classic LB registrando los nodos como
# targets. Si borras el node group primero, el CLB queda con targets en
# "draining" y tarda mucho más en limpiarse.
step "Borrando Service y Namespace de Kubernetes"
k8s_teardown "$NAMESPACE"
[[ -n "$VPC_ID" ]] && wait_load_balancers_gone "$VPC_ID"

step "Borrando los node groups"
eks_delete_nodegroups "$CLUSTER"

step "Borrando el cluster EKS"
eks_delete_cluster "$CLUSTER"
logs_delete_cluster_groups "$CLUSTER"

# Si probaste la ruta opcional con NLB, quedan stacks de eksctl.
cfn_delete_eksctl_stacks "$CLUSTER"

vpc_delete_full "$VPC_ID"

step "Borrando IAM"
iam_delete_role "$NODE_ROLE"
iam_delete_role "$CLUSTER_ROLE"
iam_delete_oidc_provider "$OIDC_ISSUER"

finish_banner
