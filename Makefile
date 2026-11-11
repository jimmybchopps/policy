# Pinned tool versions. CI reads these too; change them here only.
HELM_VERSION          ?= 4.3.1
HELM_MIN_VERSION      := 3.14.4
HELM3_LATEST_VERSION  := 3.22.1
HELM_UNITTEST_VERSION := 1.2.1
# helm-unittest 1.1.0+ uses plugin.yaml fields (platformHooks) that Helm 3.14 can't parse;
# 1.0.3 is the last release it loads.
HELM_UNITTEST_LEGACY_VERSION := 1.0.3
KUBECONFORM_VERSION   := 0.8.0
K3D_VERSION           := 5.9.0
KUBECTL_VERSION       := 1.37.2
# e2e (test/e2e/run.sh). 1.36+ so MutatingAdmissionPolicy is v1 (phase 3).
K3S_IMAGE             := rancher/k3s:v1.37.2-k3s1

# Every Helm version this chart supports; `make test-all-helm` runs the suite under each.
HELM_VERSIONS := $(HELM_MIN_VERSION) $(HELM3_LATEST_VERSION) $(HELM_VERSION)

CHART    := charts/policy
# Test-only chart that renders the chart's internal model so tests can assert on it.
PROBE    := test/model-probe
HAS_PROBE := $(wildcard $(PROBE)/Chart.yaml)
EXAMPLES := $(wildcard examples/*.yaml)
# Policy definitions, checked against the definition JSON schema (test/definition-schema), and
# deliberately broken ones the schema must reject.
DEFINITION_SCHEMA := test/definition-schema
DEFINITIONS       := $(wildcard $(CHART)/definitions/*/*.yaml)
BAD_DEFINITIONS   := $(wildcard $(DEFINITION_SCHEMA)/bad/*.yaml)
# Objects each policy must admit or refuse (phase 1e), the e2e fixtures, and example objects
# (examples/objects/), all validated with kubeconform. Files under an invalid/ folder must be
# rejected instead.
FIXTURES := $(shell find fixtures test/e2e/fixtures examples/objects -name '*.yaml' -not -path '*/invalid/*' 2>/dev/null | sort)
INVALID_FIXTURES := $(shell find fixtures test/e2e/fixtures -path '*/invalid/*.yaml' 2>/dev/null | sort)
CRDS_CATALOG := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
# The JSON schema for PolicyExceptions, generated from this chart's own CRD by `make crd-schema`
# (test/crd-schema), so objects validate against exactly the CRD this chart installs.
CRD         := $(CHART)/crd/policy.posture.dev_policyexceptions.yaml
SCHEMAS     := $(CURDIR)/.bin/schemas
CRD_SCHEMA  := $(SCHEMAS)/policy.posture.dev/policyexceptions_v1alpha1.json
LOCAL_SCHEMAS := -schema-location '$(SCHEMAS)/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# charts/policy/values.schema.json is generated from the definitions (test/values-schema) by
# `make values-schema`; check-values-schema fails if the committed file is stale.
VALUES_SCHEMA := $(CHART)/values.schema.json

OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

BIN       := $(CURDIR)/.bin
HELM_HOME := $(BIN)/helm-$(HELM_VERSION)
HELM      := $(HELM_HOME)/helm
KUBECONFORM := $(BIN)/kubeconform-$(KUBECONFORM_VERSION)
K3D       := $(BIN)/k3d-$(K3D_VERSION)
KUBECTL   := $(BIN)/kubectl-$(KUBECTL_VERSION)

# Each Helm version gets its own plugin, cache, config, and data directories, so Helm 3 and
# Helm 4 never share plugin installs.
export HELM_PLUGINS     := $(HELM_HOME)/plugins
export HELM_CACHE_HOME  := $(HELM_HOME)/cache
export HELM_CONFIG_HOME := $(HELM_HOME)/config
export HELM_DATA_HOME   := $(HELM_HOME)/data

UNITTEST_PLUGIN := $(HELM_PLUGINS)/helm-unittest
UNITTEST_VERSION := $(if $(filter 3.14.%,$(HELM_VERSION)),$(HELM_UNITTEST_LEGACY_VERSION),$(HELM_UNITTEST_VERSION))
# helm-unittest only reads tests/*_test.yaml by default; suites grouped in subfolders need both.
UNITTEST_FILES := -f 'tests/*_test.yaml' -f 'tests/*/*_test.yaml'

KUBECONFORM_ARGS := -strict -summary -schema-location default $(LOCAL_SCHEMAS) -schema-location '$(CRDS_CATALOG)'

.PHONY: help tools tools-e2e lint check-definitions check-fixtures check-values-schema values-schema unittest unittest-update crd-schema validate test test-all-helm e2e clean

help:
	@echo "make tools          install helm $(HELM_VERSION), helm-unittest, kubeconform into .bin/"
	@echo "make test           lint, check-definitions, check-fixtures, check-values-schema, unittest, validate"
	@echo "make values-schema  regenerate $(VALUES_SCHEMA) from the definitions"
	@echo "make test-all-helm  make test under Helm $(HELM_VERSIONS)"
	@echo "make e2e            k3d end-to-end tests (E2E_ARGS=<scenario>, E2E_KEEP=1, E2E_REUSE=1)"
	@echo "make unittest-update  regenerate example snapshots (review the diff)"
	@echo "HELM_VERSION=x.y.z selects the Helm version for any target."

tools: $(HELM) $(UNITTEST_PLUGIN) $(KUBECONFORM)

tools-e2e: $(K3D) $(KUBECTL)

$(HELM):
	mkdir -p $(HELM_HOME)
	curl -fsSL https://get.helm.sh/helm-v$(HELM_VERSION)-$(OS)-$(ARCH).tar.gz \
	  | tar -xz -C $(HELM_HOME) --strip-components=1 $(OS)-$(ARCH)/helm

# Helm 4 verifies plugin sources by default and helm-unittest isn't signed; Helm 3 has no
# --verify flag at all.
$(UNITTEST_PLUGIN): $(HELM)
	$(HELM) plugin install https://github.com/helm-unittest/helm-unittest \
	  --version $(UNITTEST_VERSION) \
	  $(if $(filter 4.%,$(HELM_VERSION)),--verify=false)

$(KUBECONFORM):
	mkdir -p $(BIN)
	curl -fsSL https://github.com/yannh/kubeconform/releases/download/v$(KUBECONFORM_VERSION)/kubeconform-$(OS)-$(ARCH).tar.gz \
	  | tar -xz -O kubeconform > $@
	chmod +x $@

$(K3D):
	mkdir -p $(BIN)
	curl -fsSL -o $@ https://github.com/k3d-io/k3d/releases/download/v$(K3D_VERSION)/k3d-$(OS)-$(ARCH)
	chmod +x $@

$(KUBECTL):
	mkdir -p $(BIN)
	curl -fsSL -o $@ https://dl.k8s.io/release/v$(KUBECTL_VERSION)/bin/$(OS)/$(ARCH)/kubectl
	chmod +x $@

# Linted through the examples only: with the default values the render fails by design (an
# empty policies.restrict-image-registries.registries), which tests/model_test.yaml asserts.
lint: $(HELM)
	@set -e; for f in $(EXAMPLES); do \
	  echo "==> helm lint --strict -f $$f"; \
	  $(HELM) lint --strict $(CHART) -f $$f; \
	done

# Every definition must pass the definition schema; every file in bad/ must fail it, and for a
# schema error (not some other lint problem), so the schema is known to reject things.
check-definitions: $(HELM)
	@set -e; for f in $(DEFINITIONS); do \
	  echo "==> definition schema: $$f"; \
	  $(HELM) lint --strict $(DEFINITION_SCHEMA) -f $$f >/dev/null \
	    || { $(HELM) lint --strict $(DEFINITION_SCHEMA) -f $$f; exit 1; }; \
	done
	@set -e; for f in $(BAD_DEFINITIONS); do \
	  if out=$$($(HELM) lint --strict $(DEFINITION_SCHEMA) -f $$f 2>&1); then \
	    echo "FAIL: $$f was accepted by the definition schema"; exit 1; \
	  fi; \
	  if ! printf '%s\n' "$$out" | grep -q '\[ERROR\] values.yaml:'; then \
	    echo "FAIL: $$f was rejected, but not by the schema:"; printf '%s\n' "$$out"; exit 1; \
	  fi; \
	  echo "==> rejected as expected: $$f"; \
	done

unittest: $(UNITTEST_PLUGIN)
	$(if $(HAS_PROBE),$(HELM) dependency update --skip-refresh $(PROBE) >/dev/null)
	$(HELM) unittest $(UNITTEST_FILES) $(CHART) $(if $(HAS_PROBE),$(PROBE))

# Regenerate the example snapshots after an intended change; review the diff before committing.
unittest-update: $(UNITTEST_PLUGIN)
	$(HELM) unittest -u $(UNITTEST_FILES) $(CHART)

# Renders the values schema into $(1). The chart is assembled in .bin/ because a chart can only
# read its own files.
define render-values-schema
	@rm -rf $(BIN)/values-schema-chart
	@cp -r test/values-schema $(BIN)/values-schema-chart
	@mkdir -p $(BIN)/values-schema-chart/definitions
	@cp -r $(CHART)/definitions/validating $(BIN)/values-schema-chart/definitions/
	@cp $(DEFINITION_SCHEMA)/values.schema.json $(BIN)/values-schema-chart/definition.schema.json
	@$(HELM) template x $(BIN)/values-schema-chart --show-only templates/schema.yaml > $(BIN)/values-schema.out
	@sed -e '/^---/d' -e '/^# Source/d' -e '/^$$/d' $(BIN)/values-schema.out > $(1)
endef

values-schema: $(HELM)
	$(call render-values-schema,$(VALUES_SCHEMA))
	@echo "==> wrote $(VALUES_SCHEMA)"

check-values-schema: $(HELM)
	@$(call render-values-schema,$(BIN)/values.schema.json)
	@if ! cmp -s $(BIN)/values.schema.json $(VALUES_SCHEMA); then \
	  echo "FAIL: $(VALUES_SCHEMA) is stale; run make values-schema and commit it"; \
	  diff -u $(VALUES_SCHEMA) $(BIN)/values.schema.json | head -40; exit 1; \
	fi
	@echo "==> $(VALUES_SCHEMA) is current"

crd-schema: $(CRD_SCHEMA)

# Rebuilt whenever the CRD or the converter changes. The chart is assembled in .bin/ because a
# chart can only read its own files.
$(CRD_SCHEMA): $(CRD) test/crd-schema/Chart.yaml test/crd-schema/templates/schema.yaml $(HELM)
	rm -rf $(BIN)/crd-schema-chart
	cp -r test/crd-schema $(BIN)/crd-schema-chart
	cp $(CRD) $(BIN)/crd-schema-chart/crd.yaml
	mkdir -p $(dir $@)
	$(HELM) template x $(BIN)/crd-schema-chart --show-only templates/schema.yaml > $(BIN)/crd-schema.out
	sed -e '/^---/d' -e '/^#/d' $(BIN)/crd-schema.out > $@

# No public catalog publishes a JSON schema for CustomResourceDefinition itself, so the CRD object
# is skipped here; tests/crd_test.yaml and the API server (make e2e) check it instead.
validate: $(HELM) $(KUBECONFORM) $(CRD_SCHEMA)
	@set -e; for f in $(EXAMPLES); do \
	  echo "==> kubeconform $$f"; \
	  $(HELM) template policy $(CHART) -f $$f | $(KUBECONFORM) $(KUBECONFORM_ARGS) -skip CustomResourceDefinition; \
	done
	@if [ -n "$(FIXTURES)" ]; then \
	  echo "==> kubeconform fixtures and example objects"; \
	  $(KUBECONFORM) $(KUBECONFORM_ARGS) $(FIXTURES); \
	fi
	@set -e; for f in $(INVALID_FIXTURES); do \
	  if out=$$($(KUBECONFORM) $(KUBECONFORM_ARGS) $$f 2>&1); then \
	    echo "FAIL: $$f was accepted by kubeconform"; exit 1; \
	  fi; \
	  if ! printf '%s\n' "$$out" | grep -q 'jsonschema validation failed'; then \
	    echo "FAIL: $$f was rejected, but not by its schema:"; printf '%s\n' "$$out"; exit 1; \
	  fi; \
	  echo "==> rejected as expected: $$f"; \
	done

# CLAUDE.md, "Testing": every policy has allow and deny fixtures covering the kinds it applies
# to (read from its resources: line): workloads a Pod, a Deployment, and a CronJob; services a
# Service; rbac a ClusterRole and a Role. A matchConstraints block (disallow-pod-exec) has no
# object to fixture; its cases are commands in test/e2e/scenarios/catalog.sh. And no fixtures
# exist for a policy that isn't defined.
check-fixtures:
	@set -e; fail=0; \
	for def in $(DEFINITIONS); do \
	  p=$$(basename $$def .yaml); \
	  case $$(sed -n 's/^resources: *//p' $$def) in \
	    workloads) kinds="Pod Deployment CronJob" ;; \
	    services) kinds="Service" ;; \
	    rbac) kinds="ClusterRole Role" ;; \
	    *) echo "==> $$p: a matchConstraints block, covered by e2e commands (no fixtures)"; continue ;; \
	  esac; \
	  for dir in allow deny; do \
	    for kind in $$kinds; do \
	      if ! grep -lqx "kind: $$kind" fixtures/$$p/$$dir/*.yaml 2>/dev/null; then \
	        echo "FAIL: fixtures/$$p/$$dir/ has no $$kind"; fail=1; \
	      fi; \
	    done; \
	  done; \
	done; \
	for d in fixtures/*/; do \
	  p=$$(basename $$d); \
	  if [ ! -f $(CHART)/definitions/validating/$$p.yaml ]; then \
	    echo "FAIL: $$d has no definition ($(CHART)/definitions/validating/$$p.yaml)"; fail=1; \
	  fi; \
	done; \
	[ $$fail -eq 0 ] && echo "==> fixtures cover every policy (the kinds it applies to; allow and deny)"

test: lint check-definitions check-fixtures check-values-schema unittest validate

test-all-helm:
	@set -e; for v in $(HELM_VERSIONS); do \
	  echo "==> Helm $$v"; \
	  $(MAKE) --no-print-directory test HELM_VERSION=$$v; \
	done

# Needs Docker. Extra arguments go to run.sh via E2E_ARGS (e.g. E2E_ARGS=smoke).
e2e: $(HELM) tools-e2e
	K3D=$(K3D) KUBECTL=$(KUBECTL) HELM=$(HELM) K3S_IMAGE=$(K3S_IMAGE) \
	  test/e2e/run.sh $(E2E_ARGS)

clean:
	rm -rf $(BIN)
