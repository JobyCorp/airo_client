defmodule AiroClient do
  @moduledoc """
  Elixir client for the [Airo](../airo) gateway — the thin, server-to-server
  client that incogito and orchester use instead of `openai_ex`.

  It owns *everything app↔Airo* and nothing browser-facing (see Airo's
  `DESIGN-realtime-and-client.md`). Airo is OpenAI-compatible, so `model` may be
  either an **alias** (e.g. `"chat-deep"`) or a **concrete deployment id** (e.g.
  `"qwen3.5-9b"`) — Airo resolves both.

  ## Config

      config :airo_client,
        base_url: "http://airo.internal:4000",   # private; server-to-server
        api_key:  System.get_env("AIRO_CLIENT_KEY"),
        receive_timeout: 120_000                  # generous default for slow models

  Any of `:base_url`, `:api_key`, `:receive_timeout` can be overridden per call
  via opts.

  ## Example

      AiroClient.chat(%{
        "model" => "qwen3.5-9b",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      #=> {:ok, %{"choices" => [...], ...}}
  """

  @typedoc "An OpenAI-shaped request body (string keys)."
  @type params :: map()

  @typedoc """
  Per-call options. Recognized keys: `:base_url`, `:api_key`, `:receive_timeout`,
  and `:req_options` (extra options merged into the underlying `Req` request —
  used by tests to install a `Req.Test` plug).
  """
  @type opts :: keyword()

  @type error ::
          {:http, status :: non_neg_integer(), body :: term()}
          | {:transport, reason :: term()}
          | {:config, term()}

  @default_receive_timeout 120_000

  @doc """
  Create a chat completion (non-streaming). `params["model"]` is an alias or a
  concrete deployment id. Returns the OpenAI-shaped response body.
  """
  @spec chat(params(), opts()) :: {:ok, map()} | {:error, error()}
  def chat(params, opts \\ []) when is_map(params) do
    post("/v1/chat/completions", params, opts)
  end

  ## Internal

  defp post(path, body, opts) do
    with {:ok, config} <- config(opts) do
      config
      |> build_request(opts)
      |> Req.post(url: path, json: body)
      |> handle()
    end
  end

  defp build_request(config, opts) do
    [
      base_url: config.base_url,
      headers: [{"authorization", "Bearer " <> config.api_key}],
      receive_timeout: config.receive_timeout,
      # Airo owns failover; the client must not re-dispatch.
      retry: false,
      decode_json: [keys: :strings]
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.new()
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:http, status, body}}
  end

  defp handle({:error, reason}), do: {:error, {:transport, reason}}

  defp config(opts) do
    with {:ok, base_url} <- fetch(opts, :base_url),
         {:ok, api_key} <- fetch(opts, :api_key) do
      {:ok,
       %{
         base_url: base_url,
         api_key: api_key,
         receive_timeout:
           opts[:receive_timeout] ||
             Application.get_env(:airo_client, :receive_timeout, @default_receive_timeout)
       }}
    end
  end

  defp fetch(opts, key) do
    case opts[key] || Application.get_env(:airo_client, key) do
      nil -> {:error, {:config, "airo_client #{inspect(key)} is not configured"}}
      value -> {:ok, value}
    end
  end
end
