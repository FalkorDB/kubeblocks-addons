#
# Copyright 2022 The KubeBlocks Authors
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

################################################################################
# Variables                                                                    #
################################################################################
# Define the target operating system if needed
OS ?= $(shell uname)
# Define the target system architecture if needed
ARCH ?= $(shell uname -m)

ifeq ($(OS), Darwin)
	OS=darwin
else ifeq ($(OS), Linux)
	OS=linux
endif

ifeq ($(ARCH), arm64)
	ARCH=aarch64
else ifeq ($(ARCH), amd64)
	ARCH=x86_64
endif

# Define the installation directory
PREFIX ?= /usr/local
SC_BINARY_PATH := $(PREFIX)/bin/shellcheck
SC_VERSION ?= "v0.10.0"
SC_URL := https://github.com/koalaman/shellcheck/releases/download/$(SC_VERSION)/shellcheck-$(SC_VERSION).$(OS).$(ARCH).tar.xz
SC_BUILD_DIR := shellcheck-build
SC_DOWNLOAD_FILE := shellcheck-$(SC_VERSION).$(OS).$(ARCH).tar.xz
SC_OPTIONS ?= --format=tty --severity=error
SHELLCHECK_FILE ?=

.PHONY: help
help: ##    Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)


.PHONY: install-shellcheck
install-shellcheck: ## Download shellcheck locally if necessary.
ifeq (, $(shell which shellcheck))
	@echo "Downloading ShellCheck..."
	@curl -L $(SC_URL) -o $(SC_DOWNLOAD_FILE)
	@echo "Extracting ShellCheck..."
	@mkdir -p $(SC_BUILD_DIR)
	@tar xvf $(SC_DOWNLOAD_FILE) -C $(SC_BUILD_DIR)
	@echo "Installing ShellCheck..."
	@mkdir -p $(PREFIX)/bin
	@sudo cp $(SC_BUILD_DIR)/shellcheck-$(SC_VERSION)/shellcheck $(SC_BINARY_PATH)
	@chmod +x $(SC_BINARY_PATH)
	@echo "Remove ShellCheck temporary files and directories..."
	@rm -rf $(SC_BUILD_DIR) $(SC_DOWNLOAD_FILE)
	@echo "ShellCheck Successfully installed"
	@shellcheck --version
else
	@echo "ShellCheck is detected: "$(shell which shellcheck)
	@shellcheck --version
endif

ifeq (, $(SHELLCHECK_FILE))
SCRIPT_FILES := $(shell find . -type f -name "*.sh")
endif

.PHONY: shellcheck
shellcheck: install-shellcheck ##    Run shellcheck on all shell scripts if not specify `SHELLCHECK_FILE`.
ifeq (, $(SHELLCHECK_FILE))
	$(foreach scriptFile, $(SCRIPT_FILES), \
		shellcheck $(SC_OPTIONS) $(scriptFile); \
	)
else
	@shellcheck $(SC_OPTIONS) $(SHELLCHECK_FILE)
endif

SHELLSPEC_VERSION ?= 0.28.1
SHELLSPEC_LOCAL_INSTALL_PATH := /usr/local/shellspec
SHELLSPEC_LOCAL_INSTALL_TAR_GZ_FILE := shellspec-dist.tar.gz
SHELLSPEC_BIN_PATH := $(PREFIX)/bin
SHELLSPEC_LOAD_PATH ?= ./shellspec
SHELLSPEC_DEFAULT_PATH ?= "**/scripts-ut-spec"
SHELLSPEC_DEFAULT_SHELL ?= bash

# shellspec is a full-featured BDD unit testing framework for all kinds of shells, details: https://github.com/shellspec/shellspec
.PHONY: install-shellspec
install-shellspec: ##  Download and Install shellspec ut framework if necessary.
ifeq (, $(shell which shellspec))
	@echo "Installing ShellSpec..."
	@sudo mkdir -p $(SHELLSPEC_LOCAL_INSTALL_PATH)
	@if [ ! -d "$(SHELLSPEC_LOCAL_INSTALL_PATH)/shellspec" ]; then \
		echo "Downloading ShellSpec..."; \
		sudo wget -P $(SHELLSPEC_LOCAL_INSTALL_PATH) https://github.com/shellspec/shellspec/releases/download/$(SHELLSPEC_VERSION)/$(SHELLSPEC_LOCAL_INSTALL_TAR_GZ_FILE); \
		sudo tar -xzf $(SHELLSPEC_LOCAL_INSTALL_PATH)/$(SHELLSPEC_LOCAL_INSTALL_TAR_GZ_FILE) -C $(SHELLSPEC_LOCAL_INSTALL_PATH); \
		echo "Downloaded ShellSpec and extracted successfully"; \
	fi
	@sudo ln -s $(SHELLSPEC_LOCAL_INSTALL_PATH)/shellspec/shellspec $(SHELLSPEC_BIN_PATH)/shellspec
	@shellspec --version
	@echo "ShellSpec installed successfully"
else
	@echo "ShellSpec is already installed in : "$(shell which shellspec)
	@shellspec --version
endif

# run shellspec tests
.PHONY: scripts-test
scripts-test: install-shellspec ##    Run shellspec unit test cases.
	@shellspec --load-path $(SHELLSPEC_LOAD_PATH) --default-path $(SHELLSPEC_DEFAULT_PATH) --shell $(SHELLSPEC_DEFAULT_SHELL)


SHELLSPEC_INCLUDE_PATH := $(shell ./utils/get_shellspec_include_path.sh)

# run shellspec tests with coverage report
.PHONY: scripts-test-kcov
scripts-test-kcov: install-shellspec ##    Run shellspec unit test cases.
	@shellspec --load-path $(SHELLSPEC_LOAD_PATH) --default-path $(SHELLSPEC_DEFAULT_PATH) --shell $(SHELLSPEC_DEFAULT_SHELL) --kcov --kcov-options "--include-path=$(SHELLSPEC_INCLUDE_PATH) --path-strip-level=1"

################################################################################
# End-to-end tests                                                             #
################################################################################
# Chainsaw uses Go-style arch names, unlike the shellcheck download above.
E2E_OS := $(shell uname | tr '[:upper:]' '[:lower:]')
E2E_ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
CHAINSAW_VERSION ?= v0.2.15
CHAINSAW_INSTALL_DIR ?= $(HOME)/.local/bin
CHAINSAW ?= $(shell command -v chainsaw 2>/dev/null || echo $(CHAINSAW_INSTALL_DIR)/chainsaw)
CHAINSAW_URL := https://github.com/kyverno/chainsaw/releases/download/$(CHAINSAW_VERSION)/chainsaw_$(E2E_OS)_$(E2E_ARCH).tar.gz

# The addon under test. Point this at another addon once it grows an e2e suite.
E2E_ADDON ?= falkordb
E2E_DIR := addons/$(E2E_ADDON)/e2e
# Scenario scripts source their helpers from here.
export E2E_LIB_DIR := $(CURDIR)/$(E2E_DIR)/lib
# Run a subset with e.g. `make e2e E2E_TEST=02-switchover`
E2E_TEST ?=
E2E_PARALLEL ?= 4

.PHONY: install-chainsaw
install-chainsaw: ## Download kyverno-chainsaw locally if necessary.
ifeq (, $(shell command -v chainsaw 2>/dev/null))
	@echo "Downloading Chainsaw $(CHAINSAW_VERSION) for $(E2E_OS)/$(E2E_ARCH)..."
	@mkdir -p $(CHAINSAW_INSTALL_DIR)
	@curl -sSL $(CHAINSAW_URL) | tar -xz -C $(CHAINSAW_INSTALL_DIR) chainsaw
	@chmod +x $(CHAINSAW_INSTALL_DIR)/chainsaw
	@echo "Chainsaw installed to $(CHAINSAW_INSTALL_DIR)/chainsaw"
	@$(CHAINSAW_INSTALL_DIR)/chainsaw version
else
	@echo "Chainsaw is detected: "$(shell command -v chainsaw)
	@chainsaw version
endif

.PHONY: e2e-up
e2e-up: ##    Create the local k3d cluster and install KubeBlocks plus the local addon.
	@./$(E2E_DIR)/setup/kb-cluster.sh up

.PHONY: e2e-down
e2e-down: ##    Delete the local e2e k3d cluster.
	@./$(E2E_DIR)/setup/kb-cluster.sh down

.PHONY: e2e-status
e2e-status: ##    Show what is installed in the e2e cluster.
	@./$(E2E_DIR)/setup/kb-cluster.sh status

.PHONY: e2e
e2e: install-chainsaw ##    Run the chainsaw e2e suite against the current kubecontext.
	@$(CHAINSAW) test \
		--config $(E2E_DIR)/.chainsaw.yaml \
		--parallel $(E2E_PARALLEL) \
		$(if $(E2E_TEST),--test-dir $(E2E_DIR)/tests/$(E2E_TEST),--test-dir $(E2E_DIR)/tests)

.PHONY: e2e-all
e2e-all: e2e-up e2e ##    Create the cluster and run the whole suite in one go.

