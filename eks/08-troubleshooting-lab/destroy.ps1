# destroy.ps1 - Elimina todos los recursos del lab 08 (Troubleshooting)
# Uso: .\destroy.ps1
# Este lab usa un cluster desechable de eksctl — se borra completo.

$Region = "us-east-1"
$ClusterName = "eks-troubleshoot-lab"

Write-Host "=== DESTRUYENDO LAB 08 (Troubleshooting) ===" -ForegroundColor Red
Write-Host "Borrando cluster desechable: $ClusterName" -ForegroundColor Cyan
Write-Host ""

# Verificar que eksctl esta instalado
$eksctlPath = Get-Command eksctl -ErrorAction SilentlyContinue
if (-not $eksctlPath) {
    Write-Host "ERROR: eksctl no esta instalado. Instalalo o borra manualmente:" -ForegroundColor Red
    Write-Host "  aws eks delete-cluster --name $ClusterName --region $Region" -ForegroundColor DarkYellow
    exit 1
}

Write-Host "Eliminando cluster con eksctl (puede tardar ~10 min)..." -ForegroundColor Yellow
eksctl delete cluster --name $ClusterName --region $Region --wait

Write-Host ""
Write-Host "=== Lab 08 limpio ===" -ForegroundColor Green
Write-Host "Verifica con: ..\scripts\verify-clean.sh" -ForegroundColor Cyan
