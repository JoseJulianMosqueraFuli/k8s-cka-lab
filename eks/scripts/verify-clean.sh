#!/usr/bin/env bash
# verify-clean.sh — Auditoría post-destroy: ¿quedó algo cobrando?
#
# Uso:
#   ./verify-clean.sh                 # revisa la región por defecto
#   AWS_REGION=us-west-2 ./verify-clean.sh
#
# Exit code 0 = limpio. Exit code 1 = quedan recursos.
#
# No borra nada. Solo reporta, con el costo aproximado por hora de lo que
# encuentra, para que sepas si urge o no.

set -uo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'
c_cyn=$'\033[36m'; c_dim=$'\033[2m';  c_off=$'\033[0m'

FINDINGS=0
COST_HR=0

aws_list() {
  local out
  out="$("$@" 2>/dev/null)" || return 0
  [[ "$out" == "None" ]] && return 0
  printf '%s' "$out" | tr '\t' '\n' | grep -v '^$' || true
}

# check <título> <costo_hr_por_item> <comando...>
check() {
  local title="$1" unit_cost="$2"; shift 2
  local items; items="$(aws_list "$@")"
  local n; n="$(printf '%s' "$items" | grep -c '.' || true)"

  if [[ -z "$items" ]]; then
    printf '  %s✔%s %-42s limpio\n' "$c_grn" "$c_off" "$title"
    return 0
  fi

  local subtotal; subtotal="$(awk -v c="$unit_cost" -v n="$n" 'BEGIN{printf "%.3f", c*n}')"
  COST_HR="$(awk -v a="$COST_HR" -v b="$subtotal" 'BEGIN{printf "%.3f", a+b}')"
  FINDINGS=$((FINDINGS + n))

  local color="$c_yel"
  awk -v c="$unit_cost" 'BEGIN{exit !(c > 0)}' && color="$c_red"
  printf '  %s✖%s %-42s %s hallazgo(s)' "$color" "$c_off" "$title" "$n"
  awk -v c="$unit_cost" 'BEGIN{exit !(c > 0)}' \
    && printf '  ~$%s/hr' "$subtotal"
  printf '\n'
  printf '%s' "$items" | sed "s/^/      ${c_dim}·${c_off} /"
  printf '\n'
}

printf '\n%s=== Auditoría de recursos EKS · región %s ===%s\n' "$c_cyn" "$REGION" "$c_off"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  printf '%s✖ Credenciales AWS no válidas.%s\n' "$c_red" "$c_off"
  exit 2
fi
ACCT="$(aws sts get-caller-identity --query Account --output text)"
printf '%sCuenta: %s%s\n\n' "$c_dim" "$ACCT" "$c_off"

printf '%s-- Cómputo y control plane --%s\n' "$c_cyn" "$c_off"
check "Clusters EKS" 0.10 \
  aws eks list-clusters --region "$REGION" --query 'clusters' --output text

check "Instancias EC2 activas" 0.042 \
  aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=pending,running,stopping" \
  --query 'Reservations[].Instances[].InstanceId' --output text

check "Auto Scaling groups de EKS" 0 \
  aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, 'eks-')].AutoScalingGroupName" \
  --output text

printf '\n%s-- Red (aquí se esconde la fuga de costo) --%s\n' "$c_cyn" "$c_off"
check "NAT Gateways" 0.045 \
  aws ec2 describe-nat-gateways --region "$REGION" \
  --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text

check "Elastic IPs sin asociar" 0.005 \
  aws ec2 describe-addresses --region "$REGION" \
  --query 'Addresses[?AssociationId==null].PublicIp' --output text

check "Load Balancers (ALB/NLB)" 0.0225 \
  aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].LoadBalancerName' --output text

check "Load Balancers (Classic)" 0.025 \
  aws elb describe-load-balancers --region "$REGION" \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text

check "Target groups huérfanos" 0 \
  aws elbv2 describe-target-groups --region "$REGION" \
  --query 'TargetGroups[?length(LoadBalancerArns)==`0`].TargetGroupName' --output text

check "ENIs disponibles (bloquean la VPC)" 0 \
  aws ec2 describe-network-interfaces --region "$REGION" \
  --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text

check "VPCs de los labs" 0 \
  aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=lab-vpc,ec2-lab-vpc,automode-lab-vpc" \
  --query 'Vpcs[].VpcId' --output text

printf '\n%s-- Almacenamiento --%s\n' "$c_cyn" "$c_off"
check "Volúmenes EBS sin adjuntar" 0.011 \
  aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text

check "Sistemas de archivos EFS" 0 \
  aws efs describe-file-systems --region "$REGION" \
  --query 'FileSystems[].FileSystemId' --output text

check "Log groups de EKS" 0 \
  aws logs describe-log-groups --region "$REGION" \
  --log-group-name-prefix "/aws/eks/" --query 'logGroups[].logGroupName' --output text

printf '\n%s-- IAM (no cuesta, pero estorba en el próximo lab) --%s\n' "$c_cyn" "$c_off"
check "Roles de los labs" 0 \
  aws iam list-roles \
  --query "Roles[?starts_with(RoleName, 'eks-lab-') || starts_with(RoleName, 'eks-ec2-lab-') || starts_with(RoleName, 'eks-automode-lab-')].RoleName" \
  --output text

check "Policy del LB Controller" 0 \
  aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].PolicyName" --output text

check "OIDC providers" 0 \
  aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[].Arn' --output text

check "Stacks de eksctl" 0 \
  aws cloudformation list-stacks --region "$REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?starts_with(StackName, 'eksctl-')].StackName" --output text

printf '\n%s' "$c_cyn"; printf '%.0s─' {1..64}; printf '%s\n' "$c_off"

if (( FINDINGS == 0 )); then
  printf '%s✔ Todo limpio. No hay recursos de los labs en %s.%s\n\n' "$c_grn" "$REGION" "$c_off"
  exit 0
fi

printf '%s✖ %s recurso(s) encontrados · costo estimado ~$%s/hr (~$%s/mes)%s\n' \
  "$c_red" "$FINDINGS" "$COST_HR" \
  "$(awk -v c="$COST_HR" 'BEGIN{printf "%.2f", c*730}')" "$c_off"
printf '%sOrden de limpieza sugerido: Load Balancers → NAT Gateways → EIPs → ENIs → VPC%s\n' \
  "$c_dim" "$c_off"
printf '%sLos costos son aproximados para us-east-1 y sirven solo para priorizar.%s\n\n' \
  "$c_dim" "$c_off"
exit 1
