#!/usr/bin/env bash
set -euo pipefail

REGION=eu-central-1
REPO=rust-devops-app

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Use the tag given as argument, or the newest tagged image in ECR
export IMAGE_TAG=${1:-$(aws ecr describe-images --repository-name "$REPO" --region "$REGION" \
  --query 'sort_by(imageDetails[?imageTags], &imagePushedAt)[-1].imageTags[0]' --output text)}

echo "Deploying $REPO:$IMAGE_TAG"

envsubst '$ACCOUNT_ID $IMAGE_TAG' < k8s/app.yaml | kubectl apply -f -
kubectl rollout status deployment rust-app -n rust-app