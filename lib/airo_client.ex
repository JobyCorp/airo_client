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

  ## Capabilities

      AiroClient.chat(%{"model" => "chat-deep", "messages" => [...]})
      AiroClient.embeddings(%{"model" => "embed-fast", "input" => "hello"})
      AiroClient.rerank(%{"model" => "rerank", "query" => "q", "documents" => [...]})
      AiroClient.speech(%{"model" => "tts", "input" => "hi", "voice" => "af_heart"})
      AiroClient.transcribe("/path/to/audio.wav", %{"model" => "whisper"})
      AiroClient.models()
      AiroClient.chat_stream(%{"model" => "chat", "messages" => [...]}, into: self())
  """

  alias AiroClient.Streaming

  @typedoc "An OpenAI-shaped request body (string keys)."
  @type params :: map()

  @typedoc """
  Per-call options. Recognized: `:base_url`, `:api_key`, `:receive_timeout`,
  `:req_options` (merged into the underlying `Req` request — tests install a
  `Req.Test` plug here), and (for `chat_stream/2`) `:into` (the pid to send
  events to; defaults to the caller).
  """
  @type opts :: keyword()

  @type error ::
          {:http, status :: non_neg_integer(), body :: term()}
          | {:transport, reason :: term()}
          | {:config, term()}

  @default_receive_timeout 120_000

  @transcription_fields %{
    "language" => :language,
    "prompt" => :prompt,
    "response_format" => :response_format,
    "temperature" => :temperature
  }

  ## Capabilities

  @doc "Chat completion (non-streaming). `model` is an alias or concrete id."
  @spec chat(params(), opts()) :: {:ok, map()} | {:error, error()}
  def chat(params, opts \\ []) when is_map(params),
    do: json_post("/v1/chat/completions", params, opts)

  @doc "Embeddings."
  @spec embeddings(params(), opts()) :: {:ok, map()} | {:error, error()}
  def embeddings(params, opts \\ []) when is_map(params),
    do: json_post("/v1/embeddings", params, opts)

  @doc "Rerank (Jina/Cohere shape)."
  @spec rerank(params(), opts()) :: {:ok, map()} | {:error, error()}
  def rerank(params, opts \\ []) when is_map(params),
    do: json_post("/v1/rerank", params, opts)

  @doc "Text-to-speech. Returns `{:ok, {audio_binary, content_type}}`."
  @spec speech(params(), opts()) :: {:ok, {binary(), String.t()}} | {:error, error()}
  def speech(params, opts \\ []) when is_map(params) do
    with {:ok, config} <- config(opts) do
      config
      |> build_request(opts)
      |> Req.post(url: "/v1/audio/speech", json: params)
      |> handle_binary()
    end
  end

  @doc """
  Transcription (multipart upload). `audio` is a path, `{bytes, filename}`, or
  `{bytes, filename, content_type}`; `params["model"]` selects the model.
  """
  @spec transcribe(term(), params(), opts()) :: {:ok, map()} | {:error, error()}
  def transcribe(audio, params, opts \\ []) when is_map(params) do
    with {:ok, config} <- config(opts),
         {:ok, parts} <- multipart_parts(audio, params) do
      config
      |> build_request(opts)
      |> Req.post(url: "/v1/audio/transcriptions", form_multipart: parts)
      |> handle_json()
    end
  end

  @doc "List callable model names (aliases + concrete ids), key-scoped."
  @spec models(opts()) :: {:ok, [String.t()]} | {:error, error()}
  def models(opts \\ []) do
    with {:ok, config} <- config(opts) do
      config
      |> build_request(opts)
      |> Req.get(url: "/v1/models")
      |> handle_models()
    end
  end

  @doc """
  Streaming chat. Returns `{:ok, ref}` immediately and sends events to `:into`
  (default the caller):

      {:airo, ref, {:delta, chunk}}    # normalized OpenAI delta
      {:airo, ref, {:done, metadata}}  # x-gateway-* served/fallback/latency
      {:airo, ref, {:error, reason}}
  """
  @spec chat_stream(params(), opts()) :: {:ok, reference()} | {:error, error()}
  def chat_stream(params, opts \\ []) when is_map(params) do
    into = Keyword.get(opts, :into, self())
    ref = make_ref()

    with {:ok, config} <- config(opts) do
      req = build_request(config, opts)
      body = Map.put(params, "stream", true)

      Task.Supervisor.start_child(AiroClient.TaskSupervisor, fn ->
        Streaming.run(req, "/v1/chat/completions", body, into, ref)
      end)

      {:ok, ref}
    end
  end

  ## Internal

  defp json_post(path, body, opts) do
    with {:ok, config} <- config(opts) do
      config
      |> build_request(opts)
      |> Req.post(url: path, json: body)
      |> handle_json()
    end
  end

  @doc false
  def build_request(config, opts) do
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

  defp handle_json({:ok, %Req.Response{status: s, body: body}}) when s in 200..299,
    do: {:ok, body}

  defp handle_json({:ok, %Req.Response{status: s, body: body}}), do: {:error, {:http, s, body}}
  defp handle_json({:error, reason}), do: {:error, {:transport, reason}}

  defp handle_binary({:ok, %Req.Response{status: s, body: body, headers: h}}) when s in 200..299,
    do: {:ok, {body, content_type(h)}}

  defp handle_binary({:ok, %Req.Response{status: s, body: body}}), do: {:error, {:http, s, body}}
  defp handle_binary({:error, reason}), do: {:error, {:transport, reason}}

  defp handle_models({:ok, %Req.Response{status: s, body: %{"data" => data}}}) when s in 200..299,
    do: {:ok, Enum.map(data, & &1["id"])}

  defp handle_models({:ok, %Req.Response{status: s, body: body}}), do: {:error, {:http, s, body}}
  defp handle_models({:error, reason}), do: {:error, {:transport, reason}}

  defp content_type(headers) when is_map(headers) do
    case headers["content-type"] do
      [type | _] -> type
      type when is_binary(type) -> type
      _ -> "application/octet-stream"
    end
  end

  defp multipart_parts(audio, params) do
    with {:ok, file} <- audio_part(audio) do
      extra =
        for {key, atom} <- @transcription_fields,
            (value = params[key]) != nil,
            do: {atom, to_string(value)}

      {:ok, [{:model, params["model"]}, {:file, file} | extra]}
    end
  end

  defp audio_part(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, {bytes, filename: Path.basename(path), content_type: "application/octet-stream"}}

      {:error, reason} ->
        {:error, {:config, "could not read #{path}: #{inspect(reason)}"}}
    end
  end

  defp audio_part({bytes, filename}) when is_binary(bytes),
    do: {:ok, {bytes, filename: filename, content_type: "application/octet-stream"}}

  defp audio_part({bytes, filename, content_type}) when is_binary(bytes),
    do: {:ok, {bytes, filename: filename, content_type: content_type}}

  defp audio_part(_),
    do:
      {:error,
       {:config, "audio must be a path, {bytes, filename}, or {bytes, filename, content_type}"}}

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
