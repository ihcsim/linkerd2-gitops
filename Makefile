KIND_CLUSTER_NAME ?= linkerd
KIND_KUBECONFIG ?= /home/isim/.kube/config

PROJECT_REPO := https://github.com/ihcsim/linkerd2-gitops.git
K8S_URL ?= https://kubernetes.default.svc

KUBE_SYSTEM_NAMESPACE ?= kube-system

ARGOCD_NAMESPACE ?= argocd
ARGOCD_ADMIN_ACCOUNT ?= admin
ARGOCD_ADMIN_PASSWORD ?=

CERT_MANAGER_NAMESPACE ?= cert-manager
CERT_MANAGER_PROJECT_NAME ?= cert-manager

LINKERD_CHART_URL ?= linkerd/linkerd2
LINKERD_NAMESPACE ?= linkerd
LINKERD_PLUGIN_NAME ?= linkerd
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
argocd:
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
		-d https://kubernetes.default.svc,"${KUBE_SYSTEM_NAMESPACE}" \
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
cert-manager:
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
linkerd-pull:
	helm repo update
	rm -rf linkerd/linkerd2
	helm pull linkerd/linkerd2 -d ./linkerd --untar

linkerd-mtls-bootstrap:
	argocd app create "${LINKERD_PROJECT_NAME}-bootstrap" \
		--dest-namespace "${LINKERD_NAMESPACE}" \
		--dest-server "${K8S_URL}" \
		--path ./linkerd/bootstrap \
		--project "${LINKERD_PROJECT_NAME}" \
		--repo "${PROJECT_REPO}"

linkerd-mtls-bootstrap-sync:
	argocd app sync "${LINKERD_PROJECT_NAME}"-bootstrap

.PHONY: linkerd
linkerd:
	argocd app create "${LINKERD_PROJECT_NAME}" \
		--dest-namespace "${LINKERD_NAMESPACE}" \
		--dest-server "${K8S_URL}" \
		--helm-set global.identityTrustAnchorsPEM="`kubectl -n linkerd get secret linkerd-trust-anchor -ojsonpath="{.data['ca\.crt']}" | base64 -d -`" \
		--helm-set identity.issuer.scheme=kubernetes.io/tls \
		--helm-set installNamespace=false \
		--path ./linkerd/linkerd2 \
		--project "${LINKERD_PROJECT_NAME}" \
		--repo "${PROJECT_REPO}"

linkerd-sync:
	argocd app sync "${LINKERD_PROJECT_NAME}"

linkerd-test:
	linkerd check
	linkerd inject https://run.linkerd.io/emojivoto.yml | kubectl apply -f -
	linkerd check --proxy

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
