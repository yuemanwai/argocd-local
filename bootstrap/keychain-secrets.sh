#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<EOF
Usage:
  ./bootstrap/keychain-secrets.sh save [github_account]      # save repo PAT + Gemini key
  ./bootstrap/keychain-secrets.sh apply [github_account]     # apply repo secret + Gemini override
  ./bootstrap/keychain-secrets.sh save-repo [github_account]
  ./bootstrap/keychain-secrets.sh save-pat [github_account]
  ./bootstrap/keychain-secrets.sh apply-repo [github_account]
  ./bootstrap/keychain-secrets.sh apply-repo-secret [github_account]
  ./bootstrap/keychain-secrets.sh save-gemini
  ./bootstrap/keychain-secrets.sh apply-gemini

Examples:
  ./bootstrap/keychain-secrets.sh save ymw
  ./bootstrap/keychain-secrets.sh apply ymw
  ./bootstrap/keychain-secrets.sh save-pat ymw
  ./bootstrap/keychain-secrets.sh apply-repo-secret ymw
  ./bootstrap/keychain-secrets.sh save-gemini
  ./bootstrap/keychain-secrets.sh apply-gemini
EOF
}

if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

ACTION="$1"
GITHUB_ACCOUNT="${2:-}"
GEMINI_SERVICE_NAME="argocd-local.github.com.yuemanwai.argocd-local.gemini-api-key"
GEMINI_ACCOUNT="${GEMINI_KEYCHAIN_ACCOUNT:-gemini-api-key}"
APP_NAME="${APP_NAME:-my-app}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAMESPACE="${APP_NAMESPACE:-default}"
APP_DEPLOYMENT="${APP_DEPLOYMENT:-my-app-jp}"

SAVE_REPO_SCRIPT="$ROOT_DIR/bootstrap/repo-secret/save-github-pat-to-keychain.sh"
APPLY_REPO_SCRIPT="$ROOT_DIR/bootstrap/repo-secret/apply-github-repo-secret-from-keychain.sh"

restart_app_deployment() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not found; skip rollout restart."
    return 0
  fi

  if ! kubectl -n "$APP_NAMESPACE" get deployment "$APP_DEPLOYMENT" >/dev/null 2>&1; then
    echo "Deployment '$APP_DEPLOYMENT' not found in namespace '$APP_NAMESPACE'; skip rollout restart."
    return 0
  fi

  echo "Restart deployment '$APP_DEPLOYMENT' in namespace '$APP_NAMESPACE' to reload env vars..."
  kubectl -n "$APP_NAMESPACE" rollout restart deployment "$APP_DEPLOYMENT" >/dev/null
  kubectl -n "$APP_NAMESPACE" rollout status deployment "$APP_DEPLOYMENT" --timeout=180s >/dev/null
}

save_gemini_to_keychain() {
  local account_name="$1"

  if security find-generic-password -a "$account_name" -s "$GEMINI_SERVICE_NAME" >/dev/null 2>&1; then
    read -r -p "A Gemini API key already exists for this account/service. Overwrite? (y/N): " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
      echo "Skipped. Existing Keychain item was not modified."
      return 0
    fi
  fi

  read -r -s -p "GEMINI_API_KEY to store in Keychain: " gemini_api_key
  echo ""

  if [ -z "$gemini_api_key" ]; then
    echo "GEMINI_API_KEY cannot be empty."
    exit 1
  fi

  security add-generic-password \
    -a "$account_name" \
    -s "$GEMINI_SERVICE_NAME" \
    -w "$gemini_api_key" \
    -U >/dev/null

  unset gemini_api_key
  echo "Saved Gemini API key in Keychain service '$GEMINI_SERVICE_NAME' for account '$account_name'."
}

apply_gemini_runtime_override() {
  local account_name="$1"
  local gemini_api_key=""

  gemini_api_key="$(security find-generic-password -a "$account_name" -s "$GEMINI_SERVICE_NAME" -w)"
  if [ -z "$gemini_api_key" ]; then
    echo "No Gemini API key found in Keychain for service '$GEMINI_SERVICE_NAME' account '$account_name'."
    echo "Run ./bootstrap/keychain-secrets.sh save-gemini first."
    exit 1
  fi

  if ! command -v argocd >/dev/null 2>&1; then
    if ! command -v kubectl >/dev/null 2>&1; then
      echo "Neither argocd CLI nor kubectl is available."
      echo "Install one of them, then run this script again."
      exit 1
    fi

    if ! kubectl -n "$ARGOCD_NAMESPACE" get application "$APP_NAME" >/dev/null 2>&1; then
      echo "Application '$APP_NAME' not found in namespace '$ARGOCD_NAMESPACE'."
      echo "Set APP_NAME/ARGOCD_NAMESPACE env vars and retry."
      exit 1
    fi

    kubectl -n "$ARGOCD_NAMESPACE" patch application "$APP_NAME" --type merge -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"secret.GEMINI_API_KEY\",\"value\":\"$gemini_api_key\"}]}}}}" >/dev/null
    kubectl -n "$ARGOCD_NAMESPACE" annotate application "$APP_NAME" argocd.argoproj.io/refresh=hard --overwrite >/dev/null

    restart_app_deployment

    unset gemini_api_key
    echo "Applied runtime override via kubectl patch on app '$APP_NAME' and triggered refresh."
    return 0
  fi

  argocd app set "$APP_NAME" -p "secret.GEMINI_API_KEY=$gemini_api_key" >/dev/null
  argocd app sync "$APP_NAME" >/dev/null

  restart_app_deployment

  unset gemini_api_key
  echo "Applied runtime override secret.GEMINI_API_KEY to app '$APP_NAME' and triggered sync."
}

case "$ACTION" in
  save)
    echo "[1/2] Save GitHub PAT to Keychain"
    bash "$SAVE_REPO_SCRIPT" "$GITHUB_ACCOUNT"

    echo "[2/2] Save Gemini API key to Keychain"
    save_gemini_to_keychain "$GEMINI_ACCOUNT"
    ;;
  apply)
    echo "[1/2] Apply ArgoCD repository secret from Keychain"
    bash "$APPLY_REPO_SCRIPT" "$GITHUB_ACCOUNT"

    echo "[2/2] Apply Gemini runtime override from Keychain"
    apply_gemini_runtime_override "$GEMINI_ACCOUNT"
    ;;
  save-repo|save-pat)
    echo "Save GitHub PAT to Keychain"
    bash "$SAVE_REPO_SCRIPT" "$GITHUB_ACCOUNT"
    ;;
  apply-repo|apply-repo-secret)
    echo "Apply ArgoCD repository secret from Keychain"
    bash "$APPLY_REPO_SCRIPT" "$GITHUB_ACCOUNT"
    ;;
  save-gemini)
    echo "Save Gemini API key to Keychain"
    save_gemini_to_keychain "$GEMINI_ACCOUNT"
    ;;
  apply-gemini)
    echo "Apply Gemini runtime override from Keychain"
    apply_gemini_runtime_override "$GEMINI_ACCOUNT"
    ;;
  *)
    usage
    exit 1
    ;;
esac

echo "Done: keychain secrets '$ACTION' completed."