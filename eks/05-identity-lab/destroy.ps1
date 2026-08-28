# destroy.ps1 - Elimina todos los recursos del lab 05 (Identity: IRSA + Pod Identity + External Secrets)
# Uso: .\destroy.ps1

$Region = "us-east-1"
$AccountId = aws sts get-caller-identity --query "Account" --output text
$ClusterName = "ec2-lab-cluster"
$Namespace = "apps"
$RoleIrsa = "eks-lab-s3-reader-irsa"
$RolePodId = "eks-lab-s3-reader-podid"
$RoleEso = "eks-lab-external-secrets"
$PolicyName = "eks-lab-s3-reader"
$PolicyEsoName = "eks-lab-eso-read"
$BucketName = "k8s-lab-identity-${AccountId}-${Region}"
$SecretName = "k8s-lab/identity-api/db"

Write-Host "=== DESTRUYENDO LAB 05 (Identity) ===" -ForegroundColor Red
Write-Host "Account ID: $AccountId" -ForegroundColor DarkGray
Write-Host ""

# 1. Kubernetes
Write-Host "[1/7] Borrando deployments y service accounts..." -ForegroundColor Yellow
kubectl delete deploy identity-api-irsa identity-api-podid -n $Namespace 2>$null
kubectl delete sa identity-api-irsa identity-api-podid -n $Namespace 2>$null
kubectl delete pod naked-pod -n $Namespace 2>$null

# 2. External Secrets Operator (Paso 9)
# Los ExternalSecret van primero: si se va el operator antes, los finalizers
# de las CRDs pueden dejar los objetos colgados
Write-Host "[2/7] Desinstalando External Secrets Operator..." -ForegroundColor Yellow
kubectl delete externalsecret --all -A 2>$null
kubectl delete clustersecretstore --all 2>$null
kubectl delete secretstore --all -A 2>$null
helm uninstall external-secrets -n external-secrets 2>$null
kubectl delete namespace external-secrets 2>$null
# Secrets Store CSI Driver, si se probo la alternativa del Paso 9.7
helm uninstall csi-secrets-store -n kube-system 2>$null

# 3. Pod Identity associations (la de la app y la del operator)
Write-Host "[3/7] Borrando Pod Identity associations..." -ForegroundColor Yellow
foreach ($sa in @("identity-api-podid", "external-secrets")) {
    $assocIds = aws eks list-pod-identity-associations --cluster-name $ClusterName --region $Region `
        --query "associations[?serviceAccount=='$sa'].associationId" --output text 2>$null
    if ($assocIds -and $assocIds -ne "None") {
        foreach ($id in $assocIds.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
            aws eks delete-pod-identity-association --cluster-name $ClusterName `
                --association-id $id --region $Region 2>$null | Out-Null
            Write-Host "  Association $id ($sa) borrada" -ForegroundColor Green
        }
    } else {
        Write-Host "  Sin association para $sa" -ForegroundColor DarkYellow
    }
}

# 4. IAM Roles - se sueltan TODAS las policies adjuntas, no una lista fija
Write-Host "[4/7] Borrando IAM roles..." -ForegroundColor Yellow
foreach ($role in @($RoleIrsa, $RolePodId, $RoleEso)) {
    aws iam get-role --role-name $role 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $attached = aws iam list-attached-role-policies --role-name $role `
            --query "AttachedPolicies[].PolicyArn" --output text 2>$null
        if ($attached -and $attached -ne "None") {
            foreach ($pa in $attached.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
                aws iam detach-role-policy --role-name $role --policy-arn $pa 2>$null
            }
        }
        aws iam delete-role --role-name $role 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Rol $role borrado" -ForegroundColor Green
        } else {
            Write-Host "  No pude borrar $role" -ForegroundColor DarkYellow
        }
    }
}

# 5. IAM Policies
Write-Host "[5/7] Borrando IAM policies..." -ForegroundColor Yellow
foreach ($p in @($PolicyName, $PolicyEsoName)) {
    $arn = "arn:aws:iam::${AccountId}:policy/${p}"
    aws iam delete-policy --policy-arn $arn 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Policy $p borrada" -ForegroundColor Green
    } else {
        Write-Host "  Policy $p no existia" -ForegroundColor DarkYellow
    }
}

# 6. Secreto de Secrets Manager
# Sin --force-delete-without-recovery queda 30 dias "scheduled for deletion",
# ocupando el nombre y facturando
Write-Host "[6/7] Borrando secreto de Secrets Manager..." -ForegroundColor Yellow
aws secretsmanager delete-secret --secret-id $SecretName `
    --force-delete-without-recovery --region $Region 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Secreto borrado" -ForegroundColor Green
} else {
    Write-Host "  Secreto no existia" -ForegroundColor DarkYellow
}

# 7. S3 bucket
Write-Host "[7/7] Borrando bucket S3..." -ForegroundColor Yellow
aws s3 rb "s3://$BucketName" --force 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Bucket borrado" -ForegroundColor Green
} else {
    Write-Host "  Bucket no existia" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=== Lab 05 limpio ===" -ForegroundColor Green
Write-Host "Nota: las CRDs de external-secrets.io siguen en el cluster (Helm no las borra)." -ForegroundColor DarkGray
