terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    bucket = "imaginu-terraform-state"
    prefix = "imaginu-api-gateway"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# Variáveis novas (mova para o variables.tf se preferir)
# ---------------------------------------------------------------------------

variable "espv2_version" {
  type        = string
  description = "Versão completa do ESPv2 (x.y.z). Liste com: gcloud container images list-tags gcr.io/endpoints-release/endpoints-runtime-serverless --sort-by=~timestamp --limit=5"

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", var.espv2_version))
    error_message = "Use a versão completa (ex.: 2.50.0). Com tag curta o script resolve outra versão e o nome da imagem não bate."
  }
}

variable "backend_services" {
  type        = list(string)
  description = "Serviços Cloud Run que ficam atrás do gateway"
  default     = ["imaginu-cliente"]
}

# ---------------------------------------------------------------------------

data "google_project" "this" {}

locals {
  endpoints_service_name = "imaginu-api.endpoints.${var.project_id}.cloud.goog"
  gateway_repo_url       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.gateway.repository_id}"

  # Mesmo formato de nome que o gcloud_build_image gera
  espv2_image = "${local.gateway_repo_url}/endpoints-runtime-serverless:${var.espv2_version}-${local.endpoints_service_name}-${google_endpoints_service.imaginu.config_id}"
}

resource "google_project_service" "build_apis" {
  for_each           = toset(["artifactregistry.googleapis.com", "cloudbuild.googleapis.com"])
  service            = each.value
  disable_on_destroy = false
}

# Repositório regional para a imagem do ESPv2 (mesma região do Cloud Run)
resource "google_artifact_registry_repository" "gateway" {
  location      = var.region
  repository_id = "imaginu-gateway"
  format        = "DOCKER"
  description   = "ESPv2 com a config do Endpoints embutida"

  depends_on = [google_project_service.build_apis]
}

# O gcloud builds submit roda com a SA padrão do Cloud Build. Em projetos
# recentes ela é a SA padrão do Compute Engine; se o seu projeto ainda usa a
# legada (NUMERO@cloudbuild.gserviceaccount.com), troque o member.
resource "google_artifact_registry_repository_iam_member" "build_writer" {
  location   = google_artifact_registry_repository.gateway.location
  repository = google_artifact_registry_repository.gateway.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

resource "google_service_account" "gateway" {
  account_id   = "apigw-imaginu"
  display_name = "Identidade do API Gateway"
}

# ESPv2 pode invocar cada backend no Cloud Run
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  for_each = toset(var.backend_services)
  name     = each.value
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.gateway.email}"
}

# ESPv2 precisa consultar o Service Control (quota, auth, logs)
resource "google_project_iam_member" "espv2_service_controller" {
  project = var.project_id
  role    = "roles/servicemanagement.serviceController"
  member  = "serviceAccount:${google_service_account.gateway.email}"
} 

# Registra o OpenAPI spec no Cloud Endpoints (Service Management API)
resource "google_endpoints_service" "imaginu" {
  service_name = local.endpoints_service_name
  project      = var.project_id

  openapi_config = templatefile("${path.module}/../openapi.yaml.tftpl", {
    project_id             = var.project_id
    cliente_url            = var.client_url
    endpoints_service_name = local.endpoints_service_name
  })
}

# Habilita o serviço do Endpoints no projeto (sem isso as requisições são recusadas)
resource "google_project_service" "imaginu_endpoints" {
  project            = var.project_id
  service            = google_endpoints_service.imaginu.service_name
  disable_on_destroy = false
}

# Gera a imagem do ESPv2 com a config embutida. Refaz o build sempre que o
# OpenAPI (config_id) ou a versão do ESPv2 mudarem.
# Precisa de bash, curl e gcloud autenticado onde o Terraform roda.
resource "terraform_data" "espv2_image" {
  triggers_replace = [
    google_endpoints_service.imaginu.config_id,
    var.espv2_version,
    local.gateway_repo_url,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      bash "${path.module}/../scripts/gcloud_build_image" \
        -s "${local.endpoints_service_name}" \
        -c "${google_endpoints_service.imaginu.config_id}" \
        -p "${var.project_id}" \
        -v "${var.espv2_version}" \
        -g "${local.gateway_repo_url}"
    EOT
  }

  depends_on = [
    google_project_service.build_apis,
    google_artifact_registry_repository_iam_member.build_writer,
  ]
}

# Serviço Cloud Run com ESPv2 (proxy/gateway)
resource "google_cloud_run_v2_service" "espv2" {
  name                = "imaginu-endpoints"
  location            = var.region
  deletion_protection = false

  template {
    service_account       = google_service_account.gateway.email
    execution_environment = "EXECUTION_ENVIRONMENT_GEN1"

    scaling {
      min_instance_count = 1
    }

    containers {
      # Config embutida: sem ENDPOINTS_SERVICE_NAME e sem rollout_strategy=managed
      image = local.espv2_image

      resources {
        startup_cpu_boost = true
        # Com o bloco resources declarado, o provider exige cpu_idle explícito
        # para manter "CPU só durante requests". Sem isso, a instância mínima
        # fica com CPU sempre alocada (bem mais cara).
        cpu_idle = true
      }
    }
  }

  depends_on = [
    terraform_data.espv2_image,
    google_project_iam_member.espv2_service_controller,
    google_project_service.imaginu_endpoints,
  ]
}

# Acesso público ao ESPv2 (ESPv2 valida auth internamente via Endpoints)
resource "google_cloud_run_v2_service_iam_member" "espv2_public" {
  name     = google_cloud_run_v2_service.espv2.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "gateway_url" {
  value = google_cloud_run_v2_service.espv2.uri
}

output "espv2_image" {
  value = local.espv2_image
}
