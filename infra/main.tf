terraform {
  required_version = ">= 1.7" # necessário para os blocos "removed"

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

# ------------------------------------------------------------------
# Fundação: só o que muda raramente. Cloud Run do gateway e OpenAPI
# são responsabilidade da pipeline (.github/workflows/espv2-deploy.yml)
# ------------------------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "servicemanagement.googleapis.com",
    "servicecontrol.googleapis.com",
    "endpoints.googleapis.com",
    "artifactregistry.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Identidade de runtime do ESPv2 (a pipeline só referencia pelo e-mail)
resource "google_service_account" "gateway" {
  account_id   = "apigw-imaginu"
  display_name = "Identidade do API Gateway"
}

data "google_project" "this" {}

# ESPv2 pode invocar cada backend no Cloud Run
# (exige que o backend já exista no momento do apply)
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

# Repositório das imagens ESPv2 com service config embutida
resource "google_artifact_registry_repository" "gateway" {
  repository_id = "api-gateway"
  location      = var.region
  format        = "DOCKER"
  description   = "Imagens ESPv2 com service config embutida"

  cleanup_policies {
    id     = "manter-ultimas-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "apagar-mais-de-30-dias"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "2592000s"
    }
  }

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------
# Handover para a pipeline: tira do state SEM destruir os recursos.
# Depois de um apply bem-sucedido, estes blocos podem ser apagados.
# ------------------------------------------------------------------

removed {
  from = google_cloud_run_v2_service.espv2
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_cloud_run_v2_service_iam_member.espv2_public
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_endpoints_service.imaginu
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_service.imaginu_endpoints
  lifecycle {
    destroy = false
  }
}

output "gateway_service_account" {
  value = google_service_account.gateway.email
}

output "espv2_image_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.gateway.repository_id}"
}

output "endpoints_service_name" {
  value = local.endpoints_service_name
}
