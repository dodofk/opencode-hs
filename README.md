# opencode-hs

A terminal AI coding agent in Haskell — a reimplementation of [OpenCode](https://github.com/sst/opencode).

[![CI](https://github.com/dodofk/opencode-hs/actions/workflows/ci.yml/badge.svg)](https://github.com/dodofk/opencode-hs/actions/workflows/ci.yml)

## What it is

`opencode-hs` is a terminal AI coding agent that streams LLM responses token-by-token through a [brick](https://github.com/jtdaugherty/brick) TUI, backed by a type-safe tool system and SQLite session history. Supports OpenAI, Anthropic, and MiniMax as providers. Built for correctness and FP purity: `conduit` streaming for LLM responses, `STM` for concurrency, and a strongly-typed tool layer.

See [SPEC.md](SPEC.md) for the architecture and [MILESTONES.md](MILESTONES.md) for the build plan.

## Install

Requires GHC 9.6.6 and Stack.

```sh
# Install the binary to your PATH
stack install

# Or build and run without installing
stack build
stack run opencode-hs -- <args>
```

## Quickstart

```sh
# Start the interactive TUI (bare invocation)
stack run opencode-hs
```

```sh
# Run a single prompt headless (no TUI, streams to stdout)
stack run opencode-hs -- run --prompt "list the .hs files" --no-tui
```

```sh
# Resume an existing session
stack run opencode-hs -- run --session <ID>
```

```sh
# Choose a specific model
stack run opencode-hs -- run --model openai:gpt-4o
```

```sh
# List all stored sessions
stack run opencode-hs -- list
```

```sh
# Export a session to Markdown on stdout
stack run opencode-hs -- export <SESSION_ID>
```

```sh
# Probe each configured provider for connectivity
stack run opencode-hs -- config check
```

```sh
# Print version and exit
stack run opencode-hs -- --version
```

## Configuration

Environment variables take priority over the config file. Set one key to get started:

```sh
export OPENAI_API_KEY=sk-...
export ANTHROPIC_API_KEY=sk-ant-...
export MINIMAX_API_KEY=...
```

Config file path: `~/.config/opencode-hs/config.yaml`

```yaml
providers:
  openai:
    apiKey: sk-...
  anthropic:
    apiKey: sk-ant-...
  minimax:
    apiKey: ...
defaultModel:
  provider: openai
  model: gpt-4o
```

When no `defaultModel` is set, the agent picks one automatically based on which keys are present: MiniMax key → `MiniMax-M3`; otherwise OpenAI key → `gpt-4o`; otherwise Anthropic fallback → `claude-opus-4-5`.

## Providers & models

| Provider  | Example model      | Notes                                      |
|-----------|--------------------|--------------------------------------------|
| OpenAI    | `gpt-4o`           | Standard OpenAI API                        |
| Anthropic | `claude-opus-4-5`  | Native Anthropic streaming API             |
| MiniMax   | `MiniMax-M3`       | Served over an OpenAI-compatible endpoint  |

Pass `--model provider:model` to override per-run, e.g. `--model anthropic:claude-opus-4-5`.

## Built-in tools

The agent can call these tools during a run:

- `read_file` — read a file from disk
- `write_file` — write or overwrite a file
- `edit_file` — apply a targeted patch to an existing file
- `bash` — execute a shell command and return its output
- `glob` — expand a glob pattern to a list of matching paths
- `grep` — search file contents for a pattern

## TUI keys

| Key          | Action                                       |
|--------------|----------------------------------------------|
| Enter        | Submit the input (when idle)                 |
| Esc          | Request cooperative abort of the current run |
| ↑ / ↓        | Scroll the chat one line                     |
| PgUp / PgDn  | Scroll the chat one page                     |
| Ctrl-C       | Quit                                         |

Abort is cooperative: Esc signals the loop to stop between tool rounds. If the process receives SIGINT (Ctrl-C in headless mode), it exits immediately.

## Slash commands

Type these at the input line (Enter to run):

| Command     | Action                                                    |
|-------------|-----------------------------------------------------------|
| `/new`      | Start a new session and switch to it                      |
| `/sessions` | Open a picker to switch to another stored session         |
| `/model`    | Open a picker to change this session's model (persisted)  |
| `/help`     | Show keys and commands                                    |
| `/quit`     | Exit (same as Ctrl-C)                                     |

**Autocomplete:** as soon as the input line begins with `/`, a panel lists the
matching commands with descriptions. Use `↑`/`↓` to highlight, `Tab` to complete
the highlighted command into the input, and `Enter` to run it. The panel
disappears when the line no longer starts with `/`.

Pickers are modal: `↑/↓` to move, `Enter` to confirm, `Esc` to cancel.
Context-changing commands (`/new`, `/sessions`, `/model`) are disabled while a
run is streaming — press `Esc` to abort first.

## Troubleshooting

**No API key configured**

```
No API key found. Set MINIMAX_API_KEY, OPENAI_API_KEY or ANTHROPIC_API_KEY,
or add them to ~/.config/opencode-hs/config.yaml.
```

Set at least one of `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `MINIMAX_API_KEY`, or add the key under `providers` in the config file.

**Testing the TUI without a key**

Set `OPENCODE_MOCK=1` to enable a canned streaming reply that exercises the full TUI rendering path without hitting any provider:

```sh
OPENCODE_MOCK=1 stack run opencode-hs
```
