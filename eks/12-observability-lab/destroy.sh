#!/usr/bin/env bash
# destroy.sh — Teardown del lab 12 (Observability)

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${EKS_CLUSTER:-ec2-lab-cluster}"

echo "=== DESTRUYENDO LAB 12 (Observability) ==="

# 1. Control plane logs (lo más fácil de olvidar = $5-50/día)
echo "[1/6] Deshabilitando control plane logs..."
aws eks update-cluster-config --name "$CLUSTER_NAME" --region "$REGION" \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":false}]}' 2>/dev/null \
  && echo "  Logs deshabilitados" || echo "  No se pudo (¿cluster no existe?)"

# 2. Add-ons de observabilidad
echo "[2/6] Borrando add-ons..."
aws eks delete-addon --cluster-name "$CLUSTER_NAME" \
  --addon-name amazon-cloudwatch-observability --region "$REGION" 2>/dev/null
aws eks delete-addon --cluster-name "$CLUSTER_NAME" \
  --addon-name adot --region "$REGION" 2>/dev/null

# 3. AMP workspace
echo "[3/6] Borrando AMP workspace..."
AMP_ID=$(aws amp list-workspaces --region "$REGION" \
  --query "workspaces[?alias=='eks-lab-metrics'].workspaceId" --output text 2>/dev/null)
if [[ -n "$AMP_ID" && "$AMP_ID" != "None" ]]; then
  aws amp delete-workspace --workspace-id "$AMP_ID" --region "$REGION" 2>/dev/null \
    && echo "  AMP workspace borrado"
fi

# 4. Namespace de observabilidad
echo "[4/6] Borrando namespace..."
kubectl delete namespace observability 2>/dev/null

# 5. Log groups huérfanos
echo "[5/6] Borrando log groups de EKS..."
for LG in $(aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$CLUSTER_NAME" \
  --region "$REGION" --query "logGroups[].logGroupName" --output text 2>/dev/null); do
  [[ "$LG" == "None" ]] && continue
  aws logs delete-log-group --log-group-name "$LG" --region "$REGION" 2>/dev/null \
    && echo "  $LG borrado"
done

# 6. CloudWatch dashboards custom
echo "[6/6] Verificando dashboards custom..."
for DASH in $(aws cloudwatch list-dashboards --region "$REGION" \
  --query "DashboardEntries[?contains(DashboardName,'eks')].DashboardName" --output text 2>/dev/null); do
  [[ "$DASH" == "None" ]] && continue
  aws cloudwatch delete-dashboards --dashboard-names "$DASH" --region "$REGION" 2>/dev/null \
    && echo "  Dashboard $DASH borrado"
done

echo ""
echo "=== Lab 12 limpio ==="
echo "IMPORTANTE: verifica que no quedaron log groups cobrando:"
echo "  aws logs describe-log-groups --log-group-name-prefix '/aws/eks/' --region $REGION"
