#!/bin/bash

set -e  # Exit on any error

echo "Initializing Terraform..."
terraform init

echo "Applying VPC module..."
terraform apply -target=module.vpc --auto-approve

echo "Applying EKS module..."
terraform apply -target=module.eks --auto-approve

echo "Creating Log Ingestion Pipeline..."
terraform apply -target=module.ingestion_pipeline --auto-approve

echo "Applying EKS Blueprints Addons..."
terraform apply -target=module.eks_blueprints_addons --auto-approve

echo "Applying Karpenter resources"
terraform apply -target=module.karpenter -target=helm_release.karpenter --auto-approve

echo "Applying remaining Terraform configurations..."
terraform apply --auto-approve

echo "Installation complete!"