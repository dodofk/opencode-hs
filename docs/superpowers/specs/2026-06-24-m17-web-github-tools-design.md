# Web & GitHub Tools (M17) — Design

**Date:** 2026-06-24
**Status:** Approved design, pre-implementation
**Depends on:** M7 (tool system), M14 (MCP client — for the tool registration pattern)

## Goal

Give the agent the ability to reach outside the local filesystem: search the
web, fetch a URL, and read from GitHub (search code, read issues/PRs, fetch a
file from a repo). These are the tools a coding agent most often lacks when
working on real tasks — "what does this public API return?", "is there a known
issue for this error?", "show me how library X uses function Y".

All five tools reuse the existing M7 `SomeTool` substrate and the M14 dynamic-
tool registration pattern. They register alongside `read`/`write`/`edit`/`bash`/
`glob`/`grep` and appear to the model as ordinary tools. The headless
`run --no-tui --prompt` path gets them for free, exactly as M16's `skill` tool
did.

## Decisions (settled during brainstorming)

1. **Scope:** both web and GitHub ship in M17, as two workstreams sharing one
   HTTP substrate. They are designed for clean separation so either could be
   deferred if needed.
2. **Web search backend:** Brave Search API (`api.search.brave.com`). Free tier
   is generous (1 qps, 2,000/month); simple REST; single `X-Subscription-Token`
   header.
3. **GitHub surface:** three REST tools — search code, read issue/PR, fetch
   file. PAT bearer-token auth. No GraphQL.
4. **Auth/config:** extend the existing `Config` type with a `ToolsConfig`
   record (`braveKey`, `githubKey`, both `Maybe ApiKey`). Same env-var-over-YAML
   priority as the LLM providers. `BRAVE_API_KEY` / `GITHUB_TOKEN` env vars.
   Both optional — the app boots fine without them; only the affected tool
   errors when invoked without its key.
5. **Testing:** pure unit tests + mock-backed executor tests, zero network in
   CI. Matches the M15/M16 mock-first style. Live smoke tests are a documented
   manual step, not part of the suite.
6. **HTML stripping:** use the `tagsoup` library (small, well-maintained) for
   the `web_fetch` URL→text conversion, rather than hand-rolling a parser.

## Architecture

### Shared HTTP substrate — `OpenCode.Net.Http`

The LLM providers each inline their own `Network.HTTP.Simple` calls. That is
fine for two providers, but five new networked tools would duplicate
header/auth/timeout/error-mapping logic five times. A small `Net.Http` module
with an injectable backend lets every tool share one code path and lets tests
swap in a mock without touching `AppM`.

```haskell
data HttpRequest = HttpRequest
  { hrMethod  :: Text          -- "GET" | "POST"
  , hrUrl     :: Text
  , hrHeaders :: [(Text, Text)]
  , hrBody    :: Maybe ByteString
  }

data HttpError = HttpError
  { heStatus :: Int            -- HTTP status, or 0 for transport failure
  , heBody   :: Text           -- response body or error message
  }

-- Injectable backend stored in AppEnv. Production = runHttp; tests = HttpMock.
type HttpBackend = HttpRequest -> IO (Either HttpError ByteString)

-- Production backend: Network.HTTP.Simple, TLS, 30s timeout, error mapping.
runHttp :: HttpRequest -> IO (Either HttpError ByteString)
```

`AppEnv` gains a `envHttpBackend :: HttpBackend` field, defaulted to `runHttp`
in `Run.withAppEnv`. Tests construct an `AppEnv` whose backend is a pure
`Map Text ByteString` keyed by URL (see `Net.HttpMock`). **Zero network calls
in the test suite.**

This is a targeted improvement to code the milestone works near (the HTTP call
sites), not unrelated refactoring — the LLM providers are left untouched.

### Module layout

```
src/OpenCode/
├── Net/
│   ├── Http.hs              NEW: HttpRequest/HttpError/HttpBackend/runHttp
│   └── HttpMock.hs          NEW: pure URL→ByteString backend for tests
├── Tool/
│   ├── WebSearch.hs         NEW: Brave Search tool
│   ├── WebFetch.hs          NEW: URL → cleaned markdown (via tagsoup)
│   ├── GitHubSearch.hs      NEW: GitHub code search
│   ├── GitHubIssue.hs       NEW: read issue/PR by number
│   └── GitHubFile.hs        NEW: fetch file from a repo
├── Config.hs                MODIFIED: +ToolsConfig, +braveKey, +githubKey
├── App/Types.hs             MODIFIED: AppEnv gains envHttpBackend, envTools
└── Run.hs                   MODIFIED: register the 5 new tools in withAppEnv
```

New dependency edges: every `Tool.*` web/github module → `Net.Http`,
`App.Types`, `Tool.Types`, `App.Error`. `Net.Http` is a leaf (imports only
`http-conduit` + base). `Run → Net.Http` (to wire `runHttp`). No module
imports `Network.HTTP.Simple` except `Net.Http`.

### New dependency

`tagsoup` (BSD-3, ~small, no transitive surprises) added to `package.yaml` for
`web_fetch`'s HTML→text. Everything else uses already-present `http-conduit`,
`http-types`, `aeson`.

## Tools

### Web workstream

**Tool 1: `web_search`** (Brave Search API)
- Input: `{ query :: Text, count :: Maybe Int }` — count defaults 5, capped 20.
- Endpoint: `GET https://api.search.brave.com/res/v1/web/search?q=<q>&count=<n>`
- Auth: `X-Subscription-Token: <braveKey>`.
- Output (rendered to LLM): numbered list of `title | url | snippet`.
- Errors: missing key → `ToolError` with a "set BRAVE_API_KEY" message; non-200
  → `HttpError` surfaced as `ToolError`.

**Tool 2: `web_fetch`** (URL → markdown)
- Input: `{ url :: Text, maxLength :: Maybe Int }` — defaults 10,000 chars,
  hard cap 50,000.
- No auth — plain GET with a browser-like User-Agent.
- Output: cleaned text via tagsoup: drop `<script>`/`<style>`/`<head>`, convert
  `<a href>`/`<p>`/`<br>`/`<li>` to text with newlines, collapse whitespace.
- Truncation suffix appended when the result exceeds `maxLength`.

### GitHub workstream (REST, bearer token)

All three hit `https://api.github.com` with
`Authorization: Bearer <githubKey>` + `Accept: application/vnd.github+json` +
`User-Agent: opencode-hs`.

**Tool 3: `github_search_code`**
- Input: `{ query :: Text, limit :: Maybe Int }` — limit defaults 10, capped 30.
- Endpoint: `GET /search/code?q=<q>&per_page=<n>`.
- Output: numbered list of `repo/path` with the `html_url` and text match
  excerpts where Brave/GitHub return them.

**Tool 4: `github_read_issue`**
- Input: `{ repo :: Text, number :: Int, kind :: Maybe Text }` — `kind` ∈
  `"issue"` | `"pr"`, defaults `"issue"`.
- Endpoint: `GET /repos/<repo>/issues/<n>` or `/repos/<repo>/pulls/<n>`.
- Output: title, state, author, labels, body (truncated to ~4,000 chars).

**Tool 5: `github_fetch_file`**
- Input: `{ repo :: Text, path :: Text, ref :: Maybe Text }` — `ref` defaults
  to the repo's default branch.
- Endpoint: `GET /repos/<repo>/contents/<path>?ref=<ref>` → JSON with base64
  `content`.
- Output: decoded file contents as text (truncated to ~10,000 chars).

## Config changes

Following the exact existing pattern (env var priority over YAML, `Maybe ApiKey`
fields, `fromMaybe` defaults):

```yaml
# ~/.config/opencode-hs/config.yaml
tools:
  braveApiKey: { apiKey: "BSA..." }
  githubToken: { apiKey: "ghp_..." }
```

- New `ToolsConfig` record: `braveKey :: Maybe ApiKey`, `githubKey :: Maybe
  ApiKey`. Added as a field `tools :: ToolsConfig` on `Config`.
- Env vars `BRAVE_API_KEY`, `GITHUB_TOKEN` override YAML (extend `EnvOverride` +
  `loadEnvVars`, mirror the provider key handling).
- Both optional. Missing key → affected tool returns a `ToolError` when invoked;
  the app still boots, other tools work, `config check` does not fail.
- `AppEnv` carries `envTools :: ToolsConfig` so tool executors read keys from it.

## Data flow (model path)

1. `withAppEnv` loads `Config` (now including `ToolsConfig`), builds `AppEnv`
   with `envHttpBackend = runHttp` and `envTools = tools config`.
2. The 5 new tools are built (each closing over `envHttpBackend` and the
   relevant key via `asks`) and registered into `envRegistry` next to the
   existing file/bash/search tools.
3. Agentic loop sends the tool list as usual; the model sees `web_search`,
   `web_fetch`, `github_search_code`, `github_read_issue`, `github_fetch_file`.
4. Model calls one → `executeTool` dispatches → executor builds an
   `HttpRequest`, runs it through `envHttpBackend`, parses JSON (aeson), renders
   text → returned as the tool result. Non-200 / missing key → `ToolError`.

Because the tools live in `envRegistry`, headless `run --no-tui --prompt` gets
them for free (same property as M16's `skill` tool).

## Error handling

| Case | Behavior |
|---|---|
| Missing `braveKey` / `githubKey` at call time | `ToolError` with a clear "set BRAVE_API_KEY / GITHUB_TOKEN" message. Tool is still registered (so the model knows it exists and can report the need). |
| HTTP non-200 (e.g. 401, 403, 404, 429) | `ToolError` carrying `heStatus` + a trimmed `heBody`. Model can self-correct or report. |
| Transport failure (DNS, timeout, TLS) | `HttpError { heStatus = 0, heBody = <message> }` → `ToolError`. |
| Malformed JSON response | `ToolError` with the aeson decode error text. |
| Malformed tool input JSON | Existing `executeTool` path → `ToolError` (unchanged). |
| `web_fetch` on binary / non-UTF8 body | `ToolError` ("non-text content"); no special decoding in M17. |

No retry/backoff in M17 — a 429 surfaces as a `ToolError`. (Candidate for a
later M17.1 if it bites in practice.)

## Testing

All via the existing hspec harness. No new test dependencies.

- **Net.Http unit:** test the pure pieces only — `HttpRequest` building,
  header assembly, and the `HttpError`-from-status mapping. The live
  `runHttp` is exercised end-to-end indirectly through each tool's executor
  test, which runs against the mock backend (so the `HttpRequest` it builds
  is exactly what would be sent on the wire).
- **Each tool, pure layer:** URL construction, query params, header sets, JSON
  response parsing (from a recorded fixture), output rendering (markdown/text
  shape, truncation). No `IO`.
- **Each tool, executor via mock:** `AppEnv` with `envHttpBackend = HttpMock`
  returning a recorded fixture → assert the rendered tool result. Fixtures
  recorded once from real Brave/GitHub, committed under
  `test/fixtures/web/{brave,github}/`.
- **Error paths:** missing key (env unset → `ToolError`); non-200 (mock returns
  `Left HttpError`); malformed JSON; transport failure (`heStatus = 0`).
- **Config:** extend `ConfigSpec` — env override beats YAML; both missing →
  `Nothing`, app still boots.
- **Registry:** extend `Tool.RegistrySpec` — the 5 tools are registered and
  discoverable; their schemas/descriptions are well-formed.

New test files: `Net.HttpSpec`, `WebSearchSpec`, `WebFetchSpec`,
`GitHubSearchSpec`, `GitHubIssueSpec`, `GitHubFileSpec`. Fixtures under
`test/fixtures/web/{brave,github}/`.

**No live tests in CI.** A live smoke test (set the env var, run `opencode-hs
run --no-tui --prompt "search the web for ..."` ) is a documented manual step.

## Out of scope

- Rate-limit handling / retry / backoff (429 surfaces as `ToolError`).
- Pagination past the first page on any endpoint.
- OAuth / GitHub App auth flows (PAT only).
- Response caching.
- `web_fetch` of binary / non-UTF8 / JS-rendered SPA content.
- Migrating the LLM providers to the new `Net.Http` substrate (left untouched —
  their inline HTTP is fine and out of scope).
- Web/GitHub *write* operations (create issue, post comment, etc.) — read-only
  in M17.
