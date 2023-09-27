# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "cluster_certificate_authority_data" {
  description = "Kubernetes Certificate"
  value       = module.eks.cluster_certificate_authority_data
}

output "jenkins_dns" {
  description = "Jenkins DNS"
  value       = aws_instance.jenkins_ci.public_dns
}

output "devops_service_token" {
  description = "Service Token"
  value       = kubernetes_secret.devops_service_secret.data.token
  sensitive   = true
}