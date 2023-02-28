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

## Shutdown

```sh
flux suspend ks all
flux suspend source oci --all
kubectl get ks -n flux-system --no-headers | grep -v -P '^(all|flux-system)' | while read name _rest; do echo kubectl delete ks $name -n flux-system --ignore-not-found; done | bash -ex
sleep 300
flux uninstall --keep-namespace=true --silent
terraform destroy
```

## Note

There is only a single Terraform file [`main.tf`](main.tf). The state should be
local because `local_file` resources are used for extra files generated:
OCIRepository and environment variables for Flux.

`local-exec` runs `gcloud`, `kubectl` and `flux` commands.

Setting up or shutting down the External HTTP LB takes about 5 minutes.
