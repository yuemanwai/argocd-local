# Installation Requirements (macOS + OrbStack)

## Purpose
This checklist is for setting up this repository on a new MacBook with OrbStack Kubernetes.
It preserves Minikube compatibility in scripts, but Minikube is optional on Mac.

## Required Software
- Homebrew
- OrbStack (App)
- Docker CLI
- Docker Compose plugin
- Docker Buildx plugin
- Helm
- Kubectl

## Install Commands
Run in Terminal:

brew install kubernetes-cli helm
brew install --cask orbstack
brew install docker docker-compose docker-buildx

## Shell Requirement
Ensure OrbStack command shims are first in PATH.
Add this line to ~/.zshrc:

export PATH="$HOME/.orbstack/bin:$PATH"

Then reload shell:

source ~/.zshrc

## Verification Commands
orbctl version
orbctl doctor
which docker
which docker-compose
which kubectl
docker context show
docker version
docker compose version
docker buildx version
kubectl config get-contexts

Expected:
- docker context is orbstack
- which docker points to ~/.orbstack/bin/docker
- orbctl doctor reports all checks passed

## Project Startup Modes
OrbStack mode (Mac primary):

./setup.sh --cluster orbstack

Minikube mode (fallback for old environment):

./setup.sh --cluster minikube

## Notes
- docker compose ps returns non-zero if there is no compose file in current folder. This is normal.
- OrbStack can run Docker and Kubernetes without creating a user Linux machine in orbctl list.
- Rancher-related containers may appear because OrbStack Kubernetes uses k3s ecosystem components.
