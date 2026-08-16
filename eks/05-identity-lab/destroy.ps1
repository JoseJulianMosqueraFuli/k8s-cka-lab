# destroy.ps1 - Elimina todos los recursos del lab 05 (Identity: IRSA + Pod Identity)
# Uso: .\destroy.ps1

$Region = "us-east-1"
$AccountId = aws sts get-caller-identity --query "Account" --output text
$ClusterName = "ec2-lab-cluster"
$Namespace = "apps"
$RoleIrsa = "eks-lab-s3-reader-irsa"
$RolePodId = "eks-lab-s3-reader-podid"
$PolicyName = "eks-lab-s3-reader"
$BucketName = "k8s-lab-identity-${AccountId}-${Region}"

Write-Host "=== DESTRUYENDO LAB 05 (Identity) ===" -ForegroundColor Red
Write-Host "Account ID: $AccountId" -ForegroundColor DarkGray
Write-Host ""

# 1. Kubernetes
Write-Host "[1/5] Borrando deployments y service accounts..." -ForegroundColor Yellow
kubectl delete deploy identity-api-irsa identity-api-podid -n $Namespace 2>$null
kubectl delete sa identity-api-irsa identity-api-podid -n $Namespace 2>$null
kubectl delete pod naked-pod -n $Namespace 2>$null

# 2. Pod Identity association
Write-Host "[2/5] Borrando Pod Identity association..." -ForegroundColor Yellow
$assocId = aws eks list-pod-identity-associations --cluster-name $ClusterName --region $Region `
    --query "associations[?serviceAccount=='identity-api-podid'].associationId" --output text 2>$null
if ($assocId -and $assocId -ne "None") {
    aws eks delete-pod-identity-association --cluster-name $ClusterName `
        --association-id $assocId --region $Region 2>$null | Out-Null
    Write-Host "  Association $assocId borrada" -ForegroundColor Green
} else {
    Write-Host "  No se encontro association" -ForegroundColor DarkYellow
}

# 3. IAM Roles
Write-Host "[3/5] Borrando IAM roles..." -ForegroundColor Yellow
$PolicyArn = "arn:aws:iam::${AccountId}:policy/${PolicyName}"

foreach ($role in @($RoleIrsa, $RolePodId)) {
    $roleExists = aws iam get-role --role-name $role 2>$null
    if ($LASTEXITCODE -eq 0) {
        aws iam detach-role-policy --role-name $role --policy-arn $PolicyArn 2>$null
        aws iam delete-role --role-name $role 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Rol $role borrado" -ForegroundColor Green
        } else {
            Write-Host "  No pude borrar $role" -ForegroundColor DarkYellow
        }
    }
}

# 4. IAM Policy
Write-Host "[4/5] Borrando IAM policy..." -ForegroundColor Yellow
aws iam delete-policy --policy-arn $PolicyArn 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Policy borrada" -ForegroundColor Green
} else {
    Write-Host "  Policy no existia" -ForegroundColor DarkYellow
}

# 5. S3 bucket
Write-Host "[5/5] Borrando bucket S3..." -ForegroundColor Yellow
aws s3 rb "s3://$BucketName" --force 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Bucket borrado" -ForegroundColor Green
} else {
    Write-Host "  Bucket no existia" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=== Lab 05 limpio ===" -ForegroundColor Green
