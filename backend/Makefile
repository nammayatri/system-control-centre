.PHONY: dev build test format clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

dev: ## Start full dev stack (postgres + db init + backend ghcid + frontend)
	bin/sc-dev

build: ## Compile the backend
	cabal build

test: ## Run test suite
	cabal test

format: ## Format all Haskell source files (treefmt → fourmolu)
	treefmt

clean: ## Clean build artifacts
	cabal clean
