# destroy.ps1 - Elimina todos los recursos del lab 07 (Networking + Isolation)
# Uso: .\destroy.ps1

Write-Host "=== DESTRUYENDO LAB 07 (Networking) ===" -ForegroundColor Red
Write-Host ""

# 1. Los namespaces contienen todo: deploys, services, network policies, quotas, RBAC
Write-Host "[1/2] Borrando namespaces (borra todo lo que contienen)..." -ForegroundColor Yellow
foreach ($ns in @("frontend", "backend", "database", "team-alpha")) {
    kubectl delete namespace $ns 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  $ns borrado" -ForegroundColor Green
    }
}

# 2. Revertir prefix delegation si se habilito
Write-Host "[2/2] Verificando prefix delegation..." -ForegroundColor Yellow
$envJson = kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env}' 2>$null
if ($envJson -match "ENABLE_PREFIX_DELEGATION.*true") {
    $ans = Read-Host "  Revertir prefix delegation? [s/N]"
    if ($ans -match "^[sS]$") {
        kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=false WARM_PREFIX_TARGET-
        Write-Host "  Prefix delegation deshabilitado" -ForegroundColor Green
    }
} else {
    Write-Host "  Prefix delegation no estaba habilitado" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=== Lab 07 limpio ===" -ForegroundColor Green
