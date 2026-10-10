# Secret Management

This document describes how secrets are handled for the local ArgoCD lab and for production-style deployments.

## Repository Access

A public GitHub repository does not need an ArgoCD repository Secret. Leave the template at `bootstrap/repo-secret/github-repo-secret.template.yaml` unchanged; `setup.sh` skips placeholder credentials.

For a private repository on macOS, store the GitHub PAT in Keychain and apply it to the ArgoCD namespace:

```bash
./bootstrap/keychain-secrets.sh save-repo <github_username>
./setup.sh --cluster orbstack
./bootstrap/keychain-secrets.sh apply-repo <github_username>
```

`save-repo` stores the PAT in macOS Keychain only. `apply-repo` reads it from Keychain and creates or updates the Kubernetes Secret `repo-argocd-local`. The PAT is not written to this repository.

On systems without macOS Keychain, use the prompt-based alternative after ArgoCD is installed:

```bash
./bootstrap/repo-secret/apply-github-repo-secret-from-prompts.sh
```

## Application Secrets

The Japanese Academy chart creates the application Secret from `gitops/apps/jp/values.yaml`. The `bootstrap/app-secret/` directory is not used.

For the local Gemini integration:

```bash
./bootstrap/keychain-secrets.sh save-gemini
./bootstrap/keychain-secrets.sh apply-gemini
```

`save-gemini` stores the key in macOS Keychain. `apply-gemini` temporarily updates the `my-app` ArgoCD Application and triggers a sync; the key is not committed to Git.

## Production Guidance

The local chart contains placeholder values for development. Do not use the placeholder `SECRET_KEY` or commit real API keys to Git in cloud or production environments. Production secrets should come from the configured external secret mechanism, such as AWS Secrets Manager with IAM Roles for Service Accounts (IRSA).

For the complete command list:

```bash
./bootstrap/keychain-secrets.sh --help
```
