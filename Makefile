.PHONY: build test run lint clean install-toolchain

# ---------------------------------------------------------------------------
# Build / test
# ---------------------------------------------------------------------------

build:
	stack build --fast

build-strict:
	stack build

test:
	stack test --fast

run:
	stack run -- run

# Non-interactive single-prompt mode (requires M8)
prompt:
	stack run -- run --no-tui --prompt "$(PROMPT)"

# ---------------------------------------------------------------------------
# Code quality
# ---------------------------------------------------------------------------

lint:
	hlint src app test

format:
	fourmolu --mode inplace src/**/*.hs app/**/*.hs test/**/*.hs

# ---------------------------------------------------------------------------
# Toolchain installation (run once on a fresh machine)
# ---------------------------------------------------------------------------

install-toolchain:
	@echo "Installing GHCup..."
	curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 sh
	@echo "Installing GHC 9.6.6 and Stack..."
	$${HOME}/.ghcup/bin/ghcup install ghc 9.6.6
	$${HOME}/.ghcup/bin/ghcup install stack
	$${HOME}/.ghcup/bin/ghcup set ghc 9.6.6
	@echo "Done. Restart your shell or: source ~/.ghcup/env"

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

clean:
	stack clean

deps:
	stack build --only-dependencies
