#!/bin/bash
set -euo pipefail

SERVICE_NAME="argocd-local.github.com.yuemanwai.argocd-local.pat"
ACCOUNT_NAME="${1:-}"

if [ -z "$ACCOUNT_NAME" ]; then
  read -r -p "GitHub username: " ACCOUNT_NAME
fi

if security find-generic-password -a "$ACCOUNT_NAME" -s "$SERVICE_NAME" >/dev/null 2>&1; then
  read -r -p "A token already exists for this account/service. Overwrite? (y/N): " OVERWRITE
  if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
    echo "Skipped. Existing Keychain item was not modified."
    exit 0
  fi
fi

read -r -s -p "GitHub PAT to store in Keychain: " GITHUB_PAT
echo ""

if [ -z "$GITHUB_PAT" ]; then
  echo "PAT cannot be empty."
  exit 1
fi

security add-generic-password \
  -a "$ACCOUNT_NAME" \
  -s "$SERVICE_NAME" \
  -w "$GITHUB_PAT" \
  -U >/dev/null

unset GITHUB_PAT

echo "Saved token in Keychain service '$SERVICE_NAME' for account '$ACCOUNT_NAME'."
