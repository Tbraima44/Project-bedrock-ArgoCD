#!/bin/bash
set -e

echo "================================================================"
echo " Project Bedrock - Infrastructure Setup"
echo "================================================================"

CLUSTER_NAME="project-bedrock-cluster"
REGION="us-east-1"
NAMESPACE="retail-app"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")

# ------------------------------------------------------------------
# 1. Prerequisites
# ------------------------------------------------------------------
echo "📋 Checking prerequisites..."
command -v kubectl &> /dev/null || { echo "❌ kubectl not found."; exit 1; }
command -v openssl &> /dev/null || { echo "❌ openssl not found."; exit 1; }

# ------------------------------------------------------------------
# 2. Connect to EKS
# ------------------------------------------------------------------
echo "🔗 Updating kubeconfig..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
echo ""
echo "📊 Cluster nodes:"
kubectl get nodes
echo ""

# ------------------------------------------------------------------
# 3. Get infrastructure values
# ------------------------------------------------------------------
echo "📊 Fetching infrastructure endpoints..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=project-bedrock-vpc" --query 'Vpcs[0].VpcId' --output text --region "$REGION")
echo "  VPC ID: $VPC_ID"

# ------------------------------------------------------------------
# 4. Setup AWS Load Balancer Controller
# ------------------------------------------------------------------
echo "🌐 Setting up AWS Load Balancer Controller..."

# Check if already running
if kubectl get deployment aws-load-balancer-controller -n kube-system &>/dev/null; then
  echo "  ✅ LB Controller already running."
else
  echo "  Installing LB Controller..."

  # Apply CRDs
  echo "    Applying CRDs..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/config/crd/bases/elbv2.k8s.aws_targetgroupbindings.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/config/crd/bases/elbv2.k8s.aws_ingressclassparams.yaml

  # Generate TLS certificate
  echo "    Generating TLS certificate..."
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -nodes -subj "/CN=aws-load-balancer-controller"
  kubectl create secret tls aws-load-balancer-tls --cert=/tmp/tls.crt --key=/tmp/tls.key -n kube-system --dry-run=client -o yaml | kubectl apply -f -
  rm /tmp/tls.key /tmp/tls.crt

  # Create ServiceAccount with IRSA
  echo "    Creating ServiceAccount with IRSA..."
  kubectl delete serviceaccount aws-load-balancer-controller -n kube-system --ignore-not-found=true
  kubectl create serviceaccount aws-load-balancer-controller -n kube-system --dry-run=client -o yaml | \
    kubectl annotate --local -f - "eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/project-bedrock-lb-controller-role" --dry-run=client -o yaml | \
    kubectl apply -f -

  # Apply RBAC from Git (managed by ArgoCD)
  echo "    Applying RBAC from Git..."
  kubectl apply -f kubernetes/infrastructure/lb-controller/clusterrole.yaml
  kubectl apply -f kubernetes/infrastructure/lb-controller/clusterrolebinding.yaml

  # Deploy controller from Git with dynamic VPC ID
  echo "    Deploying controller..."
  sed "s/--aws-vpc-id=.*/--aws-vpc-id=$VPC_ID/" kubernetes/infrastructure/lb-controller/deployment.yaml | kubectl apply -f -

  # Wait for it to be ready
  kubectl wait --for=condition=available --timeout=120s deployment/aws-load-balancer-controller -n kube-system
  echo "  ✅ LB Controller is running."
fi

# ------------------------------------------------------------------
# 5. Developer access
# ------------------------------------------------------------------
echo "🔐 Configuring developer access..."

# Apply developer RBAC from Git (managed by ArgoCD)
kubectl apply -f kubernetes/rbac/dev-view-clusterrolebinding.yaml

# Add developer to aws-auth ConfigMap
kubectl patch configmap aws-auth -n kube-system --type merge -p '{"data":{"mapUsers":"- userarn: arn:aws:iam::'$ACCOUNT_ID':user/bedrock-dev-view\n  username: bedrock-dev-view\n  groups:\n  - view"}}' 2>/dev/null || true
echo "  ✅ Developer access configured."

# ------------------------------------------------------------------
# 6. ArgoCD status check
# ------------------------------------------------------------------
echo "📦 Checking ArgoCD status..."
if kubectl get namespace argocd &>/dev/null; then
  echo "  ✅ ArgoCD is installed (managed by Terraform)."
  
  # Trigger sync of all apps
  echo "  🔄 Triggering ArgoCD sync..."
  kubectl apply -f argocd/infrastructure-app.yaml 2>/dev/null || true
  kubectl apply -f argocd/retail-store-app.yaml 2>/dev/null || true
  echo "  ✅ ArgoCD applications synced."
else
  echo "  ⚠️  ArgoCD not found. It should be installed by Terraform."
  echo "  Run: cd terraform && terraform apply"
fi

# ------------------------------------------------------------------
# 7. Enable CloudWatch Observability
# ------------------------------------------------------------------
echo "📊 Enabling CloudWatch Observability..."
aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name amazon-cloudwatch-observability \
  --region "$REGION" 2>/dev/null && echo "  ✅ CloudWatch add-on created." || echo "  ℹ️  Add-on may already exist."

# ------------------------------------------------------------------
# 8. Update Lambda function
# ------------------------------------------------------------------
echo "⚡ Updating Lambda function..."
cd lambda/bedrock-asset-processor
zip -r ../bedrock-asset-processor.zip index.py
cd ../..
aws lambda update-function-code \
  --function-name bedrock-asset-processor \
  --zip-file fileb://lambda/bedrock-asset-processor.zip \
  --region "$REGION" \
  --no-cli-pager
echo "  ✅ Lambda updated."

# ------------------------------------------------------------------
# 9. Wait for ALB (if Ingress exists)
# ------------------------------------------------------------------
echo "🚪 Checking Ingress..."
if kubectl get ingress retail-store-ingress -n "$NAMESPACE" &>/dev/null; then
  echo "⏳ Waiting for ALB..."
  sleep 10
  for i in $(seq 1 30); do
    ALB_URL=$(kubectl get ingress retail-store-ingress -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [ -n "$ALB_URL" ] && break
    echo "  Waiting... $i/30"
    sleep 10
  done
else
  echo "  ℹ️  Ingress not yet deployed. ArgoCD will deploy it."
  ALB_URL=""
fi

# ------------------------------------------------------------------
# 10. Summary
# ------------------------------------------------------------------
echo ""
echo "================================================================"
echo "🎉 Setup Complete!"
echo "================================================================"

if [ -n "$ALB_URL" ]; then
  echo "✅ Application URL: http://$ALB_URL"
else
  echo "⏳ Waiting for ArgoCD to deploy the application."
  echo "   Check status: kubectl get applications -n argocd"
fi

echo ""
echo "📊 Current Pods:"
kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "  (namespace not yet created by ArgoCD)"

echo ""
echo "🔍 ArgoCD Access:"
echo "   kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "   Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

echo ""
echo "📊 CloudWatch Logs:"
echo "   aws logs tail /aws/containerinsights/project-bedrock-cluster/application --region $REGION"