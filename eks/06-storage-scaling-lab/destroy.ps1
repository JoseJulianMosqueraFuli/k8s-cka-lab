# destroy.ps1 - Elimina todos los recursos del lab 06 (Storage + Scaling + KEDA + Velero)
# Uso: .\destroy.ps1

$Region = "us-east-1"
$AccountId = aws sts get-caller-identity --query "Account" --output text
$ClusterName = "automode-lab-cluster"
$Namespace = "apps"
$VeleroBucket = "velero-backups-${AccountId}-${Region}"
$QueueName = "k8s-lab-jobs"
$RoleKeda = "eks-lab-keda-sqs"
$PolicyKedaName = "eks-lab-keda-sqs-read"

Write-Host "=== DESTRUYENDO LAB 06 (Storage + Scaling) ===" -ForegroundColor Red
Write-Host "Account ID: $AccountId" -ForegroundColor DarkGray
Write-Host ""

# 1. KEDA (Parte 4) - va PRIMERO: el ScaledObject controla el Deployment del worker
# y es dueno de un HPA generado. Si se desinstala KEDA antes de borrar los
# ScaledObject, ese keda-hpa-* queda huerfano en el namespace.
Write-Host "[1/9] Desinstalando KEDA..." -ForegroundColor Yellow
kubectl delete scaledobject --all -n $Namespace 2>$null
kubectl delete scaledjob --all -n $Namespace 2>$null
kubectl delete triggerauthentication --all -n $Namespace 2>$null
helm uninstall keda -n keda 2>$null
kubectl delete namespace keda 2>$null

$leftoverHpa = kubectl get hpa -n $Namespace -o name 2>$null | Select-String "keda-hpa-"
if ($leftoverHpa) {
    foreach ($hpa in $leftoverHpa) {
        kubectl delete $hpa.ToString() -n $Namespace 2>$null
        Write-Host "  HPA huerfano borrado: $hpa" -ForegroundColor Green
    }
}

# 2. Kubernetes workloads
Write-Host "[2/9] Borrando workloads..." -ForegroundColor Yellow
kubectl delete deploy cpu-burner writer-efs queue-worker -n $Namespace 2>$null
kubectl delete sa queue-worker -n $Namespace 2>$null
kubectl delete statefulset data-store -n $Namespace 2>$null
kubectl delete hpa cpu-burner-hpa -n $Namespace 2>$null
kubectl delete pdb data-store-pdb -n $Namespace 2>$null

# 3. PVCs (esto borra los volumenes EBS con reclaimPolicy Delete)
Write-Host "[3/9] Borrando PVCs..." -ForegroundColor Yellow
kubectl delete pvc -l app=data-store -n $Namespace 2>$null
kubectl delete pvc shared-data -n $Namespace 2>$null
Write-Host "  Esperando 30s para que el CSI borre los volumenes..." -ForegroundColor DarkYellow
Start-Sleep -Seconds 30

# 4. Velero
Write-Host "[4/9] Desinstalando Velero..." -ForegroundColor Yellow
helm uninstall velero -n velero 2>$null
kubectl delete namespace velero 2>$null
aws s3 rb "s3://$VeleroBucket" --force 2>$null

# 5. EFS
Write-Host "[5/9] Borrando EFS..." -ForegroundColor Yellow
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

# 6. Security group de EFS
Write-Host "[6/9] Borrando security group de EFS..." -ForegroundColor Yellow
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

# 7. Volumenes EBS huerfanos
Write-Host "[7/9] Verificando volumenes EBS huerfanos..." -ForegroundColor Yellow
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

# 8. SQS + IAM de KEDA y del worker
Write-Host "[8/9] Borrando cola SQS e IAM de KEDA..." -ForegroundColor Yellow
foreach ($sa in @("keda-operator", "queue-worker")) {
    $assocIds = aws eks list-pod-identity-associations --cluster-name $ClusterName --region $Region `
        --query "associations[?serviceAccount=='$sa'].associationId" --output text 2>$null
    if ($assocIds -and $assocIds -ne "None") {
        foreach ($id in $assocIds.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
            aws eks delete-pod-identity-association --cluster-name $ClusterName `
                --association-id $id --region $Region 2>$null | Out-Null
            Write-Host "  Association $id ($sa) borrada" -ForegroundColor Green
        }
    }
}

aws iam get-role --role-name $RoleKeda 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    $attached = aws iam list-attached-role-policies --role-name $RoleKeda `
        --query "AttachedPolicies[].PolicyArn" --output text 2>$null
    if ($attached -and $attached -ne "None") {
        foreach ($pa in $attached.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
            aws iam detach-role-policy --role-name $RoleKeda --policy-arn $pa 2>$null
        }
    }
    aws iam delete-role --role-name $RoleKeda 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Rol $RoleKeda borrado" -ForegroundColor Green
    }
}

aws iam delete-policy --policy-arn "arn:aws:iam::${AccountId}:policy/${PolicyKedaName}" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Policy $PolicyKedaName borrada" -ForegroundColor Green
}

$queueUrl = aws sqs get-queue-url --queue-name $QueueName --region $Region `
    --query "QueueUrl" --output text 2>$null
if ($queueUrl -and $queueUrl -ne "None") {
    aws sqs delete-queue --queue-url $queueUrl --region $Region 2>$null
    Write-Host "  Cola $QueueName borrada" -ForegroundColor Green
} else {
    Write-Host "  Cola no encontrada" -ForegroundColor DarkYellow
}

# 9. Namespace
Write-Host "[9/9] Borrando namespace..." -ForegroundColor Yellow
kubectl delete namespace $Namespace 2>$null

Write-Host ""
Write-Host "=== Lab 06 limpio ===" -ForegroundColor Green
Write-Host "Nota: las CRDs de keda.sh siguen en el cluster (Helm no las borra)." -ForegroundColor DarkGray
