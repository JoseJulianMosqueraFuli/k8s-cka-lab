# destroy.ps1 - Elimina todos los recursos del lab EKS Auto Mode
# Uso: .\destroy.ps1

Write-Host "=== DESTRUYENDO LAB EKS AUTO MODE ===" -ForegroundColor Red
Write-Host ""

# 1. Eliminar recursos de Kubernetes
Write-Host "[1/7] Eliminando Service, Deployment y Namespace..." -ForegroundColor Yellow
kubectl delete svc nginx -n apps 2>$null
kubectl delete deployment nginx -n apps 2>$null
kubectl delete namespace apps 2>$null

# 2. Esperar que AWS borre el NLB
Write-Host "[2/7] Esperando 60s para que AWS elimine el Load Balancer..." -ForegroundColor Yellow
Start-Sleep -Seconds 60

# 3. Eliminar el cluster (Auto Mode termina los nodos automaticamente)
Write-Host "[3/7] Eliminando cluster EKS (Auto Mode limpia los nodos solo)..." -ForegroundColor Yellow
aws eks delete-cluster --name automode-lab-cluster --region us-east-1 | Out-Null

Write-Host "[4/7] Esperando a que el cluster se elimine..." -ForegroundColor Yellow
aws eks wait cluster-deleted --name automode-lab-cluster --region us-east-1 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Timeout del waiter, esperando 120s extra..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 120
}

# 4. Obtener VPC ID y eliminar NAT Gateway + EIP
Write-Host "[5/7] Eliminando NAT Gateway y Elastic IP..." -ForegroundColor Yellow
$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=automode-lab-vpc" --region us-east-1 --query "Vpcs[0].VpcId" --output text

if ($vpcId -and $vpcId -ne "None") {
    # Eliminar NAT Gateway
    $natId = aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpcId" --region us-east-1 --query "NatGateways[?State!='deleted'].NatGatewayId" --output text
    if ($natId -and $natId -ne "None") {
        aws ec2 delete-nat-gateway --nat-gateway-id $natId --region us-east-1 | Out-Null
        Write-Host "  NAT Gateway $natId eliminandose, esperando 60s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 60
    }

    # Liberar Elastic IP
    $eipAllocId = aws ec2 describe-addresses --filters "Name=tag:Name,Values=*automode-lab*" --region us-east-1 --query "Addresses[0].AllocationId" --output text
    if ($eipAllocId -and $eipAllocId -ne "None") {
        aws ec2 release-address --allocation-id $eipAllocId --region us-east-1
        Write-Host "  Elastic IP $eipAllocId liberada" -ForegroundColor DarkYellow
    }
}

# 5. Recordatorio VPC
Write-Host "[6/7] VPC: eliminala desde la consola -> VPC -> $vpcId -> Actions -> Delete VPC" -ForegroundColor Cyan
Write-Host "  (La consola borra subnets, IGW y route tables automaticamente)" -ForegroundColor DarkCyan

# 6. Eliminar IAM roles
Write-Host "[7/7] Eliminando IAM roles..." -ForegroundColor Yellow
aws iam detach-role-policy --role-name eks-automode-lab-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam detach-role-policy --role-name eks-automode-lab-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSComputePolicy
aws iam detach-role-policy --role-name eks-automode-lab-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicyV2
aws iam detach-role-policy --role-name eks-automode-lab-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy
aws iam detach-role-policy --role-name eks-automode-lab-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy
aws iam delete-role --role-name eks-automode-lab-cluster-role

aws iam detach-role-policy --role-name eks-automode-lab-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy
aws iam detach-role-policy --role-name eks-automode-lab-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly
aws iam delete-role --role-name eks-automode-lab-node-role

Write-Host ""
Write-Host "=== LISTO! Solo queda borrar la VPC desde la consola ===" -ForegroundColor Green
