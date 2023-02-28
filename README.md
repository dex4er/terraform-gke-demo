# terraform-gke-demo

Simple demo of the application deployed in GKE cluster using Flux with OCI
repository instead of Git repository.

## Usage

- Configure GCP:

```sh
gcloud init
gcloud auth login
gcloud config set project $PROJECT
```

- Run Terraform:

```sh
terraform init
terraform apply
```

- Connect to ingress:

```sh
kubectl get ingress -n podinfo
curl http://$ADDRESS
```

## Note

There is only a single Terraform file [`main.tf`](main.tf). The state should be
local because `local_file` resources are used for extra files generated:
OCIRepository and environment variables for Flux.

`local-exec` runs `gcloud`, `kubectl` and `flux` commands.
