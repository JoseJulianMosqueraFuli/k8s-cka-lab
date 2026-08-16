# destroy.ps1 - Elimina todos los recursos del lab EKS Fargate
# Uso: .\destroy.ps1
# IMPORTANTE: Reemplaza <TU_ACCOUNT_ID> con tu AWS Account ID antes de ejecutar

param(
    [Parameter(Mandatory=$false)]
    [string]$AccountId
)

# Obtener Account ID automaticamente si no se paso como parametro
if (-not $AccountId) {
    $AccountId = aws sts get-caller-identity --query "Account" --output text
    Write-Host "Account ID detectado: $AccountId" -ForegroundColor DarkGray
}

Write-Host "=== DESTRUYENDO LAB EKS FARGATE ===" -ForegroundColor Red
Write-Host ""

# 1. Eliminar recursos de Kubernetes
Write-Host "[1/11] Eliminando Service y Deployment..." -ForegroundColor Yellow
kubectl delete svc nginx -n apps 2>$null
kubectl delete deployment nginx -n apps 2>$null

# 2. Esperar que AWS borre el NLB
Write-Host "[2/11] Esperando 60s para que AWS elimine el Load Balancer..." -ForegroundColor Yellow
Start-Sleep -Seconds 60

# 3. Desinstalar LB Controller
Write-Host "[3/11] Desinstalando AWS Load Balancer Controller..." -ForegroundColor Yellow
helm uninstall aws-load-balancer-controller -n kube-system 2>$null

# 4. Eliminar Service Account IAM (CloudFormation stack)
Write-Host "[4/11] Eliminando IAM Service Account (CloudFormation stack)..." -ForegroundColor Yellow
eksctl delete iamserviceaccount --cluster=lab-cluster --namespace=kube-system --name=aws-load-balancer-controller --region us-east-1 2>$null
Start-Sleep -Seconds 30

# 5. Eliminar IAM Policy del LB Controller
Write-Host "[5/11] Eliminando IAM Policy del LB Controller..." -ForegroundColor Yellow
aws iam delete-policy --policy-arn "arn:aws:iam::${AccountId}:policy/AWSLoadBalancerControllerIAMPolicy" 2>$null

# 6. Eliminar Fargate Profiles (uno a la vez, no se pueden borrar en paralelo)
Write-Host "[6/11] Eliminando Fargate Profiles..." -ForegroundColor Yellow
aws eks delete-fargate-profile --cluster-name lab-cluster --fargate-profile-name fp-apps --region us-east-1 | Out-Null
Write-Host "  Esperando que fp-apps se elimine..." -ForegroundColor DarkYellow
aws eks wait fargate-profile-deleted --cluster-name lab-cluster --fargate-profile-name fp-apps --region us-east-1 2>$null
Start-Sleep -Seconds 10

aws eks delete-fargate-profile --cluster-name lab-cluster --fargate-profile-name fp-system --region us-east-1 | Out-Null
Write-Host "  Esperando que fp-system se elimine..." -ForegroundColor DarkYellow
aws eks wait fargate-profile-deleted --cluster-name lab-cluster --fargate-profile-name fp-system --region us-east-1 2>$null

# 7. Eliminar el cluster
Write-Host "[7/11] Eliminando cluster EKS..." -ForegroundColor Yellow
aws eks delete-cluster --name lab-cluster --region us-east-1 | Out-Null

Write-Host "[8/11] Esperando a que el cluster se elimine..." -ForegroundColor Yellow
aws eks wait cluster-deleted --name lab-cluster --region us-east-1 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Timeout del waiter, esperando 120s extra..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 120
}

# 8. Eliminar NAT Gateway y Elastic IP
Write-Host "[9/11] Eliminando NAT Gateway y Elastic IP..." -ForegroundColor Yellow
$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=lab-vpc" --region us-east-1 --query "Vpcs[0].VpcId" --output text

if ($vpcId -and $vpcId -ne "None") {
    # Eliminar NAT Gateway
    $natId = aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpcId" --region us-east-1 --query "NatGateways[?State!='deleted'].NatGatewayId" --output text
    if ($natId -and $natId -ne "None") {
        aws ec2 delete-nat-gateway --nat-gateway-id $natId --region us-east-1 | Out-Null
        Write-Host "  NAT Gateway $natId eliminandose, esperando 60s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 60
    }

    # Liberar Elastic IP
    $eipAllocId = aws ec2 describe-addresses --filters "Name=tag:Name,Values=*lab*" --region us-east-1 --query "Addresses[0].AllocationId" --output text
    if ($eipAllocId -and $eipAllocId -ne "None") {
        aws ec2 release-address --allocation-id $eipAllocId --region us-east-1
        Write-Host "  Elastic IP $eipAllocId liberada" -ForegroundColor DarkYellow
    }
}

# 9. Recordatorio VPC
Write-Host "[10/11] VPC: eliminala desde la consola -> VPC -> $vpcId -> Actions -> Delete VPC" -ForegroundColor Cyan
Write-Host "  (La consola borra subnets, IGW y route tables automaticamente)" -ForegroundColor DarkCyan

# 10. Eliminar IAM roles
Write-Host "[11/11] Eliminando IAM roles..." -ForegroundColor Yellow
aws iam detach-role-policy --role-name eks-lab-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam delete-role --role-name eks-lab-cluster-role

aws iam detach-role-policy --role-name eks-lab-fargate-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy
aws iam delete-role --role-name eks-lab-fargate-role

# 11. Eliminar OIDC Provider
Write-Host "Eliminando OIDC Provider..." -ForegroundColor Yellow
$oidcId = aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, 'lab-cluster')].Arn" --output text 2>$null
if ($oidcId -and $oidcId -ne "None" -and $oidcId -ne "") {
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $oidcId
    Write-Host "  OIDC Provider eliminado" -ForegroundColor DarkYellow
} else {
    Write-Host "  OIDC Provider no encontrado (puede que eksctl ya lo haya eliminado)" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=== LISTO! Solo queda borrar la VPC desde la consola ===" -ForegroundColor Green
