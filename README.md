# opencode-hs

[![CI](https://github.com/dodofk/opencode-hs/actions/workflows/ci.yml/badge.svg)](https://github.com/dodofk/opencode-hs/actions/workflows/ci.yml)

A Haskell reimplementation of [OpenCode](https://github.com/sst/opencode) — a terminal AI coding agent.

Built for correctness and FP purity: GADTs for tools, `conduit` streaming for LLM responses, `STM` for concurrency, `brick` for TUI.

## Status

Work in progress. See [MILESTONES.md](MILESTONES.md) for the plan and [SPEC.md](SPEC.md) for the full specification.

## Requirements

- GHC 9.6+ (via [GHCup](https://www.haskell.org/ghcup/))
- Stack

## Install toolchain

```bash
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
ghcup install ghc 9.6.6
ghcup install stack
```

## Build

```bash
stack build
stack test
stack run -- run
```

## Config

Create `~/.config/opencode-hs/config.yaml`:

```yaml
providers:
  openai:
    apiKey: sk-...
  anthropic:
    apiKey: sk-ant-...

defaultModel:
  provider: anthropic
  model: claude-opus-4-7
```

Or set environment variables: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`.

## Architecture

See [SPEC.md](SPEC.md) for detailed architecture documentation.
