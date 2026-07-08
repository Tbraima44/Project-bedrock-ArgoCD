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

# ------------------------------------------------------------------
# 2. Connect to EKS
# ------------------------------------------------------------------
echo "🔗 Updating kubeconfig..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
echo ""
kubectl get nodes
echo ""

# ------------------------------------------------------------------
# 3. Get infrastructure values
# ------------------------------------------------------------------
echo "📊 Fetching infrastructure values..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=project-bedrock-vpc" --query 'Vpcs[0].VpcId' --output text --region "$REGION")
echo "  VPC ID: $VPC_ID"

# ------------------------------------------------------------------
# 4. Install AWS Load Balancer Controller (COMPLETE)
# ------------------------------------------------------------------
echo "🌐 Installing AWS Load Balancer Controller..."

# 4a. Apply CRDs
echo "  Applying CRDs..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/config/crd/bases/elbv2.k8s.aws_targetgroupbindings.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/config/crd/bases/elbv2.k8s.aws_ingressclassparams.yaml

# 4b. Apply ClusterRole and ClusterRoleBinding from Git
echo "  Applying RBAC..."
kubectl apply -f kubernetes/infrastructure/lb-controller/clusterrole.yaml
kubectl apply -f kubernetes/infrastructure/lb-controller/clusterrolebinding.yaml

# 4c. Generate TLS certificate
echo "  Generating TLS certificate..."
openssl req -x509 -newkey rsa:2048 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -nodes -subj "/CN=aws-load-balancer-controller"
kubectl delete secret aws-load-balancer-tls -n kube-system --ignore-not-found=true
kubectl create secret tls aws-load-balancer-tls --cert=/tmp/tls.crt --key=/tmp/tls.key -n kube-system
rm /tmp/tls.key /tmp/tls.crt

# 4d. Create ServiceAccount with IRSA
echo "  Creating ServiceAccount with IRSA..."
kubectl delete serviceaccount aws-load-balancer-controller -n kube-system --ignore-not-found=true
kubectl create serviceaccount aws-load-balancer-controller -n kube-system --dry-run=client -o yaml | \
  kubectl annotate --local -f - "eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/project-bedrock-lb-controller-role" --dry-run=client -o yaml | \
  kubectl apply -f -

# 4e. Delete old replicasets
echo "  Cleaning old replicasets..."
kubectl delete replicaset -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --ignore-not-found=true 2>/dev/null || true

# 4f. Deploy controller with dynamic VPC ID
echo "  Deploying controller..."
kubectl delete deployment aws-load-balancer-controller -n kube-system --ignore-not-found=true
sed "s/--aws-vpc-id=.*/--aws-vpc-id=$VPC_ID/" kubernetes/infrastructure/lb-controller/deployment.yaml | kubectl apply -f -

# 4g. Wait for controller
echo "  Waiting for LB Controller..."
for i in $(seq 1 12); do
  if kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -q Running; then
    echo "  ✅ LB Controller is running."
    break
  fi
  if [ $i -eq 12 ]; then
    echo "  ❌ LB Controller failed to start. Debug:"
    kubectl describe pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller | tail -20
    kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20
    exit 1
  fi
  sleep 10
done

# ------------------------------------------------------------------
# 5. Add security group rule (ALB → Nodes)
# ------------------------------------------------------------------
echo "🔓 Configuring security group..."
NODE_SG=$(aws ec2 describe-instances --filters "Name=tag:aws:eks:cluster-name,Values=$CLUSTER_NAME" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$NODE_SG" ] && [ "$NODE_SG" != "None" ]; then
  aws ec2 authorize-security-group-ingress --group-id "$NODE_SG" --protocol tcp --port 8080 --cidr "10.0.0.0/16" --region "$REGION" 2>/dev/null || true
  echo "  ✅ Security group rule added."
fi

# ------------------------------------------------------------------
# 6. Developer access
# ------------------------------------------------------------------
echo "🔐 Configuring developer access..."
kubectl apply -f kubernetes/rbac/dev-view-clusterrolebinding.yaml
kubectl patch configmap aws-auth -n kube-system --type merge -p '{"data":{"mapUsers":"- userarn: arn:aws:iam::'$ACCOUNT_ID':user/bedrock-dev-view\n  username: bedrock-dev-view\n  groups:\n  - view"}}' 2>/dev/null || true

# ------------------------------------------------------------------
# 7. Enable CloudWatch
# ------------------------------------------------------------------
echo "📊 Enabling CloudWatch Observability..."
aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name amazon-cloudwatch-observability --region "$REGION" 2>/dev/null && echo "  ✅ CloudWatch add-on created." || echo "  ℹ️  Add-on may already exist."

# ------------------------------------------------------------------
# 8. Update Lambda
# ------------------------------------------------------------------
echo "⚡ Updating Lambda..."
cd lambda/bedrock-asset-processor && zip -r ../bedrock-asset-processor.zip index.py && cd ../..
aws lambda update-function-code --function-name bedrock-asset-processor --zip-file fileb://lambda/bedrock-asset-processor.zip --region "$REGION" --no-cli-pager
echo "  ✅ Lambda updated."

# ------------------------------------------------------------------
# 9. Deploy application via ArgoCD
# ------------------------------------------------------------------
echo "📦 Deploying application via ArgoCD..."

# Check if ArgoCD is installed
if ! kubectl get namespace argocd &>/dev/null; then
  echo "  ⚠️  ArgoCD not found. Install it via Terraform first."
  echo "  Run: cd terraform && terraform apply"
else
  # Delete old applications to force fresh sync
  echo "  Refreshing ArgoCD applications..."
  kubectl delete application --all -n argocd --ignore-not-found=true 2>/dev/null || true
  sleep 5
  
  # Apply fresh
  kubectl apply -f argocd/infrastructure-app.yaml
  kubectl apply -f argocd/retail-store-app.yaml
  echo "  ✅ ArgoCD applications applied."
fi

# ------------------------------------------------------------------
# 10. Wait for pods
# ------------------------------------------------------------------
echo "⏳ Waiting for application pods..."
sleep 30
for i in $(seq 1 12); do
  READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c Running || echo 0)
  TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo 0)
  echo "  Pods ready: $READY/$TOTAL"
  if [ "$READY" -ge 5 ] 2>/dev/null; then
    echo "  ✅ Application pods are running."
    break
  fi
  sleep 15
done

# ------------------------------------------------------------------
# 11. Apply Ingress and wait for ALB
# ------------------------------------------------------------------
echo "🚪 Configuring Ingress..."
kubectl delete ingress retail-store-ingress -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

# Apply Ingress with correct service name
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: retail-store-ingress
  namespace: $NAMESPACE
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-port: "8080"
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: retail-store-ui
            port:
              number: 80
EOF

echo "⏳ Waiting for ALB..."
for i in $(seq 1 30); do
  ALB_URL=$(kubectl get ingress retail-store-ingress -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$ALB_URL" ] && break
  echo "  Waiting... $i/30"
  sleep 10
done

# ------------------------------------------------------------------
# 12. Summary
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
kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "  (pods not yet ready)"

echo ""
echo "🔍 ArgoCD Access:"
echo "   kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "   Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"