locals {
  project_id = "wandai-interview"
  region     = "europe-west3"
}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google-beta"
      version = "4.53.1"
    }
  }
}

provider "google" {
  project = local.project_id
}

data "google_project" "project" {
}

output "project_number" {
  value = data.google_project.project.number
}

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

module "gcp-network" {
  source = "terraform-google-modules/network/google"

  project_id   = local.project_id
  network_name = "demo-network"

  subnets = [
    {
      subnet_name   = "demo-subnet"
      subnet_ip     = "10.0.0.0/17"
      subnet_region = local.region
    },
    {
      subnet_name   = "demo-master-subnet"
      subnet_ip     = "10.60.0.0/17"
      subnet_region = local.region
    },
  ]

  secondary_ranges = {
    "demo-subnet" = [
      {
        range_name    = "demo-subnet-pods"
        ip_cidr_range = "192.168.0.0/18"
      },
      {
        range_name    = "demo-subnet-svc"
        ip_cidr_range = "192.168.64.0/18"
      },
    ]
  }

  depends_on = [
    google_project_service.compute,
  ]
}
