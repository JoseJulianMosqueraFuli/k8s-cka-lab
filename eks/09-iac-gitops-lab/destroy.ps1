# destroy.ps1 - Elimina todos los recursos del lab 09 (IaC + GitOps)
# Uso: .\destroy.ps1

$Region = "us-east-1"
$AccountId = aws sts get-caller-identity --query "Account" --output text
$TfBucket = "terraform-state-${AccountId}-us-east-1"

Write-Host "=== DESTRUYENDO LAB 09 (IaC + GitOps) ===" -ForegroundColor Red
Write-Host "Account ID: $AccountId" -ForegroundColor DarkGray
Write-Host ""

# 1. Argo CD y apps
Write-Host "[1/5] Borrando Argo CD..." -ForegroundColor Yellow
kubectl delete application --all -n argocd 2>$null
helm uninstall argocd -n argocd 2>$null
kubectl delete namespace argocd argo-rollouts apps 2>$null

# 2. Cluster eksctl (si se creo)
Write-Host "[2/5] Buscando cluster eksctl..." -ForegroundColor Yellow
$clusterCheck = aws eks describe-cluster --name eks-gitops-lab --region $Region 2>$null
if ($LASTEXITCODE -eq 0) {
    $eksctlPath = Get-Command eksctl -ErrorAction SilentlyContinue
    if ($eksctlPath) {
        Write-Host "  Borrando cluster eksctl (eks-gitops-lab)..." -ForegroundColor DarkYellow
        eksctl delete cluster --name eks-gitops-lab --region $Region --wait
    } else {
        Write-Host "  eksctl no instalado. Borra manualmente el cluster eks-gitops-lab" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "  No hay cluster eks-gitops-lab" -ForegroundColor DarkYellow
}

# 3. Terraform (si se uso)
Write-Host "[3/5] Buscando infraestructura Terraform..." -ForegroundColor Yellow
if ((Test-Path "infra/terraform") -and (Test-Path "infra/terraform/.terraform/terraform.tfstate")) {
    Write-Host "  Encontrado estado Terraform local. Ejecutando destroy..." -ForegroundColor DarkYellow
    Push-Location "infra/terraform"
    terraform destroy -auto-approve
    Pop-Location
} elseif (Test-Path "infra/terraform") {
    Write-Host "  Directorio Terraform existe pero sin state local." -ForegroundColor DarkYellow
    Write-Host "  Si usaste backend S3, ejecuta manualmente:" -ForegroundColor Cyan
    Write-Host "    cd infra/terraform; terraform init; terraform destroy" -ForegroundColor Cyan
} else {
    Write-Host "  No se encontro directorio Terraform" -ForegroundColor DarkYellow
}

# 4. Terraform state backend (pregunta)
Write-Host "[4/5] Terraform state backend..." -ForegroundColor Yellow
$ans = Read-Host "  Borrar el bucket de state S3 ($TfBucket) y DynamoDB? [s/N]"
if ($ans -match "^[sS]$") {
    aws s3 rb "s3://$TfBucket" --force 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Bucket $TfBucket borrado" -ForegroundColor Green
    }
    aws dynamodb delete-table --table-name terraform-locks --region $Region 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  DynamoDB terraform-locks borrada" -ForegroundColor Green
    }
} else {
    Write-Host "  Backend conservado" -ForegroundColor Cyan
}

# 5. Verificar
Write-Host "[5/5] Verificando..." -ForegroundColor Yellow
Write-Host "  Ejecuta ..\scripts\verify-clean.sh para confirmar" -ForegroundColor Cyan

Write-Host ""
Write-Host "=== Lab 09 limpio ===" -ForegroundColor Green
