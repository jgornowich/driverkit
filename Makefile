SHELL=/bin/bash -o pipefail

DOCKER ?= docker
GORELEASER ?= goreleaser

GIT_TAG ?= $(shell git describe --tags --abbrev=0 2> /dev/null)
COMMITS_FROM_GIT_TAG := $(shell git rev-list ${GIT_TAG}.. --count 2> /dev/null || echo "0")
COMMIT_NO := $(shell git rev-parse --short HEAD 2> /dev/null || true)
GIT_COMMIT := $(if $(shell git status --porcelain --untracked-files=no),${COMMIT_NO}.dirty,${COMMIT_NO})
GIT_BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null)
GIT_BRANCH_CLEAN := $(shell echo $(GIT_BRANCH) | sed -e "s/[^[:alnum:]]/-/g")
GIT_REF := ${GIT_BRANCH_CLEAN}
ifeq ($(COMMITS_FROM_GIT_TAG),0)
	ifneq ($(GIT_TAG),)
		GIT_REF := ${GIT_TAG}
	endif
endif

DOCKER_ORG ?= falcosecurity

BUILDERS := $(patsubst build/builder_%.Dockerfile,%,$(wildcard build/builder_*.Dockerfile))

IMAGE_NAME_BUILDER_BASE ?= docker.io/$(DOCKER_ORG)/driverkit-builder

IMAGE_NAME_SUFFIX_REF := ":$(GIT_REF)_$(shell uname -m)"
IMAGE_NAME_SUFFIX_COMMIT := ":$(GIT_COMMIT)_$(shell uname -m)"
IMAGE_NAME_SUFFIX_LATEST := ":latest_$(shell uname -m)"

IMAGE_NAME_DRIVERKIT ?= docker.io/$(DOCKER_ORG)/driverkit

IMAGE_NAME_DRIVERKIT_REF := $(IMAGE_NAME_DRIVERKIT):$(GIT_REF)_$(shell uname -m)
IMAGE_NAME_DRIVERKIT_COMMIT := $(IMAGE_NAME_DRIVERKIT):$(GIT_COMMIT)_$(shell uname -m)
IMAGE_NAME_DRIVERKIT_LATEST := $(IMAGE_NAME_DRIVERKIT):latest_$(shell uname -m)

LDFLAGS := -X github.com/falcosecurity/driverkit/pkg/version.buildTime=$(shell date +%s) -X github.com/falcosecurity/driverkit/pkg/version.gitCommit=${GIT_COMMIT} -X github.com/falcosecurity/driverkit/pkg/version.gitTag=$(if ${GIT_TAG},${GIT_TAG},v0.0.0) -X github.com/falcosecurity/driverkit/pkg/version.commitsFromGitTag=${COMMITS_FROM_GIT_TAG} -X github.com/falcosecurity/driverkit/pkg/driverbuilder/builder.BaseImage=${IMAGE_NAME_BUILDER_BASE}:$(GIT_COMMIT)

TARGET_TEST_ARCH ?= $(shell uname -m)
test_configs := $(wildcard test/$(TARGET_TEST_ARCH)/configs/*.yaml)

driverkit ?= _output/bin/driverkit
driverkit_docgen ?= _output/bin/docgen

.PHONY: build
build: clean ${driverkit}

${driverkit}:
	CGO_ENABLED=0 go build -v -buildmode=pie -ldflags '${LDFLAGS}' -o $@ .

.PHONY: release
release: clean
	CGO_ENABLED=0 LDFLAGS="${LDFLAGS}" $(GORELEASER) release

.PHONY: clean
clean:
	$(RM) -R dist
	$(RM) -R _output

image/all: image/builder image/driverkit

.PHONY: image/builder
image/builder:
	$(foreach b,$(BUILDERS),\
		$(DOCKER) buildx build -o type=image,push="false" -f build/builder_$b.Dockerfile . ; \
    )

.PHONY: image/driverkit
image/driverkit:
	$(DOCKER) buildx build -o type=image,push="false" -f build/driverkit.Dockerfile .

push/all: push/builder push/driverkit

.PHONY: push/builder
push/builder:
	$(foreach b,$(BUILDERS),\
		$(DOCKER) buildx build --push -t "$(IMAGE_NAME_BUILDER_BASE)_$b$(IMAGE_NAME_SUFFIX_REF)" -t "$(IMAGE_NAME_BUILDER_BASE)_$b$(IMAGE_NAME_SUFFIX_COMMIT)" -f build/builder_$b.Dockerfile . ; \
	)

.PHONY: push/driverkit
push/driverkit:
	$(DOCKER) buildx build --push -t "$(IMAGE_NAME_DRIVERKIT_REF)" -t "$(IMAGE_NAME_DRIVERKIT_COMMIT)" -f build/driverkit.Dockerfile .

.PHONY: push/latest
push/latest:
	$(foreach b,$(BUILDERS),\
		$(DOCKER) buildx build --push -t "$(IMAGE_NAME_BUILDER_BASE)_$b$(IMAGE_NAME_SUFFIX_LATEST)" -f build/builder_$b.Dockerfile . ; \
	)
	$(DOCKER) buildx build --push -t "$(IMAGE_NAME_DRIVERKIT_LATEST)" -f build/driverkit.Dockerfile .

manifest/all: manifest/builder manifest/driverkit

.PHONY: manifest/builder
manifest/builder:
	$(foreach b,$(BUILDERS),\
		$(DOCKER) manifest create "$(IMAGE_NAME_BUILDER_BASE)_$b:$(GIT_REF)" $(IMAGE_NAME_BUILDER_BASE)_$b:$(GIT_REF)_x86_64 $(IMAGE_NAME_BUILDER_BASE)_$b:$(GIT_REF)_aarch64 ; \
		$(DOCKER) manifest push "$(IMAGE_NAME_BUILDER_BASE)_$b:$(GIT_REF)" ; \
		$(DOCKER) manifest create $(IMAGE_NAME_BUILDER_BASE)_$b:$(GIT_COMMIT) $(IMAGE_NAME_BUILDER_BASE)_$b:$(GIT_COMMIT)_x86_64 $(IMAGE_NAME_BUILDER_BASE)_$b:$(GIT_COMMIT)_aarch64 ; \
		$(DOCKER) manifest push $(IMAGE_NAME_BUILDER_BASE)_$b:$(GIT_COMMIT) ; \
	)

.PHONY: manifest/driverkit
manifest/driverkit:
	$(DOCKER) manifest create $(IMAGE_NAME_DRIVERKIT):$(GIT_REF) $(IMAGE_NAME_DRIVERKIT):$(GIT_REF)_x86_64 $(IMAGE_NAME_DRIVERKIT):$(GIT_REF)_aarch64
	$(DOCKER) manifest push $(IMAGE_NAME_DRIVERKIT):$(GIT_REF)
	$(DOCKER) manifest create $(IMAGE_NAME_DRIVERKIT):$(GIT_COMMIT) $(IMAGE_NAME_DRIVERKIT):$(GIT_COMMIT)_x86_64 $(IMAGE_NAME_DRIVERKIT):$(GIT_COMMIT)_aarch64
	$(DOCKER) manifest push $(IMAGE_NAME_DRIVERKIT):$(GIT_COMMIT)

.PHONY: manifest/latest
manifest/latest:
	$(foreach b,$(BUILDERS),\
	  	$(DOCKER) manifest create "$(IMAGE_NAME_BUILDER_BASE)_$b:latest" $(IMAGE_NAME_BUILDER_BASE)_$b:latest_x86_64 $(IMAGE_NAME_BUILDER_BASE)_$b:latest_aarch64 ; \
		$(DOCKER) manifest push "$(IMAGE_NAME_BUILDER_BASE)_$b:latest" ; \
	)
	$(DOCKER) manifest create $(IMAGE_NAME_DRIVERKIT):latest $(IMAGE_NAME_DRIVERKIT):latest_x86_64 $(IMAGE_NAME_DRIVERKIT):latest_aarch64
	$(DOCKER) manifest push $(IMAGE_NAME_DRIVERKIT):latest

.PHONY: test
test:
	go clean -testcache
	go test -v -cover -race ./...
	go test -v -cover -buildmode=pie ./cmd

.PHONY: integration_test
integration_test: $(test_configs)

.PHONY: $(test_configs)
$(test_configs): ${driverkit}
	${driverkit} docker -c $@ --builderimage auto:master -l debug --timeout 600

.PHONY: ${driverkit_docgen}
${driverkit_docgen}: ${PWD}/docgen
	go build -v -o $@ $^

.PHONY: docs
docs: ${driverkit_docgen}
	$(RM) -R docs/driverkit*
	@mkdir -p docs
	${driverkit_docgen}
