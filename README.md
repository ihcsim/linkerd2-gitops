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

* Version control Linkerd control plane YAML so that you have full visibility
  into the workloads and changes between versions
* Let Argo CD manage Linkerd control plane lifecycle by synchronizing your
  live workloads with your version control system (i.e. single source of truth)
    * Showcase how the upgrade workflow is made easy
* Define Argo CD _projects_ to manage bootstrap dependencies
    * Projects are also used to limit access to servers, namespaces and
      resources
* Use sealed-secrets to manage the encryption and auto-decryption of the mTLS
  trust anchor
* Let cert-manager manage the mTLS issuer key/cert lifecycle
* Utilize Linkerd auto proxy injection feature to add applications to the mesh
  in a GitOps workflow

Why Argo CD?

* Can handle multiple repositories
* Extensiblity via [plugins](https://argoproj.github.io/argo-cd/user-guide/config-management-plugins/)
* More common among Linkerd community members
