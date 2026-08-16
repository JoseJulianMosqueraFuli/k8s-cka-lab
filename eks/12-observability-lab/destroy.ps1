# destroy.ps1 - Elimina todos los recursos del lab 12 (Observability)
# Uso: .\destroy.ps1

$Region = "us-east-1"
$ClusterName = "ec2-lab-cluster"

Write-Host "=== DESTRUYENDO LAB 12 (Observability) ===" -ForegroundColor Red
Write-Host ""

# 1. Control plane logs (lo mas facil de olvidar = $5-50/dia)
Write-Host "[1/6] Deshabilitando control plane logs..." -ForegroundColor Yellow
$loggingConfig = '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":false}]}'
aws eks update-cluster-config --name $ClusterName --region $Region --logging $loggingConfig 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Logs deshabilitados" -ForegroundColor Green
} else {
    Write-Host "  No se pudo (cluster no existe?)" -ForegroundColor DarkYellow
}

# 2. Add-ons de observabilidad
Write-Host "[2/6] Borrando add-ons..." -ForegroundColor Yellow
aws eks delete-addon --cluster-name $ClusterName `
    --addon-name amazon-cloudwatch-observability --region $Region 2>$null | Out-Null
aws eks delete-addon --cluster-name $ClusterName `
    --addon-name adot --region $Region 2>$null | Out-Null

# 3. AMP workspace
Write-Host "[3/6] Borrando AMP workspace..." -ForegroundColor Yellow
$ampId = aws amp list-workspaces --region $Region `
    --query "workspaces[?alias=='eks-lab-metrics'].workspaceId" --output text 2>$null
if ($ampId -and $ampId -ne "None") {
    aws amp delete-workspace --workspace-id $ampId --region $Region 2>$null | Out-Null
    Write-Host "  AMP workspace borrado" -ForegroundColor Green
} else {
    Write-Host "  AMP workspace no encontrado" -ForegroundColor DarkYellow
}

# 4. Namespace de observabilidad
Write-Host "[4/6] Borrando namespace..." -ForegroundColor Yellow
kubectl delete namespace observability 2>$null

# 5. Log groups huerfanos
Write-Host "[5/6] Borrando log groups de EKS..." -ForegroundColor Yellow
$logGroups = aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$ClusterName" `
    --region $Region --query "logGroups[].logGroupName" --output text 2>$null
if ($logGroups -and $logGroups -ne "None") {
    foreach ($lg in $logGroups.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
        aws logs delete-log-group --log-group-name $lg --region $Region 2>$null
        Write-Host "  $lg borrado" -ForegroundColor Green
    }
} else {
    Write-Host "  No se encontraron log groups" -ForegroundColor DarkYellow
}

# 6. CloudWatch dashboards custom
Write-Host "[6/6] Verificando dashboards custom..." -ForegroundColor Yellow
$dashboards = aws cloudwatch list-dashboards --region $Region `
    --query "DashboardEntries[?contains(DashboardName,'eks')].DashboardName" --output text 2>$null
if ($dashboards -and $dashboards -ne "None") {
    foreach ($dash in $dashboards.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
        aws cloudwatch delete-dashboards --dashboard-names $dash --region $Region 2>$null
        Write-Host "  Dashboard $dash borrado" -ForegroundColor Green
    }
} else {
    Write-Host "  No se encontraron dashboards" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=== Lab 12 limpio ===" -ForegroundColor Green
Write-Host "IMPORTANTE: verifica que no quedaron log groups cobrando:" -ForegroundColor Cyan
Write-Host "  aws logs describe-log-groups --log-group-name-prefix '/aws/eks/' --region $Region" -ForegroundColor Cyan
