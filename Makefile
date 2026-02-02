# Detect Yelp environment and set Docker registry accordingly
ifeq ($(findstring .yelpcorp.com,$(shell hostname -f)), .yelpcorp.com)
	DOCKER_REGISTRY ?= docker-dev.yelpcorp.com/
else
	DOCKER_REGISTRY ?= docker.io/
endif

DOCKER_IMAGE := $(DOCKER_REGISTRY)nerve-dev
RUBY_VERSION := 3.2
VENV := .venv

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: setup
setup: ## Set up dev environment (auto-detects Docker vs local)
	@if command -v docker >/dev/null 2>&1; then \
		$(MAKE) setup-docker; \
	else \
		$(MAKE) setup-local; \
	fi

.PHONY: setup-docker
setup-docker: ## Build Docker development image
	docker build --build-arg RUBY_VERSION=$(RUBY_VERSION) -t $(DOCKER_IMAGE) -f Dockerfile.dev .

.PHONY: setup-local
setup-local: $(VENV) ## Install dependencies locally via bundler
	bundle install
	$(VENV)/bin/pre-commit install

$(VENV): ## Create Python venv for pre-commit
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install pre-commit

.PHONY: test
test: ## Run test suite
	@if [ -f Gemfile.lock ] && bundle check >/dev/null 2>&1; then \
		bundle exec rspec; \
	else \
		$(MAKE) test-docker; \
	fi

.PHONY: test-docker
test-docker: ## Run tests in Docker container
	docker run --rm $(DOCKER_IMAGE)

.PHONY: lint
lint: ## Check code style with StandardRB
	bundle exec standardrb

.PHONY: fix
fix: ## Auto-fix code style issues
	bundle exec standardrb --fix

.PHONY: console
console: ## Start interactive Ruby console
	@if bundle check >/dev/null 2>&1; then \
		bundle exec pry -r ./lib/nerve; \
	else \
		docker run --rm -it $(DOCKER_IMAGE) bundle exec pry -r ./lib/nerve; \
	fi

.PHONY: clean
clean: ## Remove generated files
	rm -rf tmp/ coverage/ .bundle/ vendor/ $(VENV)
	docker rmi $(DOCKER_IMAGE) 2>/dev/null || true
