# destroy.ps1 - Elimina todos los recursos del lab 04 (Ingress + ECR)
# Uso: .\destroy.ps1
# Este lab se monta sobre el cluster del lab 02 o 03; NO borra el cluster.

$Region = "us-east-1"
$RepoName = "k8s-lab/identity-api"
$Namespace = "apps"

Write-Host "=== DESTRUYENDO LAB 04 (Ingress + ECR) ===" -ForegroundColor Red
Write-Host ""

# 1. Recursos de Kubernetes
Write-Host "[1/4] Borrando Ingress, Service, Deployment y Pod..." -ForegroundColor Yellow
kubectl delete ingress identity-api -n $Namespace 2>$null
kubectl delete svc identity-api -n $Namespace 2>$null
kubectl delete deploy identity-api -n $Namespace 2>$null
kubectl delete pod identity-host -n $Namespace 2>$null

# Esperar a que el ALB se elimine
Write-Host "  Esperando 60s para que el ALB se elimine..." -ForegroundColor DarkYellow
Start-Sleep -Seconds 60

# 2. ECR (pregunta antes de borrar — se usa en labs 05-09)
Write-Host "[2/4] Repositorio ECR..." -ForegroundColor Yellow
$ans = Read-Host "  Borrar el repositorio ECR $RepoName? (se usa en labs 05-09) [s/N]"
if ($ans -match "^[sS]$") {
    aws ecr delete-repository --repository-name $RepoName --region $Region --force 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ECR $RepoName borrado" -ForegroundColor Green
    } else {
        Write-Host "  ECR no existia" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "  ECR conservado para los labs siguientes" -ForegroundColor Cyan
}

# 3. Certificados ACM
Write-Host "[3/4] Buscando certificados ACM del lab..." -ForegroundColor Yellow
$certs = aws acm list-certificates --region $Region --query "CertificateSummaryList[?contains(DomainName,'lab')].CertificateArn" --output text 2>$null
if ($certs -and $certs -ne "None") {
    foreach ($arn in $certs.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
        Write-Host "  Borrando certificado: $arn" -ForegroundColor DarkYellow
        aws acm delete-certificate --certificate-arn $arn --region $Region 2>$null
    }
} else {
    Write-Host "  No se encontraron certificados" -ForegroundColor DarkYellow
}

# 4. Namespace (solo si esta vacio)
Write-Host "[4/4] Verificando namespace..." -ForegroundColor Yellow
$remaining = kubectl get all -n $Namespace --no-headers 2>$null | Measure-Object -Line | Select-Object -ExpandProperty Lines
if ($remaining -eq 0) {
    kubectl delete namespace $Namespace 2>$null | Out-Null
    Write-Host "  Namespace $Namespace borrado" -ForegroundColor Green
} else {
    Write-Host "  Namespace $Namespace tiene $remaining recursos; no se borra" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=== Lab 04 limpio. El cluster base sigue activo ===" -ForegroundColor Green
