# Linkerd GitOps
This project contains scripts and instructions to manage
[Linkerd](https://linkerd.io) in a GitOps workflow, using
[Argo CD](https://argoproj.github.io/argo-cd/).

The scripts are tested with the following software:

1. Kubernetes v1.18.0
  1. kubectl v1.18.0
1. Linkerd 2.8.1
1. Argo CD v1.6.1+159674e

Highlights:

* Let Argo CD manage Linkerd control plane install and upgrade lifecycle
* Use Argo CD _projects_ to manage bootstrap dependencies and limit access to
  servers, namespaces and resources
* Use sealed-secrets to encrypt and auto-decrypt the mTLS trust anchor
* Let cert-manager manage the mTLS issuer key/cert assets
* Utilize Linkerd auto proxy injection in a GitOps workflow to auto mesh
  applications

Why Argo CD?

* Can handle multiple repositories
* Extensiblity via [plugins](https://argoproj.github.io/argo-cd/user-guide/config-management-plugins/)
* More common among Linkerd community members
