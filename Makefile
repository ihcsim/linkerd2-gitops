KIND_KUBECONFIG ?= /home/isim/.kube/config

PROJECT_REPO := https://github.com/ihcsim/linkerd2-gitops.git
K8S_URL ?= https://kubernetes.default.svc

KUBE_SYSTEM_NAMESPACE ?= "kube-system" # for cert-manager

ARGOCD_NAMESPACE ?= argocd
ARGOCD_ADMIN_ACCOUNT ?= admin
ARGOCD_ADMIN_PASSWORD ?=

CERT_MANAGER_NAMESPACE ?= cert-manager
CERT_MANAGER_PROJECT_NAME ?= cert-manager

LINKERD_CHART_FILE ?= ./linkerd/manual-mtls/install.yaml
LINKERD_CHART_URL ?= linkerd/linkerd2
LINKERD_NAMESPACE ?= linkerd
LINKERD_PROJECT_NAME ?= linkerd

##############################
########### Kind #############
##############################
kind:
	kind create cluster --name "${KIND_CLUSTER_NAME}"
	kind get kubeconfig --name="${KIND_CLUSTER_NAME}" > "${KIND_KUBECONFIG}"
	KUBECONFIG="${KIND_KUBECONFIG}" \
		kubectl cluster-info

##############################
########## Argo CD ###########
##############################
argocd-install:
	KUBECONFIG="${KIND_KUBECONFIG}" \
	kubectl create namespace "${ARGOCD_NAMESPACE}"

	KUBECONFIG="${KIND_KUBECONFIG}" \
	kubectl -n "${ARGOCD_NAMESPACE}" apply -f ./argocd

argocd-port-forward:
	KUBECONFIG="${KIND_KUBECONFIG}" \
	kubectl -n "${ARGOCD_NAMESPACE}" \
		port-forward svc/argocd-server 8080:443  > /dev/null 2>&1 &

argocd-login:
	KUBECONFIG="${KIND_KUBECONFIG}" \
	argocd login 127.0.0.1:8080 \
		--username="${ARGOCD_ADMIN_ACCOUNT}" \
		--password="`kubectl -n ${ARGOCD_NAMESPACE} get pods -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2`" \
		--insecure

argocd-update-password:
	argocd account update-password --account="${ARGOCD_ADMIN_ACCOUNT}" --current-password="$(shell kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2)" --new-password="${ARGOCD_ADMIN_PASSWORD}"

argocd-dashboard:
	@echo "ArgoCD dashboard URL: https://localhost:8080/"

##############################
######### Project ############
##############################
linkerd-project:
	argocd proj create "${LINKERD_PROJECT_NAME}" \
		-d https://kubernetes.default.svc,"${KUBE_SYSTEM_NAMESPACE}" \ # for cert-manager \
		-d https://kubernetes.default.svc,"${LINKERD_NAMESPACE}" \
		-d https://kubernetes.default.svc,"${CERT_MANAGER_NAMESPACE}" \
		-s "${PROJECT_REPO}"

linkerd-project-rbac:
	argocd proj allow-cluster-resource "${LINKERD_PROJECT_NAME}" \
		admissionregistration.k8s.io MutatingWebhookConfiguration

	argocd proj allow-cluster-resource "${LINKERD_PROJECT_NAME}" \
		admissionregistration.k8s.io ValidatingWebhookConfiguration

	argocd proj allow-cluster-resource "${LINKERD_PROJECT_NAME}" \
		apiextensions.k8s.io CustomResourceDefinition

	argocd proj allow-cluster-resource "${LINKERD_PROJECT_NAME}" \
	  apiregistration.k8s.io APIService

	argocd proj allow-cluster-resource "${LINKERD_PROJECT_NAME}" \
		'' Namespace

	argocd proj allow-cluster-resource "${LINKERD_PROJECT_NAME}" \
		policy PodSecurityPolicy

	argocd proj allow-cluster-resource "${LINKERD_PROJECT_NAME}" \
		rbac.authorization.k8s.io ClusterRole

	argocd proj allow-cluster-resource "${LINKERD_PROJECT_NAME}" \
		rbac.authorization.k8s.io ClusterRoleBinding

##############################
######## CertManager #########
##############################
cert-manager-create:
	argocd app create "${CERT_MANAGER_PROJECT_NAME}" \
	 --dest-namespace "${CERT_MANAGER_NAMESPACE}" \
	 --dest-server "${K8S_URL}" \
	 --path ./cert-manager \
	 --project "${LINKERD_PROJECT_NAME}" \
	 --repo "${PROJECT_REPO}"

cert-manager-sync:
	argocd app sync "${CERT_MANAGER_PROJECT_NAME}"

cert-manager-check:
	kubectl -n ${CERT_MANAGER_NAMESPACE} get po

##############################
########## Linkerd ###########
##############################
linkerd-tls:
	rm -f linkerd/manual-mtls/tls/*.crt linkerd/manual-mtls/tls/*.key
	step certificate create identity.linkerd.cluster.local linkerd/manual-mtls/tls/sample-trust.crt linkerd/manual-mtls/sample-trust.key \
		--profile root-ca \
		--no-password \
		--insecure
	step certificate create identity.linkerd.cluster.local linkerd/manual-mtls/tls/sample-issuer.crt linkerd/manual-mtls/tls/sample-issuer.key \
		--ca linkerd/manual-mtls/tls/sample-trust.crt \
		--ca-key linkerd/manual-mtls/tls/sample-trust.key \
		--profile intermediate-ca \
		--not-after 8760h \
		--no-password \
		--insecure

linkerd-template:
	helm repo update
	helm template "${LINKERD_PROJECT_NAME}" "${LINKERD_CHART_URL}" \
		-n "${LINKERD_NAMESPACE}" \
		--set-file global.identityTrustAnchorsPEM=./linkerd/manual-tls/tls/sample-trust.crt \
		--set identity.issuer.scheme=kubernetes.io/tls > "${LINKERD_CHART_FILE}"

linkerd-create:
	argocd app create "${LINKERD_PROJECT_NAME}" \
		--dest-namespace "${LINKERD_NAMESPACE}" \
		--dest-server "${K8S_URL}" \
		--path ./linkerd \
		--project "${LINKERD_PROJECT_NAME}" \
		--repo "${PROJECT_REPO}"

linkerd-sync:
	argocd app sync "${LINKERD_PROJECT_NAME}"

linkerd-test:
	linkerd check
	linkerd inject https://run.linkerd.io/emojivoto.yml | kubectl apply -f -
	linkerd check --proxy

##############################
######## Linkerd Helm ########
##############################
linkerd-pull:
	helm repo update
	rm -rf linkerd/auto-mtls
	helm pull linkerd/linkerd2 -d linkerd/auto-mtls --untar

argocd-install-with-plugin:
	KUBECONFIG="${KIND_KUBECONFIG}" \
	kubectl create namespace "${ARGOCD_NAMESPACE}"

	KUBECONFIG="${KIND_KUBECONFIG}" \
	kubectl -n "${ARGOCD_NAMESPACE}" apply -k ./argocd

linkerd-create-with-plugin:
	argocd app create "${LINKERD_PROJECT_NAME}" \
		--config-management-plugin "${LINKERD_PROJECT_NAME}" \
		--dest-namespace "${LINKERD_NAMESPACE}" \
		--dest-server "${K8S_URL}" \
		--path ./linkerd \
		--project "${LINKERD_PROJECT_NAME}" \
		--repo "${PROJECT_REPO}"

##############################
########## Clean up ##########
##############################
cert-manager-uninstall:
	argocd app delete "${CERT_MANAGER_PROJECT_NAME}" --cascade

linkerd-uninstall:
	argocd app delete "${LINKERD_PROJECT_NAME}" --cascade

argocd-uninstall:
	kubectl delete ns "${ARGOCD_NAMESPACE}"

clean: linkerd-uninstall cert-manager-uninstall argocd-uninstall

purge:
	kind delete cluster --name "${KIND_CLUSTER_NAME}"
