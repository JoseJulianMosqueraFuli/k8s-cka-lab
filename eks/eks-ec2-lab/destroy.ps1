# destroy.ps1 - Elimina todos los recursos del lab EKS EC2
# Uso: .\destroy.ps1

Write-Host "=== DESTRUYENDO LAB EKS EC2 ===" -ForegroundColor Red
Write-Host ""

# 1. Eliminar recursos de Kubernetes
Write-Host "[1/9] Eliminando Service, Deployment y Namespace..." -ForegroundColor Yellow
kubectl delete svc nginx -n apps 2>$null
kubectl delete deployment nginx -n apps 2>$null
kubectl delete namespace apps 2>$null

# 2. Esperar que AWS borre el CLB
Write-Host "[2/9] Esperando 60s para que AWS elimine el Load Balancer..." -ForegroundColor Yellow
Start-Sleep -Seconds 60

# 3. Eliminar Node Group
Write-Host "[3/9] Eliminando Node Group..." -ForegroundColor Yellow
aws eks delete-nodegroup --cluster-name ec2-lab-cluster --nodegroup-name ec2-lab-nodes --region us-east-1 | Out-Null

Write-Host "[4/9] Esperando 5 min para que el Node Group se elimine..." -ForegroundColor Yellow
aws eks wait nodegroup-deleted --cluster-name ec2-lab-cluster --nodegroup-name ec2-lab-nodes --region us-east-1 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Timeout del waiter, esperando 60s extra..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 60
}

# 4. Eliminar el cluster
Write-Host "[5/9] Eliminando cluster EKS..." -ForegroundColor Yellow
aws eks delete-cluster --name ec2-lab-cluster --region us-east-1 | Out-Null

Write-Host "[6/9] Esperando a que el cluster se elimine..." -ForegroundColor Yellow
aws eks wait cluster-deleted --name ec2-lab-cluster --region us-east-1 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Timeout del waiter, esperando 60s extra..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 60
}

# 5. Obtener VPC ID
Write-Host "[7/9] Eliminando NAT Gateway y Elastic IP..." -ForegroundColor Yellow
$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=ec2-lab-vpc" --region us-east-1 --query "Vpcs[0].VpcId" --output text

if ($vpcId -and $vpcId -ne "None") {
    # Eliminar NAT Gateway
    $natId = aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpcId" --region us-east-1 --query "NatGateways[?State!='deleted'].NatGatewayId" --output text
    if ($natId -and $natId -ne "None") {
        aws ec2 delete-nat-gateway --nat-gateway-id $natId --region us-east-1 | Out-Null
        Write-Host "  NAT Gateway $natId eliminandose, esperando 60s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 60
    }

    # Liberar Elastic IP
    $eipAllocId = aws ec2 describe-addresses --filters "Name=tag:Name,Values=*ec2-lab*" --region us-east-1 --query "Addresses[0].AllocationId" --output text
    if ($eipAllocId -and $eipAllocId -ne "None") {
        aws ec2 release-address --allocation-id $eipAllocId --region us-east-1
        Write-Host "  Elastic IP $eipAllocId liberada" -ForegroundColor DarkYellow
    }
}

# 6. Recordatorio VPC
Write-Host "[8/9] VPC: eliminala desde la consola -> VPC -> $vpcId -> Actions -> Delete VPC" -ForegroundColor Cyan
Write-Host "  (La consola borra subnets, IGW y route tables automaticamente)" -ForegroundColor DarkCyan

# 7. Eliminar IAM roles
Write-Host "[9/9] Eliminando IAM roles..." -ForegroundColor Yellow
aws iam detach-role-policy --role-name eks-ec2-lab-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam detach-role-policy --role-name eks-ec2-lab-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly
aws iam detach-role-policy --role-name eks-ec2-lab-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam delete-role --role-name eks-ec2-lab-node-role

aws iam detach-role-policy --role-name eks-ec2-lab-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam delete-role --role-name eks-ec2-lab-cluster-role

Write-Host ""
Write-Host "=== LISTO! Solo queda borrar la VPC desde la consola ===" -ForegroundColor Green
