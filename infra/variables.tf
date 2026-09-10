variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "region" {
  description = "Região dos recursos"
  type        = string
  default     = "us-east1"
}

variable "client_url" {
  description = "URL do backend do cliente"
  type        = string
  default     = "https://imaginu-cliente-940298061308.us-east1.run.app"
}
