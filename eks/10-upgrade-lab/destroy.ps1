# destroy.ps1 - Elimina todos los recursos del lab 10 (Upgrade)
# Uso: .\destroy.ps1
# Este lab no crea infra nueva: usa el cluster existente y lo sube de version.
# Solo limpia los recursos de prueba (PDBs, deploys de test).
# Si hiciste blue/green, tambien destruye el cluster GREEN.

$Region = "us-east-1"

Write-Host "=== DESTRUYENDO LAB 10 (Upgrade) ===" -ForegroundColor Red
Write-Host ""

# 1. Recursos de prueba
Write-Host "[1/3] Borrando deploys y PDBs de prueba..." -ForegroundColor Yellow
kubectl delete deploy upgrade-test 2>$null
kubectl delete pdb upgrade-test-pdb too-strict pdb-strict 2>$null

# 2. Cluster GREEN (blue/green strategy)
Write-Host "[2/3] Verificando cluster GREEN..." -ForegroundColor Yellow
$greenCheck = aws eks describe-cluster --name eks-green-lab --region $Region 2>$null
if ($LASTEXITCODE -eq 0) {
    $ans = Read-Host "  Borrar el cluster GREEN (eks-green-lab)? [s/N]"
    if ($ans -match "^[sS]$") {
        if (Test-Path "infra/terraform/green") {
            Write-Host "  Destruyendo con Terraform..." -ForegroundColor DarkYellow
            Push-Location "infra/terraform/green"
            terraform destroy -auto-approve
            Pop-Location
        } else {
            Write-Host "  Sin Terraform state. Borrando con AWS CLI..." -ForegroundColor DarkYellow
            aws eks delete-cluster --name eks-green-lab --region $Region | Out-Null
            Write-Host "  Esperando... (puede tardar ~10 min)" -ForegroundColor DarkYellow
            aws eks wait cluster-deleted --name eks-green-lab --region $Region 2>$null
        }
    }
} else {
    Write-Host "  No hay cluster GREEN" -ForegroundColor DarkYellow
}

# 3. Herramientas temporales
Write-Host "[3/3] Limpiando herramientas descargadas..." -ForegroundColor Yellow
if (Test-Path "/usr/local/bin/pluto") {
    Remove-Item "/usr/local/bin/pluto" -Force
    Write-Host "  pluto removido" -ForegroundColor Green
} else {
    Write-Host "  pluto no encontrado (nada que limpiar)" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=== Lab 10 limpio ===" -ForegroundColor Green
Write-Host "Nota: el cluster principal sigue activo en la nueva version" -ForegroundColor Cyan
