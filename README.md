# Linkerd GitOps
This project contains scripts and instructions to manage
[Linkerd](https://linkerd.io) in a GitOps workflow, using
[Argo CD](https://argoproj.github.io/argo-cd/).

The scripts are tested with the following software:

1. [kind](https://kind.sigs.k8s.io/) v0.8.1
1. [Linkerd](https://linkerd.io/) 2.8.1
1. [Argo CD](https://argoproj.github.io/argo-cd/) v1.6.1

## Highlights

* Automate the Linkerd control plane install and upgrade lifecycle using Argo CD
* Incorporate Linkerd auto proxy injection feature into the GitOps workflow to
  auto mesh applications
* Securely store the mTLS trust anchor key/cert with offline encryption and
  runtime auto-decryption using sealed-secrets
* Let cert-manager manage the mTLS issuer key/cert assets
* Utilize Argo CD [projects](https://argoproj.github.io/argo-cd/user-guide/projects/)
  to manage bootstrap dependencies and limit access to servers, namespaces and
  resources
* Uses Argo CD
  [_app of apps_ pattern](https://argoproj.github.io/argo-cd/operator-manual/cluster-bootstrapping/#app-of-apps-pattern)
  to manage application declarative resources

## Getting Started

### Create local K8s cluster

Create a `kind` cluster named `linkerd`:

```sh
kind create cluster --name=linkerd
```

### Set up a Git server

Deploy the Git server to the `scm` namespace:

```sh
kubectl apply -f git-server.yaml
```

Confirm that the Git server is healthy:

```sh
kubectl -n scm rollout status deploy/git-server
```

> This runs the Git server as a [daemon](https://git-scm.com/book/en/v2/Git-on-the-Server-Git-Daemon)
> with unauthenticated access to the Git data, over the `git` protocol.
> This setup is not recommended for production usage.

Set up the remote repository. This is the repository that Argo CD will watch:

```sh
git_server=`kubectl -n scm get po -l app=git-server -oname | awk -F/ '{ print $2 }'`

kubectl -n scm exec "${git_server}" -- \
  git clone --bare https://github.com/ihcsim/linkerd2-gitops.git
```

Confirm that the remote repository is cloned successfully:

```sh
kubectl -n scm exec "${git_server}" -- ls -al /git/linkerd2-gitops.git
```

Clone a local copy of the example repository. In later steps, changes will be
made to this repository, and will be pushed to the remote in-cluster repository.

```sh
git clone https://github.com/ihcsim/linkerd2-gitops.git
```

Update the local repo with a remote that points to the Git server:

```sh
git remote add git-server git://localhost/linkerd2-gitops.git
```

Make sure that push works via port-forwarding:

```sh
kubectl -n scm port-forward "${git_server}" 9418  &

cd ./linkerd2-gitopts

git push git-server main
```

### Deploy Argo CD 1.6.1

Install Argo CD:

```sh
kubectl create ns argocd

kubectl -n argocd apply -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v1.6.1/manifests/install.yaml
```

Confirm that all the pods are ready:

```sh
for deploy in "application-controller" "dex-server" "redis" "repo-server" "server"; \
  do kubectl -n argocd rollout status deploy/argocd-${deploy}; \
done
```

Use port-forward to access the Argo CD dashboard:

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:443  \
  > /dev/null 2>&1 &
```

The Argo CD dashboard is now accessible at https://localhost:8080/, using the
default `admin` username and
[password](https://argoproj.github.io/argo-cd/getting_started/#4-login-using-the-cli).

> The default admin password is the auto-generated name of the Argo CD API
> server pod. You can use the `argocd account update-password` command to
> change it.

Authenticte the Argo CD CLI:

```sh
argocd_server=`kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2`

argocd login 127.0.0.1:8080 \
  --username=admin \
  --password="${argocd_server}" \
  --insecure
```

#### Configure project access and permissions

Set up the `demo` project with the list of allowed cluster-scoped RBAC and
remote repositories:

```sh
cat<<EOF > ./project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: demo
  namespace: argocd
spec:
  clusterResourceWhitelist:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
  - group: apiregistration.k8s.io
    kind: APIService
  - group: ""
    kind: Namespace
  - group: policy
    kind: PodSecurityPolicy
  - group: rbac.authorization.k8s.io
    kind: ClusterRole
  - group: rbac.authorization.k8s.io
    kind: ClusterRoleBinding
  destinations:
  - namespace: cert-manager
    server: https://kubernetes.default.svc
  - namespace: emojivoto
    server: https://kubernetes.default.svc
  - namespace: kube-system
    server: https://kubernetes.default.svc
  - namespace: linkerd
    server: https://kubernetes.default.svc
  sourceRepos:
  - https://charts.jetstack.io
  - https://github.com/ihcsim/linkerd2-gitops.git
  - https://helm.linkerd.io/stable
  - https://kubernetes-charts.storage.googleapis.com
EOF

kubectl apply -f ./project.yaml
```

> The `demo` project is restricted to deploying resources to the same cluster
> that Argo CD is on. To register separate remote clusters, use the
> `argocd cluster add` command.

Confirm that the project is deployed correctly:

```sh
argocd proj get demo
```

On the dashboard:

![New project in dashboard](img/dashboard-project.png)

### Deploy cert-manager 0.15.0

Create the [cert-manager](https://cert-manager.io/docs/)
[application](https://argoproj.github.io/argo-cd/operator-manual/declarative-setup/#applications):

```sh
cat<<EOF > ./cert-manager.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: demo
  source:
    chart: cert-manager
    repoURL: https://charts.jetstack.io
    targetRevision: v0.15.0
    helm:
      parameters:
      - name: installCRDs
        value: "true"
  destination:
    namespace: cert-manager
    server: https://kubernetes.default.svc
  syncPolicy:
    syncOptions:
    - Validate=false
  ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jsonPointers:
    - /status
EOF

kubectl apply -f ./cert-manager.yaml

argocd app sync cert-manager
```

> Can't use cert-manager v0.16.0 with kubectl <1.19 and Helm 3.2
> See https://cert-manager.io/docs/installation/upgrading/upgrading-0.15-0.16/#helm

Confirm that cert-manager is running:

```sh
for deploy in "cert-manager" "cert-manager-cainjector" "cert-manager-webhook"; \
  do kubectl -n cert-manager rollout status deploy/${deploy}; \
done
```

### Deploy sealed-secrets 0.12.4

Deploy the [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets)
application:

```sh
cat<<EOF > ./sealed-secrets.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
spec:
  destination:
    namespace: kube-system
    server: https://kubernetes.default.svc
  project: demo
  source:
    chart: sealed-secrets
    repoURL: https://kubernetes-charts.storage.googleapis.com
    targetRevision: 1.10.3
EOF

kubectl apply -f ./sealed-secrets.yaml

argocd app sync sealed-secrets
```

Confirm that sealed-secrets is running:

```sh
kubectl -n kube-system rollout status deploy/sealed-secrets
```

Commit the `sealed-secrets` YAML file to Git:

```sh
git add ./sealed-secrets.yaml && \
git commit -m "add sealed-secrets 0.12.4 YAML" && \
git push
```

### Prepare the Linkerd mTLS trust anchor

Create and encrypt the mTLS trust anchor offline:

```sh
mkdir linkerd

cat<<EOF > ./linkerd/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: linkerd
EOF

step certificate create identity.linkerd.cluster.local ./linkerd/sample-trust.crt ./linkerd/sample-trust.key \
  --profile root-ca \
  --no-password \
  --insecure

kubectl -n linkerd create secret tls linkerd-trust-anchor \
  --cert ./linkerd/sample-trust.crt \
  --key ./linkerd/sample-trust.key \
  --dry-run=client -oyaml | \
kubeseal --controller-name=sealed-secrets -oyaml - | \
kubectl patch -f - \
  -p '{"spec": {"template": {"type":"kubernetes.io/tls", "metadata": {"labels": {"linkerd.io/control-plane-component":"identity", "linkerd.io/control-plane-ns":"linkerd"}, "annotations": {"linkerd.io/created-by":"linkerd/cli stable-2.8.1", "linkerd.io/identity-issuer-expiry":"2021-07-19T20:51:01Z"}}}}}' \
  --dry-run=client \
  --type=merge \
  --local -oyaml > ./linkerd/trust-anchor.yaml
```

Prepare the `Issuer` resources YAML:

```sh
cat <<EOF > ./linkerd/trust-issuer.yaml
apiVersion: cert-manager.io/v1alpha2
kind: Issuer
metadata:
  name: linkerd-trust-anchor
  namespace: linkerd
spec:
  ca:
    secretName: linkerd-trust-anchor
---
apiVersion: cert-manager.io/v1alpha2
kind: Certificate
metadata:
  name: linkerd-identity-issuer
  namespace: linkerd
spec:
  secretName: linkerd-identity-issuer
  duration: 24h0m0s
  renewBefore: 1h0m0s
  issuerRef:
    name: linkerd-trust-anchor
    kind: Issuer
  commonName: identity.linkerd.cluster.local
  isCA: true
  keyAlgorithm: ecdsa
  usages:
  - cert sign
  - crl sign
  - server auth
  - client auth
EOF
```

Commit the Linkerd bootstrap resources to Git:

```sh
git add ./linkerd && \
git commit -m "add Linkerd bootstrap resources" && \
git push
```

> Every time the encrypted trust anchor is changed, its YAML must be committed
> to git before sync-ing the `linkerd-bootstrap` application. The
> sealed-secrets operator will always use the trust anchor in the scm.

Create the `linkerd-bootstrap` application:

```sh
cat<<EOF > ./linkerd-bootstrap.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: linkerd-bootstrap
  namespace: argocd
spec:
  destination:
    namespace: linkerd
    server: https://kubernetes.default.svc
  project: demo
  source:
    path: ./linkerd
    repoURL: https://github.com/ihcsim/linkerd2-gitops.git
EOF

kubectl apply -f ./linkerd-bootstrap.yaml

argocd app sync linkerd-bootstrap
```

> If the issuer and certificate resources appear in a degraded state, it's
> likely that the sealed-secrets controller failed to decrypt the sealed trust
> anchor. Check the sealed-secrets controller for error logs.

Confirm that all the mTLS secrets are created:

```sh
kubectl -n linkerd get secret,issuer,certificates
```

Create the `linkerd` application:

```sh
cat<<EOF > ./linkerd.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: linkerd
  namespace: argocd
spec:
  project: demo
  source:
    chart: linkerd2
    repoURL: https://helm.linkerd.io/stable
    targetRevision: 2.8.0
    helm:
      parameters:
      - name: global.identityTrustAnchorsPEM
        value: |
`kubectl -n linkerd get secret linkerd-trust-anchor -ojsonpath="{.data['tls\.crt']}" | base64 -d -w 0 - | sed 's/^/          /' -`
      - name: identity.issuer.scheme
        value: kubernetes.io/tls
      - name: installNamespace
        value: "false"
  destination:
    namespace: linkerd
    server: https://kubernetes.default.svc
EOF

kubectl apply -f ./linkerd.yaml

argocd app sync linkerd
```

Check that Linkerd is ready:

```sh
linkerd check

linkerd check --proxy
```

Commit the `linkerd` YAML files to Git:

```sh
git add ./linkerd-bootstrap.yaml ./linkerd.yaml && \
git commit -m "add Linkerd 2.8.0 YAML" && \
git push
```

### Test with emojivoto

Download the emojivoto YAML:

```sh
curl -Ls https://run.linkerd.io/emojivoto.yml > ./emojivoto/deploy.yaml
```

Commit the `emojivoto` resources to Git:

```sh
git add ./emojivoto && \
git commit -m "add emojivoto resources" && \
git push
```

Deploy emojivoto to test auto proxy injection:

```sh
cat<<EOF > ./emojivoto.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: emojivoto
  namespace: argocd
spec:
  project: demo
  source:
    path: ./emojivoto
    repoURL: https://github.com/ihcsim/linkerd2-gitops
  destination:
    namespace: emojivoto
    server: https://kubernetes.default.svc
EOF

kubectl apply -f emojivoto.yaml

argocd app sync emojivoto
```

Check that the applications are healthy:

```sh
for deploy in "emoji" "vote-bot" "voting" "web" ; \
  do kubectl -n emojivoto rollout status deploy/${deploy}; \
done
```

Commit the `emojivoto` YAML to Git:

```sh
git add ./emojivoto.yaml && \
git commit -m "add emojivoto YAML" && \
git push
```

### Upgrade Linkerd to 2.8.1

Upgrade the Linkerd version to 2.8.1:

```sh
cat<<EOF > ./linkerd.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: linkerd
  namespace: argocd
spec:
  project: demo
  source:
    chart: linkerd2
    repoURL: https://helm.linkerd.io/stable
    targetRevision: 2.8.1
    helm:
      parameters:
      - name: global.identityTrustAnchorsPEM
        value: |
`kubectl -n linkerd get secret linkerd-trust-anchor -ojsonpath="{.data['tls\.crt']}" | base64 -d -w 0 - | sed 's/^/          /' -`
      - name: identity.issuer.scheme
        value: kubernetes.io/tls
      - name: installNamespace
        value: "false"
  destination:
    namespace: linkerd
    server: https://kubernetes.default.svc
EOF

kubectl apply -f ./linkerd.yaml
```

Upgrade Linkerd using the Argo CD `sync` command:

```sh
argocd app sync linkerd

linkerd version

linkerd check

linkerd check --proxy
```

Commit the version change to Git:

```sh
git add ./linkerd.yaml && \
git commit -m "upgrade Linkerd to 2.8.1" && \
git push
```
