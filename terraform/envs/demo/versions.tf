terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }

  backend "gcs" {
    prefix = "envs/demo"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
