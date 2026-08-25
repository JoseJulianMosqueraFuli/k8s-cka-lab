# =============================================================================
# App "url-shortener": repos ECR + namespace.
#
# Los workloads (Deployments/Services/Ingress de frontend, bff, link-service,
# worker, Postgres, Redis) se agregan junto con el código Go de la app en `app/`.
# Aquí dejamos listos el namespace y los repos para las imágenes.
# =============================================================================

locals {
  app_services = ["frontend", "bff", "link-service", "worker"]
}

resource "kubernetes_namespace" "apps" {
  metadata {
    name = "apps"
    labels = {
      "app.kubernetes.io/part-of" = "url-shortener"
    }
  }

  depends_on = [module.eks]
}

resource "aws_ecr_repository" "app" {
  for_each = toset(local.app_services)

  name                 = "chaos-lab/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # lab: permite destruir el repo aunque tenga imágenes

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}
