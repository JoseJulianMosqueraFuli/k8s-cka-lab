#!/usr/bin/env bash
# destroy.sh — Teardown del lab 07 (Networking + Isolation)

set -uo pipefail

echo "=== DESTRUYENDO LAB 07 (Networking) ==="

# Los namespaces contienen todo: deploys, services, network policies, quotas, RBAC
echo "[1/2] Borrando namespaces (borra todo lo que contienen)..."
for NS in frontend backend database team-alpha; do
  kubectl delete namespace "$NS" 2>/dev/null && echo "  $NS borrado"
done

# Revertir prefix delegation si se habilitó
echo "[2/2] Verificando prefix delegation..."
CURRENT=$(kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null | grep -c "ENABLE_PREFIX_DELEGATION.*true" || true)
if (( CURRENT > 0 )); then
  read -rp "¿Revertir prefix delegation? [s/N]: " ans
  if [[ "$ans" =~ ^[sS]$ ]]; then
    kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=false WARM_PREFIX_TARGET-
    echo "  Prefix delegation deshabilitado"
  fi
fi

echo ""
echo "=== Lab 07 limpio ==="
