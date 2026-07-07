#!/bin/bash
set -e

REGION="us-east-1"
CLUSTER_NAME="project-bedrock-cluster"
DB_PASSWORD="${1:-YourSecurePassword123!}"

echo "================================================================"
echo " Project Bedrock - Complete Teardown"
echo "================================================================"

# 1. Delete ArgoCD
echo "🗑️  Deleting ArgoCD..."
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null || true
kubectl delete namespace argocd --ignore-not-found=true 2>/dev/null || true

# 2. Delete application
echo "🗑️  Deleting application..."
kubectl delete namespace retail-app --ignore-not-found=true 2>/dev/null || true
kubectl delete namespace amazon-cloudwatch --ignore-not-found=true 2>/dev/null || true

# 3. Delete LB controller
kubectl delete deployment aws-load-balancer-controller -n kube-system --ignore-not-found=true 2>/dev/null || true
kubectl delete serviceaccount aws-load-balancer-controller -n kube-system --ignore-not-found=true 2>/dev/null || true
kubectl delete secret aws-load-balancer-tls -n kube-system --ignore-not-found=true 2>/dev/null || true

# 4. Delete IAM keys
for key in $(aws iam list-access-keys --user-name bedrock-dev-view --query 'AccessKeyMetadata[*].AccessKeyId' --output text --region "$REGION" 2>/dev/null); do
  aws iam delete-access-key --user-name bedrock-dev-view --access-key-id "$key" --region "$REGION" 2>/dev/null || true
done

# 5. Delete login profile
aws iam delete-login-profile --user-name bedrock-dev-view --region "$REGION" 2>/dev/null || true

# 6. Empty S3
BUCKET=$(aws s3 ls --region "$REGION" 2>/dev/null | grep bedrock-assets | awk '{print $3}')
[ -n "$BUCKET" ] && aws s3 rm "s3://$BUCKET" --recursive --region "$REGION" 2>/dev/null || true

# 7. Delete Secrets Manager
aws secretsmanager delete-secret --secret-id project-bedrock-db-credentials --force-delete-without-recovery --region "$REGION" 2>/dev/null || true

# 8. Force delete VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=project-bedrock-vpc" --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  for alb in $(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[*].LoadBalancerArn' --output text 2>/dev/null); do
    aws elbv2 delete-load-balancer --load-balancer-arn "$alb" --region "$REGION" 2>/dev/null || true
  done
  for ngw in $(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null); do
    aws ec2 delete-nat-gateway --nat-gateway-id "$ngw" --region "$REGION" 2>/dev/null || true
  done
  sleep 120
  for eip in $(aws ec2 describe-addresses --region "$REGION" --query 'Addresses[*].AllocationId' --output text 2>/dev/null); do
    aws ec2 release-address --allocation-id "$eip" --region "$REGION" 2>/dev/null || true
  done
  for eni in $(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null || true
  done
  for sg in $(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || true
  done
  for subnet in $(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
    aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" 2>/dev/null || true
  done
  IGW_ID=$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")
  if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" 2>/dev/null || true
  fi
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || true
fi

# 9. Terraform destroy
echo "🗑️  Running Terraform destroy..."
cd "$(dirname "$0")/../terraform"
terraform init 2>/dev/null || true
terraform destroy -auto-approve -var="db_password=$DB_PASSWORD" 2>/dev/null || true

echo ""
echo "✅ Teardown complete!"