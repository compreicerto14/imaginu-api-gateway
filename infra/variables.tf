variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "region" {
  description = "Região dos recursos"
  type        = string
  default     = "us-east1"
}
