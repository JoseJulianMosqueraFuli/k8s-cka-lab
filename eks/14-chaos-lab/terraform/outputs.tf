output "cluster_name" {
  description = "Nombre del cluster EKS."
  value       = module.eks.cluster_name
}

output "substrate" {
  description = "Substrato activo (automode | ec2)."
  value       = var.substrate
}

output "configure_kubectl" {
  description = "Comando para conectar kubectl."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "grafana_port_forward" {
  description = "Cómo abrir Grafana (usuario admin; password en el secret)."
  value       = var.install_monitoring ? "kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80" : "monitoring deshabilitado"
}

output "ecr_repositories" {
  description = "URLs de los repos ECR de la app."
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "fis_role_arn" {
  description = "ARN del rol IAM de AWS FIS."
  value       = var.enable_fis ? aws_iam_role.fis[0].arn : null
}

output "fis_experiment_template_ids" {
  description = "IDs de los experiment templates de FIS."
  value = var.enable_fis ? {
    pod_delete          = aws_fis_experiment_template.pod_delete[0].id
    pod_network_latency = aws_fis_experiment_template.pod_network_latency[0].id
  } : {}
}
