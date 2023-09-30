# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0
# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name = "education-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "education-vpc"

  cidr = "10.0.0.0/16"
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
  # azs = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"] 
  # private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24"]
  # public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.27"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  create_kms_key              = false
  create_cloudwatch_log_group = false
  cluster_encryption_config   = {}

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
    instance_types = ["m5a.xlarge", "t3a.small", "t3a.medium"]
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  eks_managed_node_groups = {
    node1 = {
      name = "node-group-1"

      instance_types = ["t3a.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 1

      capacity_type  = "SPOT"
    }

    node2 = {
      name = "node-group-2"

      instance_types = ["t3a.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 1

      capacity_type  = "SPOT"
    }
  }

  # aws-auth configmap
  manage_aws_auth_configmap = true

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/ 
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.7.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

################################################################################
# Load Balancer Role
################################################################################

module "lb_role" {
  depends_on = [ module.eks ]
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                              = "${module.eks.cluster_name}_eks_lb"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

###############################################################################
# Aws Load balancer Controller Service Account
###############################################################################

resource "kubernetes_service_account" "service-account" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = module.lb_role.iam_role_arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

################################################################################
# Install Load Balancer Controler With Helm
################################################################################

resource "helm_release" "lb" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  depends_on = [
    kubernetes_service_account.service-account
  ]

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "image.repository"
    value = "602401143452.dkr.ecr.${var.region}.amazonaws.com/amazon/aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
}

data "aws_ami" "amzn-linux-2023-ami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

data "aws_iam_policy_document" "devops_policy" {
  statement {

    actions = [ "ecr:*",
                "ecr-public:*",
                "eks:*", ]

    resources = [ "*" ]

    effect = "Allow"
  }
}

resource "aws_iam_role_policy" "devops_policy" {
  name = "devops_policy"

  policy = "${data.aws_iam_policy_document.devops_policy.json}"

  role = aws_iam_role.devops_role.id
}

data "aws_iam_policy_document" "devops_trust" {
  statement {
    actions = [ "sts:AssumeRole" ]

    principals {
      type = "Service"
      identifiers = [ "ec2.amazonaws.com" ]
    }

    effect = "Allow"
    
  }
}

resource "aws_iam_role" "devops_role" {
  name = "devops_role"
  path = "/"

  assume_role_policy = "${data.aws_iam_policy_document.devops_trust.json}"
}

resource "aws_iam_instance_profile" "devops_instance_profile" {
  name = "devops_instance_profile"

  role = aws_iam_role.devops_role.name
}

resource "kubernetes_service_account" "devops_service_account" {
  metadata {
    name      = "devops-service-account"

    labels = {
      "app.kubernetes.io/name" = "devops-service-account"
    }
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.devops_role.arn
    }
  }
}

resource "kubernetes_cluster_role" "devops_cluster_role" {
  metadata {
    name = "devops-cluster-role"
  }
 
  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}

resource "kubernetes_cluster_role_binding" "devops_role_binding" {
  metadata {
    name = "devops-role-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "devops-cluster-role"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "devops-service-account"
  }
}

resource "kubernetes_secret" "devops_service_secret" {
  metadata {
    name = "devops-service-secret"
    
    annotations = {
      "kubernetes.io/service-account.name" = "devops-service-account"
    }
  }

  type = "kubernetes.io/service-account-token"
}

resource "aws_instance" "jenkins_ci" {
  instance_type = "t3a.small"

  ami = data.aws_ami.amzn-linux-2023-ami.id

  subnet_id = module.vpc.public_subnets[0]

  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.devops_instance_profile.name

  vpc_security_group_ids = [ aws_security_group.jenkis_ci_sg.id ]
  
  key_name = "cintrollan"

  tags = {
    Name = "jenkins_ci"
    Terraform = "true"
    Environment = "Dev"
  }  
}

resource "aws_security_group" "jenkis_ci_sg" {
  name = "jenkis_ci_sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 8080
    to_port = 8080
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "jenkins_k8s_ingress" {
  type      = "ingress"
  from_port = 443
  to_port   = 443
  protocol  = "tcp"
  source_security_group_id = aws_security_group.jenkis_ci_sg.id
  security_group_id = module.eks.cluster_security_group_id
}

resource "aws_ecr_repository" "app_python_repository" {
  name = "app_python"

  image_tag_mutability = "MUTABLE"

}