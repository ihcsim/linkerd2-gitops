KIND_CLUSTER_NAME ?= linkerd
KIND_KUBECONFIG ?= /home/isim/.kube/config

PROJECT_REPO := https://github.com/ihcsim/linkerd2-gitops.git

ARGOCD_NAMESPACE ?= argocd
ARGOCD_ADMIN_ACCOUNT ?= admin
ARGOCD_ADMIN_PASSWORD ?=

CERT_MANAGER_NAMESPACE ?= cert-manager
CERT_MANAGER_APP_NAME ?= cert-manager

EMOJIVOTO_APP_NAME ?= emojivoto
EMOJIVOTO_NAMESPACE ?= emojivoto

LINKERD_APP_NAME ?= linkerd
LINKERD_CHART_URL ?= linkerd/linkerd2
LINKERD_NAMESPACE ?= linkerd
LINKERD_PLUGIN_NAME ?= linkerd
LINKERD_PROJECT_NAME ?= linkerd

SEALED_SECRETS_APP_NAME ?= sealed-secrets
SEALED_SECRETS_NAMESPACE ?= kube-system

##############################
########### Kind #############
##############################
kind:
	kind create cluster --name "${KIND_CLUSTER_NAME}"
	kubectl --context="kind-${KIND_CLUSTER_NAME}" cluster-info

##############################
########## Argo CD ###########
##############################
.PHONY: argocd
argocd:
	kubectl --context="kind-${KIND_CLUSTER_NAME}" create namespace "${ARGOCD_NAMESPACE}"
	kubectl --context="kind-${KIND_CLUSTER_NAME}" -n "${ARGOCD_NAMESPACE}" apply -f ./argocd

argocd-port-forward:
	kubectl --context="kind-${KIND_CLUSTER_NAME}" -n "${ARGOCD_NAMESPACE}" \
		port-forward svc/argocd-server 8080:443  > /dev/null 2>&1 &

argocd-login:
	argocd login 127.0.0.1:8080 \
		--username="${ARGOCD_ADMIN_ACCOUNT}" \
		--password="`kubectl -n ${ARGOCD_NAMESPACE} get pods -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2`" \
		--insecure

argocd-update-password:
	argocd account update-password --account="${ARGOCD_ADMIN_ACCOUNT}" --current-password="$(shell kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2)" --new-password="${ARGOCD_ADMIN_PASSWORD}"

argocd-dashboard:
	@echo "ArgoCD dashboard URL: https://localhost:8080/"

###################################
######### Target Cluster ##########
###################################
target-cluster:
	@test -n "${TARGET_CLUSTER_NAME}" || (echo 'Missing variable: TARGET_CLUSTER_NAME'; exit 1)

	argocd cluster add "${TARGET_CLUSTER_NAME}"
	argocd cluster list

##############################
######### Project ############
##############################
linkerd-project:
	@test -n "${TARGET_CLUSTER_NAME}" || (echo 'Missing variable: TARGET_CLUSTER_NAME'; exit 1)

	TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="${TARGET_CLUSTER_NAME}") | .server'` ; \
	argocd proj create "${LINKERD_PROJECT_NAME}" \
		-d "$${TARGET_ENDPOINT}","${CERT_MANAGER_NAMESPACE}" \
		-d "$${TARGET_ENDPOINT}","${EMOJIVOTO_NAMESPACE}" \
		-d "$${TARGET_ENDPOINT}",kube-system \
		-d "$${TARGET_ENDPOINT}","${LINKERD_NAMESPACE}" \
		-s "${PROJECT_REPO}"
	argocd proj get "${LINKERD_PROJECT_NAME}"

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
.PHONY: cert-manager
cert-manager:
	@test -n "${TARGET_CLUSTER_NAME}" || (echo 'Missing variable: TARGET_CLUSTER_NAME'; exit 1)

	TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="${TARGET_CLUSTER_NAME}") | .server'` ; \
	argocd app create "${CERT_MANAGER_APP_NAME}" \
	 --dest-namespace "${CERT_MANAGER_NAMESPACE}" \
	 --dest-server "$${TARGET_ENDPOINT}" \
	 --path ./cert-manager \
	 --project "${LINKERD_PROJECT_NAME}" \
	 --repo "${PROJECT_REPO}"

cert-manager-sync:
	argocd app sync "${CERT_MANAGER_APP_NAME}"

cert-manager-check:
	kubectl --context="${TARGET_CONTEXT}" -n ${CERT_MANAGER_NAMESPACE} get po

#######################################
############ Sealed Secrets ###########
#######################################
.PHONY: sealed-secrets
sealed-secrets:
	@test -n "${TARGET_CLUSTER_NAME}" || (echo 'Missing variable: TARGET_CLUSTER_NAME'; exit 1)

	TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="${TARGET_CLUSTER_NAME}") | .server'` ; \
	argocd app create "${SEALED_SECRETS_APP_NAME}" \
	 --dest-namespace "${SEALED_SECRETS_NAMESPACE}" \
	 --dest-server "$${TARGET_ENDPOINT}" \
	 --path ./sealed-secrets \
	 --project "${LINKERD_PROJECT_NAME}" \
	 --repo "${PROJECT_REPO}"

sealed-secrets-sync:
	argocd app sync "${SEALED_SECRETS_APP_NAME}"

##############################
########## Linkerd ###########
##############################
linkerd-pull:
	helm repo update
	rm -rf linkerd/linkerd2
	helm pull linkerd/linkerd2 -d ./linkerd --untar

linkerd-tls:
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

linkerd-encrypted-trust-anchor:
	@test -n "${TARGET_CONTEXT}" || (echo 'Missing variable: TARGET_CONTEXT'; exit 1)

	kubectl -n linkerd create secret tls linkerd-trust-anchor \
		--cert linkerd/tls/sample-trust.crt \
		--key linkerd/tls/sample-trust.key \
		--dry-run=client -oyaml | kubeseal --context="${TARGET_CONTEXT}" -oyaml - > linkerd/tls/encrypted.yaml

	SECRET="`cat linkerd/tls/encrypted.yaml`" ; echo "$${SECRET}" | kubectl patch -f - -p '{"spec": {"template": {"type":"kubernetes.io/tls", "metadata": {"labels": {"linkerd.io/control-plane-component":"identity", "linkerd.io/control-plane-ns":"linkerd"}, "annotations": {"linkerd.io/created-by":"linkerd/cli stable-2.8.1", "linkerd.io/identity-issuer-expiry":"2021-07-19T20:51:01Z"}}}}}' --dry-run=client --type=merge --local -oyaml > linkerd/tls/encrypted.yaml

linkerd-bootstrap:
	kubectl --context="${TARGET_CONTEXT}" create namespace linkerd
	kubectl --context="${TARGET_CONTEXT}" apply -f linkerd/tls/encrypted.yaml

	TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="${TARGET_CLUSTER_NAME}") | .server'` ; \
	argocd app create "${LINKERD_PROJECT_NAME}-bootstrap" \
		--dest-namespace "${LINKERD_NAMESPACE}" \
		--dest-server "$${TARGET_ENDPOINT}" \
		--path ./linkerd/bootstrap \
		--project "${LINKERD_PROJECT_NAME}" \
		--repo "${PROJECT_REPO}"

linkerd-bootstrap-sync:
	argocd app sync "${LINKERD_PROJECT_NAME}"-bootstrap

.PHONY: linkerd
linkerd:
	TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="${TARGET_CLUSTER_NAME}") | .server'` ; \
	argocd app create "${LINKERD_APP_NAME}" \
		--dest-namespace "${LINKERD_NAMESPACE}" \
		--dest-server "$${TARGET_ENDPOINT}" \
		--helm-set global.identityTrustAnchorsPEM="`kubectl --context=${TARGET_CLUSTER_NAME} -n linkerd get secret linkerd-trust-anchor -ojsonpath="{.data['tls\.crt']}" | base64 -d -`" \
		--helm-set identity.issuer.scheme=kubernetes.io/tls \
		--helm-set installNamespace=false \
		--path ./linkerd/linkerd2 \
		--project "${LINKERD_PROJECT_NAME}" \
		--repo "${PROJECT_REPO}"

linkerd-sync:
	argocd app sync "${LINKERD_APP_NAME}"

linkerd-check:
	linkerd --context="${TARGET_CONTEXT}" check
	linkerd --context="${TARGET_CONTEXT}" check --proxy

##############################
######### Emojivoto ##########
##############################
.PHONY: emojivoto
emojivoto:
	TARGET_ENDPOINT=`argocd cluster list -ojson | jq -r '.[] | select(.name=="${TARGET_CLUSTER_NAME}") | .server'` ; \
	argocd app create "${EMOJIVOTO_APP_NAME}" \
		--dest-namespace "${EMOJIVOTO_NAMESPACE}" \
		--dest-server "$${TARGET_ENDPOINT}" \
		--path ./emojivoto \
		--project "${LINKERD_PROJECT_NAME}" \
		--repo "${PROJECT_REPO}"

emojivoto-sync:
	argocd app sync "${EMOJIVOTO_APP_NAME}"

##############################
########## Upgrade ###########
##############################
linkerd-upgrade-to-edge:
	helm repo update
	rm -rf ./linkerd/linkerd2
	helm pull linkerd-edge/linkerd2 -d ./linkerd --untar

##############################
########## Clean up ##########
##############################
cert-manager-uninstall:
	argocd app delete "${CERT_MANAGER_APP_NAME}" --cascade

linkerd-uninstall:
	argocd app delete "${LINKERD_APP_NAME}" --cascade

argocd-uninstall:
	kubectl delete ns "${ARGOCD_NAMESPACE}"

clean: linkerd-uninstall cert-manager-uninstall argocd-uninstall

purge:
	kind delete cluster --name "${KIND_CLUSTER_NAME}"
