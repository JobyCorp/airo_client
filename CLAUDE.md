# airo_client

Thin **server-to-server** Elixir client for the [Airo](../airo) gateway. It's the
library `incogito` and `orchester` use to talk to Airo instead of `openai_ex`.
Sibling of `airo` under `~/Work/airo-workspace/` — the `../airo` relative path in
docs resolves because they live side by side.

Scope: owns *everything app↔Airo*, **nothing browser-facing**. For realtime voice
the consumer terminates the browser WebSocket itself and relays only the upstream
leg to Airo via `AiroClient.Realtime` (the browser never reaches Airo directly).

## Layout
- `lib/airo_client.ex` — public API + request building / config resolution
- `lib/airo_client/streaming.ex` — SSE streaming for `chat_stream/2`
- `lib/airo_client/realtime.ex` — WebSocket relay leg (app → Airo `/v1/realtime`)
- `lib/airo_client/application.ex` — OTP app
- `test/` — uses `Req.Test` plug for HTTP; Bandit echo/reject upstreams for realtime

## Config (consumer side)
```elixir
config :airo_client,
  base_url: "http://airo.internal:4000",  # gateway HOST — NO /v1
  api_key:  System.get_env("AIRO_CLIENT_KEY"),
  receive_timeout: 120_000
```
- `:base_url` is the gateway **host**; this lib owns the full `/v1/...` paths.
  A trailing `/v1` is tolerated and stripped (so an `openai_ex`-style URL works).
- `:base_url`, `:api_key`, `:receive_timeout` are all overridable per call via opts.
- Airo is OpenAI-compatible: `model` may be an **alias** (`"chat-deep"`) or a
  **concrete deployment id** (`"qwen3.5-9b"`) — Airo resolves both.

## Public API (`AiroClient`)
`chat/2`, `chat_stream/2` (`into:` pid, defaults to caller), `embeddings/2`,
`rerank/2`, `classify/2`, `speech/2` (→ `{audio_binary, content_type}`),
`transcribe/3`, `voices/1` (opt `:model` → `?model=`), `models/1`,
`model_catalog/1`. Bodies are OpenAI-shaped maps with
**string keys**. Errors: `{:http, status, body}` | `{:transport, reason}` | `{:config, term}`.

## Dev
- `mix deps.get` · `mix compile` · `mix test` · `mix format`
- Deps: `req` (HTTP), `jason`, `mint_web_socket` (realtime). `plug`/`bandit`/`websock_adapter` are test-only.
