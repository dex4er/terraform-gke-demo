## Fixed versions of providers

terraform {
  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "2.3.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "4.53.1"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "4.53.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.18.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.4.3"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.9.1"
    }
  }
}

## Set it in `terraform.tfvars` file or `TF_VAR_` environment variables.

variable "region" {
  type = string
}

variable "project_id" {
  type = string
}

locals {
  name       = "terraform-gke-demo"
  region     = var.region
  project_id = var.project_id
}

output "project_id" {
  value = local.project_id
}

output "region" {
  value = local.region
}

provider "google" {
  project = local.project_id
}

## Enable GCP APIs

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "container" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

## Public Artifact registry to avoid IAM settings for demo

resource "google_artifact_registry_repository" "this" {
  location      = local.region
  repository_id = local.name
  format        = "DOCKER"

  depends_on = [
    google_project_service.artifactregistry,
  ]
}

resource "google_artifact_registry_repository_iam_member" "member" {
  project    = google_artifact_registry_repository.this.project
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.reader"
  member     = "allUsers"
}

resource "null_resource" "gcloud_auth_configure-docker" {
  provisioner "local-exec" {
    command = "gcloud auth configure-docker ${google_artifact_registry_repository.this.location}-docker.pkg.dev"
  }
}

## Network for the cluster

module "gcp-network" {
  source  = "terraform-google-modules/network/google"
  version = "6.0.1"

  project_id   = local.project_id
  network_name = "${local.name}-network"

  subnets = [
    {
      subnet_name   = "${local.name}-subnet"
      subnet_ip     = "10.0.0.0/17"
      subnet_region = local.region
    },
  ]

  secondary_ranges = {
    ("${local.name}-subnet") = [
      {
        range_name    = "${local.name}-ip-range-pods"
        ip_cidr_range = "192.168.0.0/18"
      },
      {
        range_name    = "${local.name}-ip-range-svc"
        ip_cidr_range = "192.168.64.0/18"
      },
    ]
  }

  ## Dependencies for modules are harmful but we need the API anyway
  depends_on = [
    google_project_service.compute
  ]
}

## Autopilot cluster

module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/beta-autopilot-public-cluster"
  version = "25.0.0"

  project_id = local.project_id
  region     = local.region

  name                            = local.name
  regional                        = true
  network                         = module.gcp-network.network_name
  subnetwork                      = module.gcp-network.subnets_names[0]
  ip_range_pods                   = module.gcp-network.subnets_secondary_ranges[0][0].range_name
  ip_range_services               = module.gcp-network.subnets_secondary_ranges[0][1].range_name
  release_channel                 = "REGULAR"
  enable_vertical_pod_autoscaling = true

  ## Dependency on network is via module outputs. Only APIs are here directly.
  depends_on = [
    google_project_service.compute,
    google_project_service.container,
  ]
}

locals {
  context = "gke_${local.project_id}_${local.region}_${local.name}"
}

## ~/.kube/config

resource "null_resource" "gcloud_container_clusters_get-credentials" {
  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${local.name} --region ${local.region} --project ${local.project_id}"
  }

  depends_on = [
    module.gke,
  ]
}

## ./.kube/config

resource "null_resource" "gcloud_container_clusters_get-credentials_kubeconfig" {
  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${local.name} --region ${local.region} --project ${local.project_id}"
    environment = {
      KUBECONFIG = ".kube/config"
    }
  }

  depends_on = [
    module.gke,
  ]
}

## Pass variables from Terraform to Flux through env file

resource "local_file" "cluster_vars" {
  content = join("\n", [
    "cluster_name=${local.name}",
    "project_id=${local.project_id}",
    "region=${local.region}",
  ])
  filename = "flux/flux-system/cluster-vars.env"
}

## Calculate checksum for ./flux directory to detect the changes

data "archive_file" "flux" {
  type        = "zip"
  source_dir  = "flux"
  output_path = ".flux.zip"
}

## This file can't be resolved by Flux yet

resource "local_file" "ocirepository" {
  content = templatefile("flux/flux-system/ocirepository.yaml.tftpl", {
    cluster_name = local.name,
    project_id   = local.project_id,
    region       = local.region,
  })
  filename = "flux/flux-system/ocirepository.yaml"
}

## Push ./flux directory to kind-registry

resource "null_resource" "flux_push_artifact" {
  triggers = {
    flux_directory_checksum = data.archive_file.flux.output_base64sha256
  }

  provisioner "local-exec" {
    command = "flux push artifact oci://${local.region}-docker.pkg.dev/${local.project_id}/${local.name}/flux-system:latest --path=flux --source=\"localhost\" --revision=\"$(git rev-parse --short HEAD 2>/dev/null || LC_ALL=C date +%Y%m%d%H%M%S)\" --kubeconfig .kube/config --context ${local.context}"
  }

  depends_on = [
    google_artifact_registry_repository.this,
    local_file.cluster_vars,
    local_file.ocirepository,
  ]
}

## Flux: step 1 - install CRDs and main manifest

resource "null_resource" "apply_flux_system_install" {
  provisioner "local-exec" {
    command = "kubectl apply -k flux/flux-system-install --server-side --kubeconfig .kube/config --context ${local.context}"
  }

  depends_on = [
    null_resource.gcloud_container_clusters_get-credentials_kubeconfig,
  ]
}

## Flux: step 2 - install sources and kustomization

resource "null_resource" "apply_flux_system" {
  provisioner "local-exec" {
    command = "kubectl apply -k flux/flux-system --server-side --kubeconfig .kube/config --context ${local.context}"
  }

  depends_on = [
    null_resource.apply_flux_system_install,
  ]
}

## Flux: step 3 - install main Flux kustomization

resource "null_resource" "apply_flux_all" {
  provisioner "local-exec" {
    command = "kubectl apply -f flux/all.yaml --server-side --kubeconfig .kube/config --context ${local.context}"
  }

  depends_on = [
    null_resource.apply_flux_system,
  ]
}

resource "time_sleep" "after_apply_flux_all" {
  create_duration = "120s"

  depends_on = [
    null_resource.apply_flux_all,
  ]
}

## Reconcile Flux source repo and kustomization

resource "null_resource" "flux_reconcile_all" {
  triggers = {
    flux_push_artifact_id = null_resource.flux_push_artifact.id
  }

  provisioner "local-exec" {
    command = "flux reconcile source oci flux-system --kubeconfig .kube/config --context ${local.context} && flux reconcile ks all --kubeconfig .kube/config --context ${local.context}"
  }

  depends_on = [
    time_sleep.after_apply_flux_all,
    null_resource.flux_push_artifact,
  ]
}
