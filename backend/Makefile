.PHONY: setup build run test format clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup: ## Setup local database (create + migrate + seed)
	bash scripts/setup-db.sh

build: ## Compile the backend
	cabal build

run: setup build ## Setup DB + build + start server
	cabal run namma-ap-exe

server: ## Start server only (assumes already built)
	cabal run namma-ap-exe

format: ## Format all Haskell source files
	bash scripts/format.sh

test: ## Run test suite
	cabal test

hpack: ## Regenerate .cabal from package.yaml
	hpack && echo "Regenerated .cabal from package.yaml"

clean: ## Clean build artifacts
	cabal clean
