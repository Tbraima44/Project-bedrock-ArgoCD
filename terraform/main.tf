provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = "karatu-2025-capstone" }
  }
}

data "aws_caller_identity" "current" {}

# Secrets Manager for database credentials
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "project-bedrock-db-credentials"
  recovery_window_in_days = 0
  tags = { Project = "karatu-2025-capstone" }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    mysql_username      = var.db_username
    mysql_password      = var.db_password
    mysql_host          = aws_db_instance.mysql.endpoint
    mysql_port          = "3306"
    mysql_database      = "retaildb"
    postgresql_username = var.db_username
    postgresql_password = var.db_password
    postgresql_host     = "localhost"
    postgresql_port     = "5432"
  })
}

# IAM role for LB Controller (IRSA)
resource "aws_iam_role" "load_balancer_controller" {
  name = "project-bedrock-lb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.${var.aws_region}.amazonaws.com/id/${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}"
      }
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
  tags = { Project = "karatu-2025-capstone" }
}

resource "aws_iam_role_policy" "load_balancer_controller" {
  name = "project-bedrock-lb-controller-policy"
  role = aws_iam_role.load_balancer_controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "iam:CreateServiceLinkedRole",
        "ec2:DescribeAccountAttributes", "ec2:DescribeAddresses",
        "ec2:DescribeAvailabilityZones", "ec2:DescribeInternetGateways",
        "ec2:DescribeVpcs", "ec2:DescribeVpcPeeringConnections",
        "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeTags", "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateTags", "ec2:DeleteTags",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:DescribeListenerCertificates",
        "elasticloadbalancing:DescribeSSLPolicies",
        "elasticloadbalancing:DescribeRules",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:DescribeTargetGroupAttributes",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:DescribeTags",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:CreateRule",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:DeleteRule",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:ModifyLoadBalancerAttributes",
        "elasticloadbalancing:ModifyListener",
        "elasticloadbalancing:ModifyRule",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:SetIpAddressType",
        "elasticloadbalancing:SetSecurityGroups",
        "elasticloadbalancing:SetSubnets",
        "elasticloadbalancing:SetWebAcl",
        "elasticloadbalancing:AddListenerCertificates",
        "elasticloadbalancing:RemoveListenerCertificates",
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:RemoveTags"
      ]
      Resource = "*"
    }]
  })
}

# OIDC Provider
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  tags = { Project = "karatu-2025-capstone" }
}

# ArgoCD installation via Helm
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.8.0"

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [aws_eks_node_group.main]
}
#trigger