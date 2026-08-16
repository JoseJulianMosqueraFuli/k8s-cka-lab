# destroy.ps1 - Elimina todos los recursos del lab 13 (FinOps)
# Uso: .\destroy.ps1

$Region = "us-east-1"

Write-Host "=== DESTRUYENDO LAB 13 (FinOps) ===" -ForegroundColor Red
Write-Host ""

# 1. OpenCost / Kubecost
Write-Host "[1/4] Desinstalando herramientas de costos..." -ForegroundColor Yellow
helm uninstall opencost -n opencost 2>$null
helm uninstall kubecost -n kubecost 2>$null
kubectl delete namespace opencost kubecost 2>$null

# 2. VPA
Write-Host "[2/4] Desinstalando VPA..." -ForegroundColor Yellow
if (Test-Path "/tmp/autoscaler/vertical-pod-autoscaler") {
    Push-Location "/tmp/autoscaler/vertical-pod-autoscaler"
    bash ./hack/vpa-down.sh 2>$null
    Pop-Location
    Write-Host "  VPA desinstalado" -ForegroundColor Green
} else {
    kubectl delete vpa --all -A 2>$null
    kubectl delete deployment vpa-recommender vpa-updater vpa-admission-controller -n kube-system 2>$null
    Write-Host "  VPA recursos borrados (script no encontrado)" -ForegroundColor DarkYellow
}

# 3. Deployments de prueba
Write-Host "[3/4] Borrando workloads de prueba..." -ForegroundColor Yellow
kubectl delete deploy consolidation-test 2>$null
kubectl delete nodepool mixed-pool 2>$null

# 4. Verificacion de waste
Write-Host "[4/4] Ejecutando verificacion de waste residual..." -ForegroundColor Yellow
Write-Host ""
Write-Host "--- Volumenes EBS sin usar ---" -ForegroundColor Cyan
aws ec2 describe-volumes --region $Region `
    --filters "Name=status,Values=available" `
    --query "Volumes[].[VolumeId,Size,CreateTime]" --output table 2>$null

Write-Host ""
Write-Host "--- Elastic IPs sin asociar ---" -ForegroundColor Cyan
aws ec2 describe-addresses --region $Region `
    --query "Addresses[?AssociationId==null].[PublicIp,AllocationId]" --output table 2>$null

Write-Host ""
Write-Host "=== Lab 13 limpio ===" -ForegroundColor Green
Write-Host "Para auditoria completa: ..\scripts\verify-clean.sh" -ForegroundColor Cyan
