# destroy.ps1 - Elimina todos los recursos del lab 04 (Ingress + ECR)
# Uso: .\destroy.ps1
# Este lab se monta sobre el cluster del lab 02 o 03; NO borra el cluster.

$Region = "us-east-1"
$RepoName = "k8s-lab/identity-api"
$Namespace = "apps"

Write-Host "=== DESTRUYENDO LAB 04 (Ingress + ECR) ===" -ForegroundColor Red
Write-Host ""

# 1. Gateway API (Paso 8), si se probo.
# Las rutas van antes del Gateway: el Gateway es el dueno del ALB, y borrarlo
# con rutas colgando puede dejar el balanceador atras.
Write-Host "[1/6] Borrando recursos de Gateway API..." -ForegroundColor Yellow
kubectl delete httproute --all -n $Namespace 2>$null
kubectl delete grpcroute --all -n $Namespace 2>$null
kubectl delete tcproute --all -n $Namespace 2>$null
kubectl delete gateway --all -n $Namespace 2>$null
kubectl delete gatewayclass alb 2>$null

# 2. Recursos de Kubernetes
Write-Host "[2/6] Borrando Ingress, Service, Deployment y Pod..." -ForegroundColor Yellow
kubectl delete ingress identity-api -n $Namespace 2>$null
kubectl delete svc identity-api -n $Namespace 2>$null
kubectl delete deploy identity-api -n $Namespace 2>$null
kubectl delete pod identity-host -n $Namespace 2>$null

# Esperar a que los balanceadores se eliminen
Write-Host "  Esperando 60s para que los ALB se eliminen..." -ForegroundColor DarkYellow
Start-Sleep -Seconds 60

# Verificar que no quedo ningun ALB del lab cobrando
$leftoverLb = aws elbv2 describe-load-balancers --region $Region `
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-$Namespace')].LoadBalancerName" `
    --output text 2>$null
if ($leftoverLb -and $leftoverLb -ne "None") {
    Write-Host "  ADVERTENCIA: quedan balanceadores del lab: $leftoverLb" -ForegroundColor Red
    Write-Host "  Revisa si el Ingress/Gateway se borro correctamente." -ForegroundColor Red
}

# 3. cert-manager (Paso 5, Opcion C), si se instalo
Write-Host "[3/6] Desinstalando cert-manager..." -ForegroundColor Yellow
kubectl delete certificate --all -A 2>$null
kubectl delete clusterissuer --all 2>$null
kubectl delete issuer --all -A 2>$null
helm uninstall cert-manager -n cert-manager 2>$null
kubectl delete namespace cert-manager 2>$null

# 4. ECR (pregunta antes de borrar - se usa en labs 05-09)
Write-Host "[4/6] Repositorio ECR..." -ForegroundColor Yellow
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

# 5. Certificados ACM
Write-Host "[5/6] Buscando certificados ACM del lab..." -ForegroundColor Yellow
$certs = aws acm list-certificates --region $Region --query "CertificateSummaryList[?contains(DomainName,'lab')].CertificateArn" --output text 2>$null
if ($certs -and $certs -ne "None") {
    foreach ($arn in $certs.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)) {
        Write-Host "  Borrando certificado: $arn" -ForegroundColor DarkYellow
        aws acm delete-certificate --certificate-arn $arn --region $Region 2>$null
    }
} else {
    Write-Host "  No se encontraron certificados" -ForegroundColor DarkYellow
}

# 6. Namespace (solo si esta vacio)
Write-Host "[6/6] Verificando namespace..." -ForegroundColor Yellow
$remaining = kubectl get all -n $Namespace --no-headers 2>$null | Measure-Object -Line | Select-Object -ExpandProperty Lines
if ($remaining -eq 0) {
    kubectl delete namespace $Namespace 2>$null | Out-Null
    Write-Host "  Namespace $Namespace borrado" -ForegroundColor Green
} else {
    Write-Host "  Namespace $Namespace tiene $remaining recursos; no se borra" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=== Lab 04 limpio. El cluster base sigue activo ===" -ForegroundColor Green
Write-Host "Nota: las CRDs de Gateway API y cert-manager siguen en el cluster." -ForegroundColor DarkGray
Write-Host "Helm no las borra a proposito. Si el cluster sobrevive y quieres limpiarlas:" -ForegroundColor DarkGray
Write-Host "  kubectl delete crd -l app.kubernetes.io/name=cert-manager" -ForegroundColor DarkGray
