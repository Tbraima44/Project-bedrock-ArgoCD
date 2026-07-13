#!/bin/bash
set -e

echo "================================================================"
echo " Project Bedrock - Complete Infrastructure + App Deployment"
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
command -v jq &> /dev/null || { echo "❌ jq not found."; exit 1; }

# ------------------------------------------------------------------
# 2. Connect to EKS
# ------------------------------------------------------------------
echo "🔗 Updating kubeconfig..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl get nodes --no-headers | wc -l | xargs echo "  Nodes:"
echo ""

# ------------------------------------------------------------------
# 3. Get infrastructure values
# ------------------------------------------------------------------
echo "📊 Fetching infrastructure values..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=project-bedrock-vpc" --query 'Vpcs[0].VpcId' --output text --region "$REGION")
MYSQL_HOST=$(aws rds describe-db-instances --db-instance-identifier project-bedrock-mysql --query 'DBInstances[0].Endpoint.Address' --output text --region "$REGION")
echo "  VPC ID: $VPC_ID"
echo "  MySQL Host: $MYSQL_HOST"

# ------------------------------------------------------------------
# 4. Get database credentials from Secrets Manager
# ------------------------------------------------------------------
echo "🔑 Retrieving database credentials..."
DB_SECRET=$(aws secretsmanager get-secret-value --secret-id project-bedrock-db-credentials --query SecretString --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$DB_SECRET" ]; then
  MYSQL_USER=$(echo "$DB_SECRET" | jq -r '.mysql_username')
  MYSQL_PASS=$(echo "$DB_SECRET" | jq -r '.mysql_password')
  echo "  ✅ Credentials retrieved."
else
  echo "  ⚠️  Could not retrieve credentials."
  MYSQL_USER="admin"
  MYSQL_PASS="password"
fi

# ------------------------------------------------------------------
# 5. Generate Helm values.yaml from template
# ------------------------------------------------------------------
echo "📝 Generating Helm values..."
sed -e "s|MYSQL_HOST_PLACEHOLDER|$MYSQL_HOST|g" \
    -e "s|MYSQL_USER_PLACEHOLDER|$MYSQL_USER|g" \
    -e "s|MYSQL_PASS_PLACEHOLDER|$MYSQL_PASS|g" \
    kubernetes/helm/values.yaml.tmpl > kubernetes/helm/values.yaml
echo "  ✅ Helm values generated."

# ------------------------------------------------------------------
# 6. Create namespace
# ------------------------------------------------------------------
echo "📁 Creating namespace '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ------------------------------------------------------------------
# 7. Create database credentials secret
# ------------------------------------------------------------------
echo "🔐 Creating database credentials secret..."
kubectl delete secret db-credentials -n "$NAMESPACE" --ignore-not-found=true
kubectl create secret generic db-credentials -n "$NAMESPACE" \
  --from-literal=mysql-password="$MYSQL_PASS" \
  --from-literal=mysql-username="$MYSQL_USER"
echo "  ✅ Database secret created."

# ------------------------------------------------------------------
# 8. Apply IngressClass from Git
# ------------------------------------------------------------------
echo "🌐 Applying IngressClass..."
kubectl apply -f kubernetes/retail-store/ingress/ingressclass.yaml

# ------------------------------------------------------------------
# 9. Install AWS Load Balancer Controller
# ------------------------------------------------------------------
echo "🌐 Installing AWS Load Balancer Controller..."

# 9a. Apply CRDs
echo "  Applying CRDs..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/config/crd/bases/elbv2.k8s.aws_targetgroupbindings.yaml --validate=false
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/config/crd/bases/elbv2.k8s.aws_ingressclassparams.yaml --validate=false

# 9b. Apply RBAC from Git (ArgoCD managed)
echo "  Applying RBAC..."
kubectl apply -f kubernetes/infrastructure/lb-controller/clusterrole.yaml
kubectl apply -f kubernetes/infrastructure/lb-controller/clusterrolebinding.yaml

# 9c. Generate TLS certificate
echo "  Generating TLS certificate..."
openssl req -x509 -newkey rsa:2048 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -nodes -subj "/CN=aws-load-balancer-controller" 2>/dev/null
kubectl delete secret aws-load-balancer-tls -n kube-system --ignore-not-found=true
kubectl create secret tls aws-load-balancer-tls --cert=/tmp/tls.crt --key=/tmp/tls.key -n kube-system --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/tls.key /tmp/tls.crt

# 9d. Create ServiceAccount with IRSA
echo "  Creating ServiceAccount..."
kubectl delete serviceaccount aws-load-balancer-controller -n kube-system --ignore-not-found=true
kubectl create serviceaccount aws-load-balancer-controller -n kube-system --dry-run=client -o yaml | \
  kubectl annotate --local -f - "eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/project-bedrock-lb-controller-role" --dry-run=client -o yaml | \
  kubectl apply -f -

# 9e. Clean old replicasets
kubectl delete replicaset -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --ignore-not-found=true 2>/dev/null || true

# 9f. Deploy controller with dynamic VPC ID
echo "  Deploying controller..."
kubectl delete deployment aws-load-balancer-controller -n kube-system --ignore-not-found=true
sed "s/--aws-vpc-id=.*/--aws-vpc-id=$VPC_ID/" kubernetes/infrastructure/lb-controller/deployment.yaml | kubectl apply -f -

# 9g. Wait for controller
echo "  Waiting for LB Controller..."
for i in $(seq 1 20); do
  if kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -q Running; then
    echo "  ✅ LB Controller is running."
    break
  fi
  if [ $i -eq 20 ]; then
    echo "  ❌ LB Controller failed. Debug:"
    kubectl describe pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller | tail -20
    exit 1
  fi
  sleep 5
done

# ------------------------------------------------------------------
# 10. Security group: Allow traffic within VPC
# ------------------------------------------------------------------
echo "🔓 Configuring security group..."
NODE_SG=$(aws ec2 describe-instances --filters "Name=tag:aws:eks:cluster-name,Values=$CLUSTER_NAME" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$NODE_SG" ] && [ "$NODE_SG" != "None" ]; then
  aws ec2 authorize-security-group-ingress --group-id "$NODE_SG" --protocol tcp --port 8080 --cidr 10.0.0.0/16 --region "$REGION" 2>/dev/null || true
  echo "  ✅ Security group configured."
fi

# ------------------------------------------------------------------
# 11. Developer access
# ------------------------------------------------------------------
echo "🔐 Configuring developer access..."
kubectl apply -f kubernetes/rbac/dev-view-clusterrolebinding.yaml
kubectl patch configmap aws-auth -n kube-system --type merge -p '{"data":{"mapUsers":"- userarn: arn:aws:iam::'$ACCOUNT_ID':user/bedrock-dev-view\n  username: bedrock-dev-view\n  groups:\n  - view"}}' 2>/dev/null || true
echo "  ✅ Developer access configured."

# ------------------------------------------------------------------
# 12. Enable CloudWatch
# ------------------------------------------------------------------
echo "📊 Enabling CloudWatch..."
aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name amazon-cloudwatch-observability --region "$REGION" 2>/dev/null && echo "  ✅ Created." || echo "  ℹ️  Already exists."

# ------------------------------------------------------------------
# 13. Update Lambda
# ------------------------------------------------------------------
echo "⚡ Updating Lambda..."
cd lambda/bedrock-asset-processor && zip -r ../bedrock-asset-processor.zip index.py -q && cd ../..
aws lambda update-function-code --function-name bedrock-asset-processor --zip-file fileb://lambda/bedrock-asset-processor.zip --region "$REGION" --no-cli-pager 2>/dev/null
echo "  ✅ Lambda updated."

# ------------------------------------------------------------------
# 14. Deploy application via ArgoCD
# ------------------------------------------------------------------
echo "📦 Deploying application via ArgoCD..."

if ! kubectl get namespace argocd &>/dev/null; then
  echo "  ⚠️  ArgoCD not installed. Run Terraform first."
else
  # Delete old apps and let ArgoCD recreate from Git
  kubectl delete application --all -n argocd --ignore-not-found=true 2>/dev/null || true
  sleep 5
  
  # Apply fresh ArgoCD applications
  kubectl apply -f argocd/infrastructure-app.yaml
  kubectl apply -f argocd/retail-store-app.yaml
  echo "  ✅ ArgoCD applications applied."
fi

# ------------------------------------------------------------------
# 15. Wait for application pods
# ------------------------------------------------------------------
echo "⏳ Waiting for application pods..."
for i in $(seq 1 30); do
  READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  echo "  Pods ready: $READY"
  if [ "$READY" -ge 5 ] 2>/dev/null; then
    echo "  ✅ Application pods are running."
    break
  fi
  sleep 10
done

# ------------------------------------------------------------------
# 16. Wait for ALB
# ------------------------------------------------------------------
echo "⏳ Waiting for ALB..."
for i in $(seq 1 30); do
  ALB_URL=$(kubectl get ingress retail-store-ingress -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$ALB_URL" ] && break
  echo "  Waiting... $i/30"
  sleep 10
done

# ------------------------------------------------------------------
# 17. Summary
# ------------------------------------------------------------------
echo ""
echo "================================================================"
echo "🎉 Deployment Complete!"
echo "================================================================"
if [ -n "$ALB_URL" ]; then
  echo "✅ Application URL: http://$ALB_URL"
else
  echo "⚠️  Check manually: kubectl get ingress -n $NAMESPACE"
fi
echo ""
echo "📊 Pod Status:"
kubectl get pods -n "$NAMESPACE" 2>/dev/null | head -10
echo ""
echo "🔍 ArgoCD Status:"
echo "   kubectl get applications -n argocd"