# Illustrative module contract, not a deployed or production-locked module.
# Live configuration must supply a pinned Google provider and approved project IDs.
terraform {
  required_version = ">= 1.6.0, < 2.0.0"
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

variable "identity_project_id" {
  type = string
}

variable "gke_project_id" {
  type = string
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "This design example supports dev or prod."
  }
}

locals {
  identities = {
    worker = {
      namespace = "harness-workers-${var.environment}"
      ksa_name  = "harness-worker"
    }
    gateway = {
      namespace = "harness-control-${var.environment}"
      ksa_name  = "harness-gateway"
    }
  }
}

resource "google_service_account" "identity" {
  for_each     = local.identities
  project      = var.identity_project_id
  account_id   = "harness-${each.key}-${var.environment}"
  display_name = "Harness ${each.key} ${var.environment}"
}

resource "google_service_account_iam_member" "ksa_link" {
  for_each           = local.identities
  service_account_id = google_service_account.identity[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.gke_project_id}.svc.id.goog[${each.value.namespace}/${each.value.ksa_name}]"
}

output "workload_configuration" {
  value = {
    for key, identity in google_service_account.identity : key => {
      ksa_namespace = local.identities[key].namespace
      ksa_name      = local.identities[key].ksa_name
      gsa_email     = identity.email
      gsa_subject   = identity.unique_id
    }
  }
}
