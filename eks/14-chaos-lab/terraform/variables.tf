variable "region" {
  description = "Región de AWS."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Prefijo/nombre base del lab. El cluster se llama <name>-<substrate>."
  type        = string
  default     = "chaos-lab"
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes del cluster."
  type        = string
  default     = "1.31"
}

# --- La decisión central del lab -------------------------------------------
# automode -> EKS Auto Mode (Bottlerocket, nodos cerrados). Caos con AWS FIS.
# ec2      -> Managed Node Group EC2. Caos con Chaos Mesh (+ FIS opcional).
variable "substrate" {
  description = "Substrato del cluster: 'automode' o 'ec2'."
  type        = string
  default     = "automode"

  validation {
    condition     = contains(["automode", "ec2"], var.substrate)
    error_message = "substrate debe ser 'automode' o 'ec2'."
  }
}

variable "ec2_instance_types" {
  description = "Tipos de instancia del node group (solo variante ec2)."
  type        = list(string)
  default     = ["t3.large"]
}

variable "ec2_desired_size" {
  description = "Nodos deseados en el node group (solo variante ec2)."
  type        = number
  default     = 2
}

variable "install_chaos_mesh" {
  description = "Instalar Chaos Mesh. Solo tiene sentido en 'ec2' (daemon privilegiado)."
  type        = bool
  default     = true
}

variable "install_monitoring" {
  description = "Instalar kube-prometheus-stack (Prometheus + Grafana)."
  type        = bool
  default     = true
}

variable "enable_fis" {
  description = "Crear el rol y los experiment templates de AWS FIS."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags comunes."
  type        = map(string)
  default = {
    Lab       = "14-chaos-lab"
    ManagedBy = "terraform"
  }
}
