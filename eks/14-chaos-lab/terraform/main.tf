# =============================================================================
# Lab 14 · Chaos engineering — infraestructura base
#
# Una variable (var.substrate) decide el substrato y, con él, el motor de caos:
#   automode -> EKS Auto Mode + AWS FIS       (nodos cerrados, caos gestionado)
#   ec2      -> Managed Node Group + Chaos Mesh (nodos EC2, caos in-cluster)
#
# NOTA: correr UNA variante a la vez. Cambiar de substrato recrea el cluster.
#       Antes de cambiar: `terraform destroy`.
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
}

# --- Red --------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = local.cluster_name
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.64.0/19", "10.0.96.0/19"]

  enable_nat_gateway   = true
  single_nat_gateway   = true # un solo NAT para abaratar el lab
  enable_dns_hostnames = true

  # Tags que EKS/Auto Mode y el LB necesitan para descubrir subnets.
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
  version = "~> 20.31" # v20.31+ soporta Auto Mode (cluster_compute_config)

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true # te da admin del cluster al aplicar

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Variante A · Auto Mode. Con enabled=true, EKS gestiona compute + storage +
  # load balancing. En 'ec2' se desactiva.
  cluster_compute_config = var.substrate == "automode" ? {
    enabled    = true
    node_pools = ["general-purpose", "system"]
    } : {
    enabled = false
  }

  # Variante B · Managed Node Group EC2 (para que Chaos Mesh pueda correr su
  # daemon privilegiado). Vacío en 'automode'.
  eks_managed_node_groups = var.substrate == "ec2" ? {
    chaos = {
      instance_types = var.ec2_instance_types
      min_size       = var.ec2_desired_size
      max_size       = var.ec2_desired_size + 2
      desired_size   = var.ec2_desired_size
    }
  } : {}

  tags = local.tags
}
