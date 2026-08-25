# =============================================================================
# AWS FIS — motor de caos para la variante 'automode' (y usable también en ec2).
#
# Las acciones aws:eks:pod-* crean un pod inyector en el cluster con contenedores
# efímeros, así que NO necesitan daemon privilegiado (funcionan en Auto Mode).
# Requieren: (1) un rol IAM para FIS, (2) que ese rol pueda autenticarse al
# cluster (EKS access entry), y (3) un ServiceAccount con RBAC que el pod inyector
# usa dentro del namespace objetivo.
#
# NOTA: el RBAC de abajo es permisivo para que el lab funcione; en un entorno real
# hay que acotarlo. Los parámetros exactos de cada acción pueden ajustarse en el
# primer `terraform plan`/experimento (ver AWS FIS actions reference).
# =============================================================================

data "aws_partition" "current" {}

# --- Rol IAM que asume el servicio FIS --------------------------------------
resource "aws_iam_role" "fis" {
  count = var.enable_fis ? 1 : 0

  name = "${local.cluster_name}-fis"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.${data.aws_partition.current.dns_suffix}" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

# Policies gestionadas de FIS (EKS pod actions + red + EC2 para Spot/AZ).
# Verifica los ARNs con: aws iam list-policies --scope AWS | grep FaultInjection
resource "aws_iam_role_policy_attachment" "fis" {
  for_each = var.enable_fis ? toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEKSAccess",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access",
  ]) : toset([])

  role       = aws_iam_role.fis[0].name
  policy_arn = each.value
}

# --- Acceso del rol FIS al cluster (EKS access entry) -----------------------
resource "aws_eks_access_entry" "fis" {
  count = var.enable_fis ? 1 : 0

  cluster_name      = module.eks.cluster_name
  principal_arn     = aws_iam_role.fis[0].arn
  kubernetes_groups = ["fis-experiments"]
  type              = "STANDARD"
}

# --- ServiceAccount + RBAC que usa el pod inyector de FIS -------------------
resource "kubernetes_service_account" "fis" {
  count = var.enable_fis ? 1 : 0

  metadata {
    name      = "fis-experiment"
    namespace = kubernetes_namespace.apps.metadata[0].name
  }
}

# RBAC permisivo para el lab. FIS necesita crear/observar pods y contenedores
# efímeros en el namespace objetivo. Acotar en producción.
resource "kubernetes_cluster_role" "fis" {
  count = var.enable_fis ? 1 : 0

  metadata {
    name = "fis-experiment"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/ephemeralcontainers", "pods/exec", "events", "nodes"]
    verbs      = ["get", "list", "watch", "create", "delete", "patch", "update"]
  }
}

resource "kubernetes_cluster_role_binding" "fis" {
  count = var.enable_fis ? 1 : 0

  metadata {
    name = "fis-experiment"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.fis[0].metadata[0].name
  }

  # El grupo del access entry (para el rol IAM de FIS).
  subject {
    kind      = "Group"
    name      = "fis-experiments"
    api_group = "rbac.authorization.k8s.io"
  }

  # El ServiceAccount que usa el pod inyector.
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.fis[0].metadata[0].name
    namespace = kubernetes_namespace.apps.metadata[0].name
  }
}

# --- Experiment templates ---------------------------------------------------
# Experimento 1 · matar un pod (aws:eks:pod-delete).
resource "aws_fis_experiment_template" "pod_delete" {
  count = var.enable_fis ? 1 : 0

  description = "Lab14: eliminar un pod de link-service"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none" # sin alarma; en un experimento real: aws:cloudwatch:alarm
  }

  action {
    name      = "pod-delete"
    action_id = "aws:eks:pod-delete"

    target {
      key   = "Pods"
      value = "link-service-pods"
    }

    parameter {
      key   = "kubernetesServiceAccount"
      value = "fis-experiment"
    }
  }

  target {
    name           = "link-service-pods"
    resource_type  = "aws:eks:pod"
    selection_mode = "COUNT(1)"

    parameters = {
      clusterIdentifier = module.eks.cluster_name
      namespace         = "apps"
      selectorType      = "labelSelector"
      selectorValue     = "app=link-service"
    }
  }

  tags = merge(local.tags, { Name = "${local.cluster_name}-pod-delete" })
}

# Experimento 2 · latencia de red (aws:eks:pod-network-latency).
resource "aws_fis_experiment_template" "pod_network_latency" {
  count = var.enable_fis ? 1 : 0

  description = "Lab14: 500ms de latencia en el BFF"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "network-latency"
    action_id = "aws:eks:pod-network-latency"

    target {
      key   = "Pods"
      value = "bff-pods"
    }

    parameter {
      key   = "kubernetesServiceAccount"
      value = "fis-experiment"
    }
    parameter {
      key   = "duration"
      value = "PT3M"
    }
    parameter {
      key   = "delayMilliseconds"
      value = "500"
    }
    parameter {
      key   = "jitterMilliseconds"
      value = "100"
    }
  }

  target {
    name           = "bff-pods"
    resource_type  = "aws:eks:pod"
    selection_mode = "ALL"

    parameters = {
      clusterIdentifier = module.eks.cluster_name
      namespace         = "apps"
      selectorType      = "labelSelector"
      selectorValue     = "app=bff"
    }
  }

  tags = merge(local.tags, { Name = "${local.cluster_name}-network-latency" })
}
