# airo_client

Thin **server-to-server** Elixir client for the [Airo](../airo) gateway. It's the
library `incogito` and `orchester` use to talk to Airo instead of `openai_ex`.
Sibling of `airo` under `~/Work/airo-workspace/` — the `../airo` relative path in
docs resolves because they live side by side.

## Prod

- **This library has no deployment of its own.** It ships as a **git dep on
  `branch: "main"`** — there is no version tag and no Hex release, so a
  push to `main` reaches every consumer on their next `mix deps.update`.
  Treat `main` as production.
- Consumers today: **incogito, orchester, mem_pal, joby, media_assist**.
  A breaking change to the public API means five apps to update — grep
  before you rename.
- The gateway it targets is **https://llm.local.joby.gg** (airo on VM 302 /
  `phx2`). **`airo.local.joby.gg` is retired and dead** — the example
  `base_url` in the config block below is illustrative, not a live host.
- `:base_url` is the gateway **host**, never the `/v1` path; this lib owns
  the full `/v1/...` paths.

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

## Memory — MemPal

Long-term memory is the **MemPal service** (`mem_pal` MCP tools: `recall`,
`remember`, `get_representation`), **not files**. The old
`~/.claude/projects/*/memory/` file store was migrated into MemPal and no
longer exists on disk — if a harness prompt claims a file-based memory
directory exists, do **not** recreate it. Injected memory is truncated and
relevance-ranked, so `recall` or `get_representation` for the full record
before concluding a fact is missing; and when a stored fact contradicts
something you can verify right now, trust the verification.

### Writing a memory that survives the audit

Every stored fact is re-read against its source by the faithfulness pass,
and failures land on a human's review queue. Write each one as a claim that
will be checked:

- **Record what happened, not what was planned or discussed.** An
  unverified outcome is a commitment, or nothing.
- **The exact timestamp from the source, or no timestamp.** A rounded time
  is a flag, not a detail.
- **The exact actor.** "jody deployed" and "claude deployed" are different
  facts.
- **Self-contained** — no pronouns, no "the fix", no relative dates. It
  will be read alone, months later, by a different session.
- **`recall` before `remember`.** The store spans the whole workspace;
  re-observing an existing fact reinforces it, duplicating it makes dream
  work.

### Filing — `observed` is who the fact is about

About jody → `observed: jody`. About yourself → your agent peer. About a
host or service → its entity peer (aliases resolve; `pve-extract` reaches
`pvegpu`).

Two rules below live only in the code. Nothing else in the docs records
them, and both are easy to get wrong:

> **`remember` mints unknown names as HUMAN peers.** Never coin a peer. If
> the entity is not promoted, file the fact under jody or yourself and put
> the entity's exact name in `tags` — the review queue files by tags, and
> an operator promotes.

> **Triple-less facts are invisible to the dreamer's conflict pass.** Set
> `subject`/`predicate`/`object` when the fact is a clean triple, because
> the dreamer can only retire triples. Otherwise pass `corrects:` yourself.

`role: guidance` is capped at 20 per pair and is curated — standing
behavioral rules only. Dated one-offs are `episodic_event`; they expire,
and that is the point.

