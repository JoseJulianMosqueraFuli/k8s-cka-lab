# destroy.ps1 - Elimina todos los recursos del lab 06 (Storage + Scaling + Velero)
# Uso: .\destroy.ps1

$Region = "us-east-1"
$AccountId = aws sts get-caller-identity --query "Account" --output text
$ClusterName = "automode-lab-cluster"
$Namespace = "apps"
$VeleroBucket = "velero-backups-${AccountId}-${Region}"

Write-Host "=== DESTRUYENDO LAB 06 (Storage + Scaling) ===" -ForegroundColor Red
Write-Host "Account ID: $AccountId" -ForegroundColor DarkGray
Write-Host ""

# 1. Kubernetes workloads
Write-Host "[1/7] Borrando workloads..." -ForegroundColor Yellow
kubectl delete deploy cpu-burner writer-efs -n $Namespace 2>$null
kubectl delete statefulset data-store -n $Namespace 2>$null
kubectl delete hpa cpu-burner-hpa -n $Namespace 2>$null
kubectl delete pdb data-store-pdb -n $Namespace 2>$null

# 2. PVCs (esto borra los volumenes EBS con reclaimPolicy Delete)
Write-Host "[2/7] Borrando PVCs..." -ForegroundColor Yellow
kubectl delete pvc -l app=data-store -n $Namespace 2>$null
kubectl delete pvc shared-data -n $Namespace 2>$null
Write-Host "  Esperando 30s para que el CSI borre los volumenes..." -ForegroundColor DarkYellow
Start-Sleep -Seconds 30

# 3. Velero
Write-Host "[3/7] Desinstalando Velero..." -ForegroundColor Yellow
helm uninstall velero -n velero 2>$null
kubectl delete namespace velero 2>$null
aws s3 rb "s3://$VeleroBucket" --force 2>$null

# 4. EFS
Write-Host "[4/7] Borrando EFS..." -ForegroundColor Yellow
$efsId = aws efs describe-file-systems --region $Region `
    --query "FileSystems[?Name=='eks-lab-efs'].FileSystemId" --output text 2>$null
if ($efsId -and $efsId -ne "None") {
    # Borrar mount targets primero
    $mountTargets = aws efs describe-mount-targets --file-system-id $efsId --region $Region `
        --query "MountTargets[].MountTargetId" --output text 2>$null
    if ($mountTargets -and $mountTargets -ne "None") {
        foreach ($mt in $mountTargets.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
            aws efs delete-mount-target --mount-target-id $mt --region $Region 2>$null
        }
    }
    Write-Host "  Esperando 30s para que se borren los mount targets..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 30
    aws efs delete-file-system --file-system-id $efsId --region $Region 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  EFS $efsId borrado" -ForegroundColor Green
    }
} else {
    Write-Host "  No se encontro EFS" -ForegroundColor DarkYellow
}

# 5. Security group de EFS
Write-Host "[5/7] Borrando security group de EFS..." -ForegroundColor Yellow
$efsSg = aws ec2 describe-security-groups --region $Region `
    --filters "Name=group-name,Values=eks-lab-efs-sg" `
    --query "SecurityGroups[0].GroupId" --output text 2>$null
if ($efsSg -and $efsSg -ne "None") {
    aws ec2 delete-security-group --group-id $efsSg --region $Region 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  SG $efsSg borrado" -ForegroundColor Green
    }
} else {
    Write-Host "  SG no encontrado" -ForegroundColor DarkYellow
}

# 6. Volumenes EBS huerfanos
Write-Host "[6/7] Verificando volumenes EBS huerfanos..." -ForegroundColor Yellow
$orphans = aws ec2 describe-volumes --region $Region `
    --filters "Name=status,Values=available" `
    --query "Volumes[?Tags[?Key=='kubernetes.io/created-for/pvc/namespace' && Value=='$Namespace']].VolumeId" `
    --output text 2>$null
if ($orphans -and $orphans -ne "None") {
    foreach ($vol in $orphans.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
        aws ec2 delete-volume --volume-id $vol --region $Region 2>$null
        Write-Host "  Volumen $vol borrado" -ForegroundColor Green
    }
} else {
    Write-Host "  Sin volumenes huerfanos" -ForegroundColor DarkYellow
}

# 7. Namespace
Write-Host "[7/7] Borrando namespace..." -ForegroundColor Yellow
kubectl delete namespace $Namespace 2>$null

Write-Host ""
Write-Host "=== Lab 06 limpio ===" -ForegroundColor Green
