#!/usr/bin/env bash
# destroy.sh — Teardown del lab 08 (Troubleshooting)
# Este lab usa un cluster desechable de eksctl — se borra completo.

set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="eks-troubleshoot-lab"

echo "=== DESTRUYENDO LAB 08 (Troubleshooting) ==="
echo "Borrando cluster desechable: $CLUSTER_NAME"

if ! command -v eksctl >/dev/null 2>&1; then
  echo "ERROR: eksctl no está instalado. Instálalo o borra manualmente:"
  echo "  aws eks delete-cluster --name $CLUSTER_NAME --region $REGION"
  exit 1
fi

eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait

echo ""
echo "=== Lab 08 limpio ==="
echo "Verifica con: ../scripts/verify-clean.sh"
