# VERSION defines the project version for the bundle.
# Update this value when you upgrade the version of your project.
# To re-generate a bundle for another specific version without changing the standard setup, you can:
# - use the VERSION as arg of the bundle target (e.g make bundle VERSION=0.0.2)
# - use environment variables to overwrite this value (e.g export VERSION=0.0.2)
VERSION ?= 0.0.1

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "preview,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=preview,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="preview,fast,stable")
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)


KUBE_RBAC_PROXY_IMAGE ?= registry.redhat.io/openshift4/ose-kube-rbac-proxy@sha256:f85766573467db25a9e12ee1f75a8315b15a775c76da55e84a36602bca5a1d33

# OPERATOR_IMAGE_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle and catalog images.
#
# For example, running 'make bundle-build bundle-push catalog-build catalog-push' will build and push both
# quay.io/prismacloud/pcc-operator-bundle:$VERSION and quay.io/prismacloud/pcc-operator-catalog:$VERSION.
OPERATOR_IMAGE_BASE ?= quay.io/prismacloud/pcc-operator

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(OPERATOR_IMAGE_BASE)-bundle:v$(VERSION)

# Image URL to use all building/pushing image targets
IMG ?= $(OPERATOR_IMAGE_BASE):v$(VERSION)

all: docker-build


# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php
help:
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)


## Run against the configured Kubernetes cluster in ~/.kube/config
run: ansible-operator
	$(ANSIBLE_OPERATOR) run

# Build operator image
docker-build:
	docker build -t $(IMG) --build-arg VERSION=v$(VERSION) .

# Push operator image
docker-push:
	docker push $(IMG)


## Deploy to cluster specified in ~/.kube/config
install: kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

uninstall: kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

deploy: kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/deploy | kubectl apply -f -

undeploy:
	$(KUSTOMIZE) build config/deploy | kubectl delete -f -


.PHONY: manifests
manifests: kustomize docker-build docker-push
	operator-sdk generate kustomize manifests -q
	repo_digest=$$(docker inspect --format '{{ .RepoDigests }}' $(IMG) | grep -Eo 'quay.io/prismacloud/pcc-operator@sha256:\w{64}') \
	&& gsed -i -E \
	  -e "s quay.io\/prismacloud\/pcc-operator((@sha256:\w{64})|(:[-._0-9A-Za-z]+))? $$repo_digest " \
	  -e "s registry.redhat.io\/openshift4\/ose-kube-rbac-proxy((@sha256:\w{64})|(:[-._0-9A-Za-z]+))? $(KUBE_RBAC_PROXY_IMAGE) " \
	  config/manifests/bases/pcc-operator.clusterserviceversion.yaml \
	&& cd config/manager && $(KUSTOMIZE) edit set image kube-rbac-proxy=$(KUBE_RBAC_PROXY_IMAGE) controller="$$repo_digest"

## Generate bundle manifests and metadata, then validate generated files.
## Note: this uses `gsed` (gnu-sed from Homebrew on macOS)
.PHONY: bundle
bundle: manifests
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

.PHONY: bundle-build
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push:
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)


# A comma-separated list of bundle images (e.g. make catalog-build BUNDLE_IMGS=example.com/operator-bundle:v0.1.0,example.com/operator-bundle:v0.2.0).
# These images MUST exist in a registry and be pull-able.
BUNDLE_IMGS ?= $(BUNDLE_IMG)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(OPERATOR_IMAGE_BASE)-catalog:v$(VERSION)

# Set CATALOG_BASE_IMG to an existing catalog image tag to add $BUNDLE_IMGS to that image.
ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

# Build a catalog image by adding bundle images to an empty catalog using the operator package manager tool, 'opm'.
# This recipe invokes 'opm' in 'semver' bundle add mode. For more information on add modes, see:
# https://github.com/operator-framework/community-operators/blob/7f1438c/docs/packaging-operator.md#updating-your-existing-operator
.PHONY: catalog-build
catalog-build: opm
	$(OPM) index add --container-tool docker --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

# Push the catalog image.
.PHONY: catalog-push
catalog-push:
	$(MAKE) docker-push IMG=$(CATALOG_IMG)


OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/')

## Download kustomize locally if necessary.
.PHONY: kustomize
KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize:
ifeq (,$(wildcard $(KUSTOMIZE)))
ifeq (,$(shell which kustomize 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(KUSTOMIZE)) ;\
	curl -sSLo - https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v3.5.4/kustomize_v3.5.4_$(OS)_$(ARCH).tar.gz | \
	tar xzf - -C bin/ ;\
	}
else
KUSTOMIZE = $(shell which kustomize)
endif
endif

## Download ansible-operator locally if necessary, preferring the $(pwd)/bin path over global if both exist.
.PHONY: ansible-operator
ANSIBLE_OPERATOR = $(shell pwd)/bin/ansible-operator
ansible-operator:
ifeq (,$(wildcard $(ANSIBLE_OPERATOR)))
ifeq (,$(shell which ansible-operator 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(ANSIBLE_OPERATOR)) ;\
	curl -sSLo $(ANSIBLE_OPERATOR) https://github.com/operator-framework/operator-sdk/releases/download/v1.8.1/ansible-operator_$(OS)_$(ARCH) ;\
	chmod +x $(ANSIBLE_OPERATOR) ;\
	}
else
ANSIBLE_OPERATOR = $(shell which ansible-operator)
endif
endif

## Download opm locally if necessary.
.PHONY: opm
OPM = ./bin/opm
opm:
ifeq (,$(wildcard $(OPM)))
ifeq (,$(shell which opm 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPM)) ;\
	curl -sSLo $(OPM) https://github.com/operator-framework/operator-registry/releases/download/v1.17.5/$(OS)-$(ARCH)-opm ;\
	chmod +x $(OPM) ;\
	}
else
OPM = $(shell which opm)
endif
endif