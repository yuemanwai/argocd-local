#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/yuemanwai/argocd-local.git"
SECRET_NAME="repo-argocd-local"
NAMESPACE="argocd"

echo "Apply ArgoCD repository credentials securely"
read -r -p "GitHub username: " GITHUB_USERNAME
read -r -s -p "GitHub PAT (repo read access): " GITHUB_PAT
echo ""

if [ -z "${GITHUB_USERNAME}" ] || [ -z "${GITHUB_PAT}" ]; then
  echo "Username and PAT are required."
  exit 1
fi

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$GITHUB_USERNAME" \
  --from-literal=password="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$NAMESPACE" label secret "$SECRET_NAME" argocd.argoproj.io/secret-type=repository --overwrite >/dev/null

unset GITHUB_PAT
echo "Repository secret applied to namespace '$NAMESPACE' as '$SECRET_NAME'."
