# =============================================================================
# Lab 14 · Chaos engineering — infraestructura base
#
# var.substrate decide el substrato y, con él, el motor de caos:
#   automode -> EKS Auto Mode + AWS FIS        (nodos cerrados, caos gestionado)
#   ec2      -> Managed Node Group + Chaos Mesh (nodos EC2, caos in-cluster)
#
# Correr UNA variante a la vez. Cambiar de substrato recrea el cluster:
# `terraform destroy` antes de cambiar.
#
# Versiones (validadas contra el registry, ago 2026):
#   - terraform-aws-modules/eks   ~> 21.0  (inputs v21: name, kubernetes_version,
#     endpoint_public_access, compute_config)
#   - terraform-aws-modules/vpc   ~> 6.0
#   - hashicorp/aws ~> 6.59 · helm ~> 3.0 · kubernetes ~> 3.0
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  cluster_name = "${var.name}-${var.substrate}"
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = merge(var.tags, {
    Substrate = var.substrate
    Cluster   = local.cluster_name
  })

  # Node group EC2 (solo variante 'ec2'). Se filtra con un for más abajo para
  # evitar el choque de tipos de un ternario contra un mapa vacío.
  ec2_node_groups = {
    chaos = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.ec2_instance_types
      min_size       = var.ec2_desired_size
      max_size       = var.ec2_desired_size + 2
      desired_size   = var.ec2_desired_size
    }
  }
}

# --- Red --------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.cluster_name
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.64.0/19", "10.0.96.0/19"]

  enable_nat_gateway   = true
  single_nat_gateway   = true # un solo NAT para abaratar el lab
  enable_dns_hostnames = true

  # Tags que EKS/Auto Mode y el ALB necesitan para descubrir subnets.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}

# --- Cluster EKS ------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true # te da admin del cluster al aplicar

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Variante A · Auto Mode. enabled=true habilita compute + storage + LB
  # gestionados. En 'ec2' queda deshabilitado. Objeto único (sin ternario entre
  # objetos de distinta forma) para no romper la comprobación de tipos.
  compute_config = {
    enabled    = var.substrate == "automode"
    node_pools = var.substrate == "automode" ? ["general-purpose", "system"] : []
  }

  # Variante B · Managed Node Group EC2 (para el daemon privilegiado de Chaos
  # Mesh). El for-filter deja el mapa vacío en 'automode' conservando el tipo.
  eks_managed_node_groups = {
    for k, v in local.ec2_node_groups : k => v
    if var.substrate == "ec2"
  }

  tags = local.tags
}
