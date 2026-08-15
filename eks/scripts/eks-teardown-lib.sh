#!/usr/bin/env bash
# eks-teardown-lib.sh — Funciones compartidas para destruir labs de EKS.
#
# No se ejecuta directo. Se importa desde cada destroy.sh:
#   source "$(dirname "$0")/../scripts/eks-teardown-lib.sh"
#
# Principios de diseño:
#  - Nunca filtrar por tag:Name con wildcards. Se descubren los recursos
#    navegando las relaciones reales (cluster -> vpc -> nat -> eip).
#  - Nunca hardcodear ARNs de policies. Se listan las adjuntas y se sueltan.
#  - Esperar con waiters de AWS, no con sleeps fijos.
#  - Idempotente: se puede volver a correr si algo falló a medias.

# Sin `set -e`: en un teardown queremos seguir aunque un paso falle.
set -uo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# ---------------------------------------------------------------- logging ----
_c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_yel=$'\033[33m'
_c_cyn=$'\033[36m'; _c_dim=$'\033[2m';  _c_off=$'\033[0m'

step() { printf '%s\n%s==> %s%s\n' "" "$_c_cyn" "$*" "$_c_off"; }
info() { printf '    %s\n' "$*"; }
dim()  { printf '    %s%s%s\n' "$_c_dim" "$*" "$_c_off"; }
ok()   { printf '    %s✔ %s%s\n' "$_c_grn" "$*" "$_c_off"; }
warn() { printf '    %s! %s%s\n' "$_c_yel" "$*" "$_c_off"; }
fail() { printf '    %s✖ %s%s\n' "$_c_red" "$*" "$_c_off"; }

# `aws ... --output text` devuelve "None" o "" cuando no hay nada.
# Esta función normaliza eso a cadena vacía y parte tabs en líneas.
aws_list() {
  local out
  out="$("$@" 2>/dev/null)" || return 0
  [[ "$out" == "None" ]] && return 0
  printf '%s' "$out" | tr '\t' '\n' | grep -v '^$' || true
}

require_tools() {
  local missing=()
  for t in aws kubectl; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    fail "Faltan herramientas: ${missing[*]}"
    return 1
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    fail "Credenciales AWS no válidas. Corre 'aws configure' o exporta AWS_PROFILE."
    return 1
  fi
  dim "Región: $REGION · Cuenta: $(aws sts get-caller-identity --query Account --output text)"
}

confirm() {
  local answer
  printf '%s%s%s ' "$_c_yel" "${1:-¿Continuar?} [escribe 'si' para confirmar]:" "$_c_off"
  read -r answer
  [[ "$answer" == "si" ]]
}

# =============================================================== KUBERNETES ==
# Borra los objetos del namespace del lab. El Service tipo LoadBalancer
# tiene que irse ANTES del cluster: si borras el cluster primero, el
# Load Balancer queda huérfano en la cuenta cobrando.
k8s_teardown() {
  local ns="${1:-apps}"
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    dim "Namespace '$ns' no existe (o kubectl no apunta a este cluster). Salto."
    return 0
  fi
  info "Borrando Services tipo LoadBalancer en '$ns'..."
  local svc
  for svc in $(aws_list kubectl get svc -n "$ns" \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}'); do
    kubectl delete svc "$svc" -n "$ns" --wait=true --timeout=180s >/dev/null 2>&1 \
      && ok "Service $svc borrado" || warn "No pude borrar el Service $svc"
  done
  kubectl delete namespace "$ns" --wait=true --timeout=300s >/dev/null 2>&1 \
    && ok "Namespace $ns borrado" || warn "El namespace $ns no terminó de borrarse"
}

# Espera a que AWS realmente elimine los Load Balancers de la VPC.
# Reemplaza el "Start-Sleep -Seconds 60" a ciegas: si el LB tarda más,
# el sleep fijo te deja un LB huérfano y un ENI que bloquea la VPC.
wait_load_balancers_gone() {
  local vpc="$1" tries="${2:-30}" n=0 v2 v1
  step "Esperando que se eliminen los Load Balancers de $vpc"
  while ((n < tries)); do
    v2="$(aws_list aws elbv2 describe-load-balancers --region "$REGION" \
          --query "LoadBalancers[?VpcId=='$vpc'].LoadBalancerArn" --output text | wc -l)"
    v1="$(aws_list aws elb describe-load-balancers --region "$REGION" \
          --query "LoadBalancerDescriptions[?VPCId=='$vpc'].LoadBalancerName" --output text | wc -l)"
    if (( v2 == 0 && v1 == 0 )); then
      ok "No quedan Load Balancers en la VPC"
      return 0
    fi
    dim "Quedan $((v2 + v1)) LB(s)... ($((++n))/$tries)"
    sleep 15
  done
  warn "Timeout. Revisa a mano: EC2 -> Load Balancers"
}

# ====================================================================== EKS ==
eks_vpc_id() {
  aws eks describe-cluster --name "$1" --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null | grep '^vpc-' || true
}

eks_delete_nodegroups() {
  local cluster="$1" ng
  local ngs; ngs="$(aws_list aws eks list-nodegroups --cluster-name "$cluster" \
                    --region "$REGION" --query 'nodegroups' --output text)"
  [[ -z "$ngs" ]] && { dim "Sin node groups."; return 0; }
  for ng in $ngs; do
    info "Borrando node group $ng..."
    aws eks delete-nodegroup --cluster-name "$cluster" --nodegroup-name "$ng" \
      --region "$REGION" >/dev/null 2>&1
  done
  for ng in $ngs; do
    dim "Esperando node group $ng (hasta ~10 min)..."
    aws eks wait nodegroup-deleted --cluster-name "$cluster" --nodegroup-name "$ng" \
      --region "$REGION" 2>/dev/null && ok "$ng eliminado" || warn "Waiter de $ng expiró"
  done
}

# Los Fargate profiles NO se pueden borrar en paralelo: hay que uno a uno.
eks_delete_fargate_profiles() {
  local cluster="$1" fp
  local fps; fps="$(aws_list aws eks list-fargate-profiles --cluster-name "$cluster" \
                    --region "$REGION" --query 'fargateProfileNames' --output text)"
  [[ -z "$fps" ]] && { dim "Sin Fargate profiles."; return 0; }
  for fp in $fps; do
    info "Borrando Fargate profile $fp..."
    aws eks delete-fargate-profile --cluster-name "$cluster" --fargate-profile-name "$fp" \
      --region "$REGION" >/dev/null 2>&1
    dim "Esperando $fp (secuencial, obligatorio)..."
    aws eks wait fargate-profile-deleted --cluster-name "$cluster" \
      --fargate-profile-name "$fp" --region "$REGION" 2>/dev/null \
      && ok "$fp eliminado" || warn "Waiter de $fp expiró"
  done
}

eks_delete_cluster() {
  local cluster="$1"
  if ! aws eks describe-cluster --name "$cluster" --region "$REGION" >/dev/null 2>&1; then
    dim "El cluster $cluster ya no existe."
    return 0
  fi
  info "Borrando cluster $cluster..."
  aws eks delete-cluster --name "$cluster" --region "$REGION" >/dev/null 2>&1
  dim "Esperando (~10 min)..."
  aws eks wait cluster-deleted --name "$cluster" --region "$REGION" 2>/dev/null \
    && ok "Cluster eliminado" || warn "Waiter expiró; verifica en la consola"
}

# =================================================================== IAM =====
# Suelta TODAS las policies adjuntas (managed e inline) en vez de una lista
# hardcodeada de ARNs. Así funciona aunque hayas agregado permisos extra.
iam_delete_role() {
  local role="$1" arn name prof
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || { dim "Rol $role no existe."; return 0; }

  for arn in $(aws_list aws iam list-attached-role-policies --role-name "$role" \
               --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" >/dev/null 2>&1
    dim "detach $(basename "$arn")"
  done
  for name in $(aws_list aws iam list-role-policies --role-name "$role" \
                --query 'PolicyNames' --output text); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$name" >/dev/null 2>&1
    dim "delete inline $name"
  done
  # Un rol de nodos vive dentro de un instance profile. Si no lo sacas de ahí,
  # el delete-role falla con DeleteConflict.
  for prof in $(aws_list aws iam list-instance-profiles-for-role --role-name "$role" \
                --query 'InstanceProfiles[].InstanceProfileName' --output text); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$prof" \
      --role-name "$role" >/dev/null 2>&1
    aws iam delete-instance-profile --instance-profile-name "$prof" >/dev/null 2>&1
    dim "instance profile $prof eliminado"
  done
  aws iam delete-role --role-name "$role" >/dev/null 2>&1 \
    && ok "Rol $role eliminado" || fail "No pude borrar el rol $role"
}

# Borra una customer managed policy con todas sus versiones y desvinculándola
# de cualquier rol/usuario/grupo que la use.
iam_delete_policy() {
  local name="$1" arn acct target ver
  acct="$(aws sts get-caller-identity --query Account --output text)"
  arn="arn:aws:iam::${acct}:policy/${name}"
  aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1 || { dim "Policy $name no existe."; return 0; }

  for target in $(aws_list aws iam list-entities-for-policy --policy-arn "$arn" \
                  --query 'PolicyRoles[].RoleName' --output text); do
    aws iam detach-role-policy --role-name "$target" --policy-arn "$arn" >/dev/null 2>&1
  done
  for ver in $(aws_list aws iam list-policy-versions --policy-arn "$arn" \
               --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$ver" >/dev/null 2>&1
  done
  aws iam delete-policy --policy-arn "$arn" >/dev/null 2>&1 \
    && ok "Policy $name eliminada" || fail "No pude borrar la policy $name"
}

# Borra el OIDC provider del cluster buscándolo por el issuer URL real,
# no por "contains(Arn, 'lab-cluster')" que puede matchear otro cluster.
iam_delete_oidc_provider() {
  local issuer="$1" host arn
  [[ -z "$issuer" || "$issuer" == "None" ]] && { dim "Sin OIDC issuer."; return 0; }
  host="${issuer#https://}"
  arn="$(aws iam list-open-id-connect-providers \
         --query "OpenIDConnectProviderList[?ends_with(Arn, '$host')].Arn" \
         --output text 2>/dev/null)"
  if [[ -n "$arn" && "$arn" != "None" ]]; then
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn" >/dev/null 2>&1 \
      && ok "OIDC provider eliminado" || fail "No pude borrar el OIDC provider"
  else
    dim "OIDC provider no encontrado (eksctl pudo haberlo borrado)."
  fi
}

# ==================================================================== VPC ====
# Los ENIs que dejan EKS y los Load Balancers son la causa #1 de que
# "Delete VPC" falle en la consola. Hay que barrerlos primero.
vpc_delete_orphan_enis() {
  local vpc="$1" eni att
  for eni in $(aws_list aws ec2 describe-network-interfaces --region "$REGION" \
               --filters "Name=vpc-id,Values=$vpc" \
               --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text); do
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" >/dev/null 2>&1 \
      && dim "ENI $eni eliminado" || warn "ENI $eni no se pudo borrar (¿aún en uso?)"
  done
  local stuck
  stuck="$(aws_list aws ec2 describe-network-interfaces --region "$REGION" \
           --filters "Name=vpc-id,Values=$vpc" \
           --query 'NetworkInterfaces[].NetworkInterfaceId' --output text | wc -l)"
  (( stuck > 0 )) && warn "Quedan $stuck ENI(s) adjuntos; se liberan al borrar sus recursos padre."
  return 0
}

# Captura los AllocationId de las EIP DESDE el NAT antes de borrarlo.
# Así no dependemos de tags: la relación NAT -> EIP es la fuente de verdad.
vpc_delete_nat_and_eips() {
  local vpc="$1" nat allocs=() a
  local nats
  nats="$(aws_list aws ec2 describe-nat-gateways --region "$REGION" \
          --filter "Name=vpc-id,Values=$vpc" \
          --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text)"
  if [[ -z "$nats" ]]; then
    dim "Sin NAT Gateways activos."
  else
    for nat in $nats; do
      for a in $(aws_list aws ec2 describe-nat-gateways --region "$REGION" \
                 --nat-gateway-ids "$nat" \
                 --query 'NatGateways[].NatGatewayAddresses[].AllocationId' --output text); do
        allocs+=("$a")
      done
      info "Borrando NAT Gateway $nat (deja de cobrar \$0.045/hr)..."
      aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" >/dev/null 2>&1
    done
    for nat in $nats; do
      dim "Esperando $nat..."
      aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$nat" --region "$REGION" 2>/dev/null \
        && ok "$nat eliminado" || warn "Waiter de $nat expiró"
    done
  fi

  # Además de las del NAT, recoge EIP sueltas asociadas a ENIs de esta VPC.
  for a in $(aws_list aws ec2 describe-addresses --region "$REGION" \
             --query 'Addresses[?AssociationId==null].AllocationId' --output text); do
    allocs+=("$a")
  done

  for a in $(printf '%s\n' "${allocs[@]:-}" | sort -u | grep -v '^$'); do
    # Solo libera si ya no está asociada a nada.
    local assoc
    assoc="$(aws ec2 describe-addresses --allocation-ids "$a" --region "$REGION" \
             --query 'Addresses[0].AssociationId' --output text 2>/dev/null)"
    if [[ "$assoc" == "None" || -z "$assoc" ]]; then
      aws ec2 release-address --allocation-id "$a" --region "$REGION" >/dev/null 2>&1 \
        && ok "Elastic IP $a liberada" || warn "EIP $a no se pudo liberar"
    else
      dim "EIP $a sigue asociada; la salto."
    fi
  done
}

# Borra la VPC y todo lo que cuelga de ella. Esto es lo que los destroy.ps1
# dejaban como paso manual "ve a la consola" — el riesgo real de fuga de costo.
vpc_delete_full() {
  local vpc="$1"
  [[ -z "$vpc" || "$vpc" == "None" ]] && { warn "Sin VPC ID; salto el borrado de red."; return 0; }
  aws ec2 describe-vpcs --vpc-ids "$vpc" --region "$REGION" >/dev/null 2>&1 \
    || { dim "La VPC $vpc ya no existe."; return 0; }

  step "Borrando la VPC $vpc y sus dependencias"

  local id
  for id in $(aws_list aws ec2 describe-vpc-endpoints --region "$REGION" \
              --filters "Name=vpc-id,Values=$vpc" --query 'VpcEndpoints[].VpcEndpointId' --output text); do
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$id" --region "$REGION" >/dev/null 2>&1
    dim "VPC endpoint $id eliminado"
  done

  vpc_delete_nat_and_eips "$vpc"
  vpc_delete_orphan_enis "$vpc"

  for id in $(aws_list aws ec2 describe-internet-gateways --region "$REGION" \
              --filters "Name=attachment.vpc-id,Values=$vpc" \
              --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc" --region "$REGION" >/dev/null 2>&1
    aws ec2 delete-internet-gateway --internet-gateway-id "$id" --region "$REGION" >/dev/null 2>&1 \
      && dim "Internet Gateway $id eliminado"
  done

  for id in $(aws_list aws ec2 describe-subnets --region "$REGION" \
              --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id "$id" --region "$REGION" >/dev/null 2>&1 \
      && dim "Subnet $id eliminada" || warn "Subnet $id ocupada"
  done

  # La main route table no se puede borrar; se va con la VPC.
  for id in $(aws_list aws ec2 describe-route-tables --region "$REGION" \
              --filters "Name=vpc-id,Values=$vpc" \
              --query 'RouteTables[?!(Associations[?Main==`true`])].RouteTableId' --output text); do
    aws ec2 delete-route-table --route-table-id "$id" --region "$REGION" >/dev/null 2>&1 \
      && dim "Route table $id eliminada"
  done

  # Los SGs se referencian entre sí (el de EKS y el de los nodos), así que
  # primero se vacían las reglas y después se borran.
  local sgs; sgs="$(aws_list aws ec2 describe-security-groups --region "$REGION" \
                    --filters "Name=vpc-id,Values=$vpc" \
                    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)"
  for id in $sgs; do
    local perms
    perms="$(aws ec2 describe-security-groups --group-ids "$id" --region "$REGION" \
             --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)"
    [[ "$perms" != "[]" && -n "$perms" ]] && \
      aws ec2 revoke-security-group-ingress --group-id "$id" --ip-permissions "$perms" \
        --region "$REGION" >/dev/null 2>&1
    perms="$(aws ec2 describe-security-groups --group-ids "$id" --region "$REGION" \
             --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)"
    [[ "$perms" != "[]" && -n "$perms" ]] && \
      aws ec2 revoke-security-group-egress --group-id "$id" --ip-permissions "$perms" \
        --region "$REGION" >/dev/null 2>&1
  done
  for id in $sgs; do
    aws ec2 delete-security-group --group-id "$id" --region "$REGION" >/dev/null 2>&1 \
      && dim "Security group $id eliminado" || warn "SG $id todavía en uso"
  done

  local n=0
  while ((n < 6)); do
    if aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" >/dev/null 2>&1; then
      ok "VPC $vpc eliminada"
      return 0
    fi
    dim "La VPC aún tiene dependencias, reintento en 20s... ($((++n))/6)"
    sleep 20
    vpc_delete_orphan_enis "$vpc" >/dev/null
  done
  fail "No pude borrar la VPC $vpc. Corre scripts/verify-clean.sh para ver qué queda."
  return 1
}

# ========================================================== CLOUDFORMATION ==
# eksctl crea stacks para los IAM service accounts (IRSA).
cfn_delete_eksctl_stacks() {
  local cluster="$1" stack
  for stack in $(aws_list aws cloudformation list-stacks --region "$REGION" \
                 --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE \
                 --query "StackSummaries[?starts_with(StackName, 'eksctl-${cluster}-')].StackName" \
                 --output text); do
    info "Borrando stack de CloudFormation $stack..."
    aws cloudformation delete-stack --stack-name "$stack" --region "$REGION" >/dev/null 2>&1
    aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$REGION" 2>/dev/null \
      && ok "$stack eliminado" || warn "Waiter de $stack expiró"
  done
}

# Los log groups sobreviven al cluster y siguen cobrando almacenamiento.
logs_delete_cluster_groups() {
  local cluster="$1" lg
  for lg in $(aws_list aws logs describe-log-groups --region "$REGION" \
              --log-group-name-prefix "/aws/eks/${cluster}/" \
              --query 'logGroups[].logGroupName' --output text); do
    aws logs delete-log-group --log-group-name "$lg" --region "$REGION" >/dev/null 2>&1 \
      && dim "Log group $lg eliminado"
  done
}

finish_banner() {
  local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '\n%s=== Teardown terminado ===%s\n' "$_c_grn" "$_c_off"
  info "Verifica que no quedó nada cobrando:"
  printf '        %s/verify-clean.sh\n\n' "$script_dir"
}
