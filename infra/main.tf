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

locals {
  endpoints_service_name = "imaginu-api.endpoints.${var.project_id}.cloud.goog"
}

resource "google_service_account" "gateway" {
  account_id   = "apigw-imaginu"
  display_name = "Identidade do API Gateway"
}

data "google_project" "this" {}

# ESPv2 pode invocar cada backend no Cloud Run
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  for_each = toset(["imaginu-cliente"])
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

# Serviço Cloud Run com ESPv2 (proxy/gateway)
resource "google_cloud_run_v2_service" "espv2" {
  name     = "imaginu-endpoints"
  location = var.region
  deletion_protection = false

  template {
    service_account = google_service_account.gateway.email

    containers {
      image = "gcr.io/endpoints-release/endpoints-runtime-serverless:2"

      env {
        name  = "ENDPOINTS_SERVICE_NAME"
        value = local.endpoints_service_name
      }

      env {
        # fixed: ESPv2 usa a config já conhecida no boot, sem chamada ao
        # Service Management API — economiza ~400 ms de latência de inicialização
        name  = "ESPv2_ARGS"
        value = "--rollout_strategy=fixed --service_config_id=${google_endpoints_service.imaginu.config_id}"
      }
    }
  }

  depends_on = [google_endpoints_service.imaginu, google_project_iam_member.espv2_service_controller, google_project_service.imaginu_endpoints]
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