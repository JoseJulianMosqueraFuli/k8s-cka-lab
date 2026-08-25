# =============================================================================
# Add-ons desplegados por Helm.
#   - Observabilidad (kube-prometheus-stack): SIEMPRE. Es el que mide el estado
#     estable del que depende todo el lab.
#   - Chaos Mesh: SOLO en la variante 'ec2' (necesita el daemon privilegiado que
#     Auto Mode/Bottlerocket no permite).
#
# helm v3: `set` es una LISTA de objetos { name, value }, no bloques repetidos.
# =============================================================================

# --- Observabilidad ---------------------------------------------------------
resource "helm_release" "monitoring" {
  count = var.install_monitoring ? 1 : 0

  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  # version        = "x.y.z"  # recomendado pinear en un entorno estable

  set = [
    {
      name  = "grafana.service.type"
      value = "ClusterIP" # accedes por `kubectl port-forward`; sin ALB extra
    },
    {
      # En Auto Mode no hay una StorageClass por defecto; evitamos que Prometheus
      # quede Pending pidiendo un PVC. Para retención real, define una SC y quita esto.
      name  = "prometheus.prometheusSpec.storageSpec"
      value = ""
    }
  ]

  depends_on = [module.eks]
}

# --- Chaos Mesh (solo variante ec2) ----------------------------------------
resource "helm_release" "chaos_mesh" {
  count = var.substrate == "ec2" && var.install_chaos_mesh ? 1 : 0

  name             = "chaos-mesh"
  repository       = "https://charts.chaos-mesh.org"
  chart            = "chaos-mesh"
  namespace        = "chaos-mesh"
  create_namespace = true
  # version        = "2.7.x"  # recomendado pinear

  set = [
    {
      name  = "chaosDaemon.runtime"
      value = "containerd"
    },
    {
      # Socket de containerd en nodos EKS AL2023.
      name  = "chaosDaemon.socketPath"
      value = "/run/containerd/containerd.sock"
    },
    {
      name  = "dashboard.create"
      value = "true"
    }
  ]

  depends_on = [module.eks]
}
