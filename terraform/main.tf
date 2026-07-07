provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = "karatu-2025-capstone" }
  }
}

data "aws_caller_identity" "current" {}

# Kubernetes and Helm providers (needed for ArgoCD installation)
data "aws_eks_cluster" "main" {
  name = aws_eks_cluster.main.name
  depends_on = [aws_eks_cluster.main]
}

data "aws_eks_cluster_auth" "main" {
  name = aws_eks_cluster.main.name
  depends_on = [aws_eks_cluster.main]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

# ... rest of your resources (Secrets Manager, IAM, OIDC, etc.)

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

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.coredns,
    aws_eks_addon.kube_proxy
  ]
}