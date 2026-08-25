# State remoto (patrón del lab 09). Descomenta y ajusta el bucket/tabla.
# Reutiliza el bucket S3 + tabla DynamoDB que ya creaste para IaC, o créalos.
#
# terraform {
#   backend "s3" {
#     bucket         = "TU-BUCKET-DE-STATE"
#     key            = "eks/14-chaos-lab/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "TU-TABLA-DE-LOCK"
#     encrypt        = true
#   }
# }
