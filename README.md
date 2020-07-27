# Linkerd GitOps
This project contains scripts and instructions to manage
[Linkerd](https://linkerd.io) in a GitOps workflow, using
[Argo CD](https://argoproj.github.io/argo-cd/).

The scripts are tested with the following software:

1. Kubernetes v1.18.0
  1. kubectl v1.18.0
1. Linkerd 2.8.1
1. Argo CD v1.6.1+159674e

## Highlights

* Automate the Linkerd control plane install and upgrade lifecycle using Argo CD
* Incorporate Linkerd auto proxy injection into a GitOps workflow to auto mesh
  applications
* Separate control cluster from workload cluster
* Securely store the mTLS trust anchor key/cert with offline encryption and
  real time auto-decryption using sealed-secrets
* Utilize Argo CD _projects_ to manage bootstrap dependencies and limit access
  to servers, namespaces and resources
* Let cert-manager manage the mTLS issuer key/cert assets

## Getting Started

### Create the control cluster
Create a KinD cluster named `linkerd`:

```sh
kind create cluster --name=linkerd
```

This is the cluster where Argo CD will be deployed.

Install Argo CD:

```sh
kubectl --context=kind-linkerd create namespace argocd
kubectl --context=kind-linkerd -n argocd apply -f ./argocd
```

Use port-forward to access the Argo CD dashboard:

```sh
kubectl --context=kind-linkerd -n argocd \
  port-forward svc/argocd-server 8080:443  > /dev/null 2>&1 &
```

Log in to Argo CD to change the default `admin` password:

```sh
argocd login 127.0.0.1:8080 \
  --username=admin \
  --password="`kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2`" \
  --insecure

argocd account update-password --account=admin --current-password="$(shell kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2)" --new-password=some-new-password
```

The Argo CD dashboard is now accessible at https://localhost:8080/ using the
new `admin` password.

### Configure project access and permissions

Add the `k8s-remote` cluster access configuration to Argo CD. The `k8s-remote`
cluster is where Linkerd and other applications will be deployed. The context of
this cluster must be defined in your active kubeconfig.

```sh
argocd cluster add k8s-remote

argocd cluster list
```

Set up the `linkerd` project:

```sh
TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="k8s-remote") | .server'`
argocd proj create linkerd \
  -d "${TARGET_ENDPOINT}",cert-manager \
  -d "${TARGET_ENDPOINT}",emojivoto \
  -d "${TARGET_ENDPOINT}",kube-system \ # default for sealed-secrets
  -d "${TARGET_ENDPOINT}",linkerd \
  -s "https://github.com/ihcsim/linkerd2-gitops.git"

argocd proj get linkerd
```

Configure the cluster-wide RBAC for the `linkerd` project:

```sh
argocd proj allow-cluster-resource linkerd \
  admissionregistration.k8s.io MutatingWebhookConfiguration

argocd proj allow-cluster-resource linkerd \
admissionregistration.k8s.io ValidatingWebhookConfiguration

argocd proj allow-cluster-resource linkerd \
  apiextensions.k8s.io CustomResourceDefinition

argocd proj allow-cluster-resource linkerd \
  apiregistration.k8s.io APIService

argocd proj allow-cluster-resource linkerd \
  '' Namespace

argocd proj allow-cluster-resource linkerd \
  policy PodSecurityPolicy

argocd proj allow-cluster-resource linkerd \
  rbac.authorization.k8s.io ClusterRole

argocd proj allow-cluster-resource linkerd \
  rbac.authorization.k8s.io ClusterRoleBinding
```

### Deploy the application workloads

Deploy and sync cert-manager:

```sh
TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="k8s-remote") | .server'`

argocd app create cert-manager \
  --dest-namespace cert-manager \
  --dest-server "${TARGET_ENDPOINT}" \
  --path ./cert-manager \
  --project linkerd \
  --repo https://github.com/ihcsim/linkerd2-gitops.git

argocd app sync cert-manager
```

Confirm that cert-manager is running:
```sh
kubectl --context=k8s-remote -n cert-manager get po
```

Deploy sealed-secrets:

```sh
TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="k8s-remote") | .server'`

argocd app create sealed-secrets \
  --dest-namespace sealed-secrets \
  --dest-server "${TARGET_ENDPOINT}" \
  --path ./sealed-secrets \
  --project linkerd \
  --repo https://github.com/ihcsim/linkerd2-gitops.git

argocd app sync sealed-secrets
```

Create and encrypt the mTLS trust anchor offline:

```sh
rm -f linkerd/tls/*.crt linkerd/tls/*.key

step certificate create identity.linkerd.cluster.local linkerd/tls/sample-trust.crt linkerd/tls/sample-trust.key \
  --profile root-ca \
  --no-password \
  --insecure

step certificate create identity.linkerd.cluster.local linkerd/tls/sample-issuer.crt linkerd/tls/sample-issuer.key \
  --ca linkerd/tls/sample-trust.crt \
  --ca-key linkerd/tls/sample-trust.key \
  --profile intermediate-ca \
  --not-after 8760h \
  --no-password \
  --insecure


kubectl -n linkerd create secret tls linkerd-trust-anchor \
  --cert linkerd/tls/sample-trust.crt \
  --key linkerd/tls/sample-trust.key \
  --dry-run=client -oyaml | \
    kubeseal --context=k8s-remote -oyaml - > \
      linkerd/tls/encrypted.yaml
```

Patch the encrypted secret with the Linkerd annotations and labels:
```sh
SECRET="`cat linkerd/tls/encrypted.yaml`" ; echo "$${SECRET}" | \
  kubectl patch -f - \
    -p '{"spec": {"template": {"type":"kubernetes.io/tls", "metadata": {"labels": {"linkerd.io/control-plane-component":"identity", "linkerd.io/control-plane-ns":"linkerd"}, "annotations": {"linkerd.io/created-by":"linkerd/cli stable-2.8.1", "linkerd.io/identity-issuer-expiry":"2021-07-19T20:51:01Z"}}}}}' \
    --dry-run=client \
    --type=merge \
    --local -oyaml > \
      linkerd/tls/encrypted.yaml
```

Retrieve and untar the Linked Helm chart:

```sh
helm repo update

rm -rf linkerd/linkerd2

helm pull linkerd/linkerd2 -d ./linkerd --untar
```

Create the `linkerd-bootstrap` application to pre-create the mTLS trust anchor
and issuer resources:

```sh
kubectl --context="${TARGET_CONTEXT}" create namespace linkerd

kubectl --context="${TARGET_CONTEXT}" apply -f linkerd/tls/encrypted.yaml

TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="k8s-remote") | .server'`

argocd app create "linkerd-bootstrap" \
  --dest-namespace linkerd \
  --dest-server "${TARGET_ENDPOINT}" \
  --path ./linkerd/bootstrap \
  --project linkerd \
  --repo https://github.com/ihcsim/linkerd2-gitops.git

argocd app sync linkerd-bootstrap
```

Confirm that all the mTLS secrets are created:

```sh
kubectl --context=k8s-remote -n linkerd get secret,issuer,certificates
```

Deploy Linkerd:

```sh
TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name==k8s-remote) | .server'`

argocd app create linkerd \
  --dest-namespace linkerd \
  --dest-server "${TARGET_ENDPOINT}" \
  --helm-set global.identityTrustAnchorsPEM="`kubectl --context=k8s-remote -n linkerd get secret linkerd-trust-anchor -ojsonpath="{.data['tls\.crt']}" | base64 -d -`" \
  --helm-set identity.issuer.scheme=kubernetes.io/tls \
  --helm-set installNamespace=false \
  --path ./linkerd/linkerd2 \
  --project linkerd \
  --repo https://github.com/ihcsim/linkerd2-gitops.git

argocd app sync "${LINKERD_APP_NAME}"

linkerd --context=k8s-remote check

linkerd --context=k8s-remote check --proxy
```

Deploy emojivoto to test auto proxy injection:
```sh
TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name==k8s-remote) | .server'`

argocd app create emojivoto \
  --dest-namespace emojivoto \
  --dest-server "${TARGET_ENDPOINT}" \
  --path ./emojivoto \
  --project linkerd \
  --repo https://github.com/ihcsim/linkerd2-gitops.git

argocd app sync emojivoto
```

### Upgrade Linkerd to newer version

Perform Linkerd upgrade:

```sh
helm repo update

rm -rf ./linkerd/linkerd2

helm pull linkerd-edge/linkerd2 -d ./linkerd --untar

argocd app sync linkerd

linkerd check

linkerd check --proxy
```
