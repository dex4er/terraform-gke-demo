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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.18.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.4.3"
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

resource "google_project_service" "container" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

module "gcp-network" {
  source  = "terraform-google-modules/network/google"
  version = "6.0.1"

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

module "gke" {
  source                          = "terraform-google-modules/kubernetes-engine/google"
  version                         = "25.0.0"
  project_id                      = local.project_id
  name                            = "demo"
  regional                        = true
  region                          = local.region
  network                         = module.gcp-network.network_name
  subnetwork                      = "demo-subnet"
  ip_range_pods                   = "demo-subnet-pods"
  ip_range_services               = "demo-subnet-svc"
  release_channel                 = "REGULAR"
  enable_vertical_pod_autoscaling = false

  depends_on = [
    google_project_service.compute,
    google_project_service.container,
  ]
}
