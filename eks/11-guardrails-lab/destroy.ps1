# destroy.ps1 - Elimina todos los recursos del lab 11 (Guardrails / Kyverno)
# Uso: .\destroy.ps1

$Region = "us-east-1"
$AccountId = aws sts get-caller-identity --query "Account" --output text

Write-Host "=== DESTRUYENDO LAB 11 (Guardrails) ===" -ForegroundColor Red
Write-Host "Account ID: $AccountId" -ForegroundColor DarkGray
Write-Host ""

# 1. Politicas de Kyverno
Write-Host "[1/6] Borrando politicas y excepciones..." -ForegroundColor Yellow
kubectl delete clusterpolicy --all 2>$null
kubectl delete policyexception -n kyverno --all 2>$null

# 2. Kyverno
Write-Host "[2/6] Desinstalando Kyverno..." -ForegroundColor Yellow
helm uninstall kyverno -n kyverno 2>$null
kubectl delete namespace kyverno 2>$null

# 3. Namespaces de prueba
Write-Host "[3/6] Borrando namespaces y pods de prueba..." -ForegroundColor Yellow
kubectl delete namespace team-alpha 2>$null
kubectl delete pod test-tagged test-latest test-latest2 with-resources 2>$null

# 4. kube-bench (Paso 9) - un Job completado no se limpia solo
Write-Host "[4/6] Borrando Job de kube-bench..." -ForegroundColor Yellow
kubectl delete job kube-bench 2>$null
kubectl delete job kube-bench-node 2>$null

# 5. KMS key (schedule deletion)
Write-Host "[5/6] Buscando KMS key del lab..." -ForegroundColor Yellow
$kmsKey = aws kms list-aliases --region $Region `
    --query "Aliases[?AliasName=='alias/eks-secrets'].TargetKeyId" --output text 2>$null
if ($kmsKey -and $kmsKey -ne "None") {
    $ans = Read-Host "  Programar borrado de KMS key $kmsKey en 7 dias? [s/N]"
    if ($ans -match "^[sS]$") {
        aws kms schedule-key-deletion --key-id $kmsKey `
            --pending-window-in-days 7 --region $Region 2>$null | Out-Null
        aws kms delete-alias --alias-name alias/eks-secrets --region $Region 2>$null
        Write-Host "  KMS key programada para borrado en 7 dias" -ForegroundColor Green
    }
} else {
    Write-Host "  No se encontro KMS key" -ForegroundColor DarkYellow
}

# 6. PSS labels (revertir)
Write-Host "[6/6] Removiendo labels PSS de namespaces..." -ForegroundColor Yellow
$namespaces = kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>$null
if ($namespaces) {
    foreach ($ns in $namespaces.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)) {
        kubectl label namespace $ns pod-security.kubernetes.io/enforce- `
            pod-security.kubernetes.io/warn- pod-security.kubernetes.io/audit- 2>$null
    }
    Write-Host "  Labels PSS removidos" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Lab 11 limpio ===" -ForegroundColor Green
