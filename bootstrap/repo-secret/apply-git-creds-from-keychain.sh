#!/bin/bash
set -euo pipefail

SERVICE_NAME="argocd-local.github.com.yuemanwai.argocd-local.pat"
REPO_URL="https://github.com/yuemanwai/argocd-local.git"
SECRET_NAME="repo-argocd-local"
NAMESPACE="argocd"
ACCOUNT_NAME="${1:-}"

if [ -z "$ACCOUNT_NAME" ]; then
  read -r -p "GitHub username (Keychain account): " ACCOUNT_NAME
fi

# This reads from macOS Keychain. Depending your macOS settings,
# system may ask for password or Touch ID authorization.
GITHUB_PAT="$(security find-generic-password -a "$ACCOUNT_NAME" -s "$SERVICE_NAME" -w)"

if [ -z "$GITHUB_PAT" ]; then
  echo "No PAT found in Keychain for service '$SERVICE_NAME' account '$ACCOUNT_NAME'."
  echo "Run ./bootstrap/repo-secret/keychain-save-token.sh first."
  exit 1
fi

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$ACCOUNT_NAME" \
  --from-literal=password="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$NAMESPACE" label secret "$SECRET_NAME" argocd.argoproj.io/secret-type=repository --overwrite >/dev/null

unset GITHUB_PAT

echo "Applied repository secret '$SECRET_NAME' in namespace '$NAMESPACE' using Keychain token."
