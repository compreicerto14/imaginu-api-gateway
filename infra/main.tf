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

resource "google_service_account" "gateway" {
  account_id   = "apigw-imaginu"
  display_name = "Identidade do API Gateway"
}

data "google_project" "this" {}

resource "google_service_account_iam_member" "apigw_agent" {
  service_account_id = google_service_account.gateway.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-apigateway.iam.gserviceaccount.com"
}

# invoker em cada backend
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  for_each = toset(["imaginu-cliente"])
  name     = each.value
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.gateway.email}"
}

resource "google_api_gateway_api" "imaginu" {
  provider = google-beta
  api_id   = "imaginu"
}

resource "google_api_gateway_api_config" "imaginu" {
  provider             = google-beta
  api                  = google_api_gateway_api.imaginu.api_id
  api_config_id_prefix = "cfg-"

  openapi_documents {
    document {
      path     = "openapi.yaml"
      contents = base64encode(templatefile("${path.module}/../openapi.yaml.tftpl", {
        project_id  = var.project_id
        cliente_url = var.client_url
      }))
    }
  }

  gateway_config {
    backend_config {
      google_service_account = google_service_account.gateway.email
    }
  }

  lifecycle { create_before_destroy = true }
  depends_on = [google_service_account_iam_member.apigw_agent]
}

resource "google_api_gateway_gateway" "imaginu" {
  provider   = google-beta
  region     = local.region
  gateway_id = "imaginu-gw"
  api_config = google_api_gateway_api_config.imaginu.id
}

output "gateway_url" {
  value = "https://${google_api_gateway_gateway.imaginu.default_hostname}"
}