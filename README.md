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
* Define a Argo CD _project_ to limit deployment permissions to selected servers
  , namespaces and resources
* Let cert-manager manage the mTLS issuer secret to eliminate manual steps to
  manage the issuer certificates and privte keys

Why Argo CD?

* Can handle multiple repositories
* Extensiblity via [plugins](https://argoproj.github.io/argo-cd/user-guide/config-management-plugins/)
* More common among Linkerd community members
