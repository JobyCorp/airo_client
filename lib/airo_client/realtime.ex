defmodule AiroClient.Realtime do
  @moduledoc """
  Server-to-server relay to Airo's realtime WebSocket (`/v1/realtime`).

  The consumer app terminates the **browser** WebSocket itself — it owns
  authentication and the public URL, and the browser must never reach Airo
  directly (Airo is private; see Airo's `DESIGN-realtime-and-client.md` §4). This
  module owns the **other leg**: the `Mint.WebSocket` connection to Airo, carrying
  the client key as a `Bearer`, relaying frames transparently in both directions.
  Airo in turn brokers the connection to the provider (e.g. Speaches).

  It's a plain data wrapper driven from the consumer's own `WebSock` callbacks —
  not a process. Open it in `init/1`, push browser frames through `send_frame/2`,
  feed socket messages through `stream/2`, and `close/1` on terminate:

      {:ok, up} = AiroClient.Realtime.connect("whisper", "transcription", base_url: ..., api_key: ...)
      {:ok, up} = AiroClient.Realtime.send_frame(up, {:text, msg})        # browser → Airo
      {:ok, up, events} = AiroClient.Realtime.stream(up, tcp_message)     # Airo → browser

  `stream/2` returns normalized `t:event/0`s — `:open`, `{:frame, frame}` (relay
  verbatim to the browser), `{:close, code, reason}` (end the browser session) —
  so the consumer never touches Mint. Frames sent before the upstream handshake
  completes are buffered and flushed on open.

  Connect-time routing only (Airo picks the upstream); a mid-session upstream
  failure surfaces as a `{:close, …}` event or an `{:error, …}` and the consumer
  ends the browser session.

  ## Example `WebSock` handler

      @impl true
      def init(state) do
        case AiroClient.Realtime.connect(state.model, state.intent, state.airo_opts) do
          {:ok, up} -> {:ok, %{state | up: up}}
          {:error, _} -> {:stop, :normal, {1011, "voice gateway unavailable"}, state}
        end
      end

      @impl true
      def handle_in({data, [opcode: op]}, state) do
        case AiroClient.Realtime.send_frame(state.up, {op, data}) do
          {:ok, up} -> {:ok, %{state | up: up}}
          {:error, up, _} -> {:stop, :normal, 1011, %{state | up: up}}
        end
      end

      @impl true
      def handle_info(msg, state) do
        case AiroClient.Realtime.stream(state.up, msg) do
          {:ok, up, events} -> AiroClient.Realtime.apply_events(events, %{state | up: up})
          {:error, up, _} -> {:stop, :normal, {1011, "upstream error"}, %{state | up: up}}
          :unknown -> {:ok, state}
        end
      end
  """

  alias AiroClient.Realtime

  @enforce_keys [:conn, :ref]
  defstruct [:conn, :ref, :websocket, :upstream_status, status: :connecting, pending: []]

  @typedoc "An opaque realtime relay connection."
  @opaque t :: %Realtime{
            conn: Mint.HTTP.t() | nil,
            ref: Mint.Types.request_ref(),
            websocket: Mint.WebSocket.t() | nil,
            upstream_status: non_neg_integer() | nil,
            status: :connecting | :open | :closed,
            pending: [frame()]
          }

  @typedoc "A WebSocket frame relayed verbatim."
  @type frame :: {:text | :binary | :ping | :pong, binary()}

  @typedoc """
  A normalized relay event from `stream/2`:

    * `:open` — the upstream handshake completed (buffered frames were flushed)
    * `{:frame, frame}` — relay this frame verbatim to the browser
    * `{:close, code, reason}` — the session ended; close the browser with this detail
  """
  @type event ::
          :open
          | {:frame, frame()}
          | {:close, code :: non_neg_integer(), reason :: binary()}

  @type error :: {:transport, term()} | {:config, term()}

  @doc """
  Open a relay to Airo's `/v1/realtime` for `model` + `intent`.

  Config (`:base_url`, `:api_key`, and an optional `:connect_timeout`) is resolved
  from `opts` then `:airo_client` app env, same as the rest of the client — so a
  trailing `/v1` on `base_url` is tolerated. `model` may be an alias or a concrete
  deployment id; `intent` is the realtime intent (e.g. `"transcription"`).
  """
  @spec connect(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def connect(model, intent, opts \\ []) when is_binary(model) and is_binary(intent) do
    with {:ok, target} <- target(model, intent, opts) do
      do_connect(target, opts)
    end
  end

  @doc """
  Resolve `model` + `intent` to an upstream WS target without connecting — the
  ws(s) scheme/host/port/path and the `Bearer` header. Exposed for callers that
  resolve and connect separately (and for testing).
  """
  @spec target(String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             ws_scheme: :ws | :wss,
             host: String.t(),
             port: :inet.port_number(),
             path: String.t(),
             headers: [{String.t(), String.t()}]
           }}
          | {:error, error()}
  def target(model, intent, opts \\ []) when is_binary(model) and is_binary(intent) do
    with {:ok, config} <- AiroClient.config(opts) do
      uri = URI.parse(config.base_url)
      query = URI.encode_query(%{"model" => String.trim(model), "intent" => intent})

      {:ok,
       %{
         ws_scheme: ws_scheme(uri.scheme),
         host: uri.host,
         port: uri.port || default_port(uri.scheme),
         path: "/v1/realtime?" <> query,
         headers: [{"authorization", "Bearer " <> config.api_key}]
       }}
    end
  end

  @doc """
  Send a frame to the upstream (browser → Airo). Frames sent before the handshake
  completes are buffered and flushed on open. A no-op once closed.
  """
  @spec send_frame(t(), frame()) :: {:ok, t()} | {:error, t(), error()}
  def send_frame(%Realtime{status: :open} = state, frame), do: do_send(state, frame)

  def send_frame(%Realtime{status: :connecting} = state, frame),
    do: {:ok, %{state | pending: [frame | state.pending]}}

  def send_frame(%Realtime{status: :closed} = state, _frame), do: {:ok, state}

  @doc """
  Feed a process message (a TCP/SSL message from the upstream socket) and get
  back normalized events (Airo → browser). Returns `:unknown` for messages that
  aren't ours (pass them to your other `handle_info` clauses).
  """
  @spec stream(t(), term()) :: {:ok, t(), [event()]} | {:error, t(), error()} | :unknown
  def stream(%Realtime{conn: conn} = state, message) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        process(responses, %{state | conn: conn}, [])

      {:error, conn, reason, _responses} ->
        {:error, %{state | conn: conn, status: :closed}, {:transport, reason}}

      :unknown ->
        :unknown
    end
  end

  def stream(_state, _message), do: :unknown

  @doc "Close the upstream connection. Idempotent."
  @spec close(t()) :: :ok
  def close(%Realtime{conn: conn}) when not is_nil(conn) do
    Mint.HTTP.close(conn)
    :ok
  end

  def close(_state), do: :ok

  @doc """
  Convenience for `WebSock` `handle_info`: fold `stream/2` events into a WebSock
  return — push relayed frames, and stop with the close detail if the session
  ended.
  """
  @spec apply_events([event()], state) ::
          {:push, [frame()], state}
          | {:stop, :normal, {non_neg_integer(), binary()}, [frame()], state}
        when state: term()
  def apply_events(events, state) do
    {pushes, close} =
      Enum.reduce(events, {[], nil}, fn
        _event, {pushes, {_code, _reason} = close} -> {pushes, close}
        {:frame, frame}, {pushes, nil} -> {[frame | pushes], nil}
        {:close, code, reason}, {pushes, nil} -> {pushes, {code, reason}}
        :open, acc -> acc
      end)

    pushes = Enum.reverse(pushes)

    case close do
      nil -> {:push, pushes, state}
      detail -> {:stop, :normal, detail, pushes, state}
    end
  end

  ## ── connect / send ───────────────────────────────────────────────

  defp do_connect(target, opts) do
    http_scheme = if target.ws_scheme == :wss, do: :https, else: :http
    connect_opts = [protocols: [:http1]] |> maybe_timeout(opts)

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, target.host, target.port, connect_opts),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(target.ws_scheme, conn, target.path, target.headers) do
      {:ok, %Realtime{conn: conn, ref: ref}}
    else
      {:error, reason} -> {:error, {:transport, reason}}
      {:error, _conn, reason} -> {:error, {:transport, reason}}
    end
  end

  defp maybe_timeout(connect_opts, opts) do
    case opts[:connect_timeout] do
      nil -> connect_opts
      timeout -> Keyword.put(connect_opts, :timeout, timeout)
    end
  end

  defp do_send(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | websocket: websocket, conn: conn}}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, %{state | websocket: websocket}, {:transport, reason}}

      {:error, conn, reason} ->
        {:error, %{state | conn: conn}, {:transport, reason}}
    end
  end

  defp flush_pending(%{pending: pending} = state) do
    state = %{state | pending: []}

    Enum.reduce(Enum.reverse(pending), state, fn frame, state ->
      case do_send(state, frame) do
        {:ok, state} -> state
        {:error, state, _reason} -> state
      end
    end)
  end

  ## ── inbound response processing (Airo → browser) ─────────────────

  # Fold Mint responses into events (chronological). The accumulator is
  # newest-first and reversed on return.
  defp process([], state, events), do: {:ok, state, Enum.reverse(events)}

  defp process([{:status, ref, status} | rest], %{ref: ref} = state, events),
    do: process(rest, %{state | upstream_status: status}, events)

  defp process([{:headers, ref, headers} | rest], %{ref: ref} = state, events) do
    case Mint.WebSocket.new(state.conn, ref, state.upstream_status, headers) do
      {:ok, conn, websocket} ->
        state = flush_pending(%{state | conn: conn, websocket: websocket, status: :open})
        process(rest, state, [:open | events])

      {:error, conn, _reason} ->
        # Upstream rejected the upgrade (e.g. Airo 404 model_not_found).
        finish(%{state | conn: conn}, [{:close, 1011, "upstream upgrade failed"} | events])
    end
  end

  defp process([{:data, ref, data} | rest], %{ref: ref, status: :open} = state, events) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        {events, closed?} = collect(frames, events)
        state = %{state | websocket: websocket}
        if closed?, do: finish(state, events), else: process(rest, state, events)

      {:error, websocket, _reason} ->
        finish(%{state | websocket: websocket}, [{:close, 1011, "decode error"} | events])
    end
  end

  defp process([_other | rest], state, events), do: process(rest, state, events)

  defp finish(state, events), do: {:ok, %{state | status: :closed}, Enum.reverse(events)}

  # Map decoded upstream frames to relay events (verbatim); an upstream close
  # becomes a terminal `{:close, …}` (later frames are dropped — session ending).
  defp collect(frames, events) do
    Enum.reduce(frames, {events, false}, fn
      _frame, {events, true} ->
        {events, true}

      {opcode, data}, {events, false} when opcode in [:text, :binary, :ping, :pong] ->
        {[{:frame, {opcode, data}} | events], false}

      {:close, code, reason}, {events, false} ->
        {[{:close, code || 1000, reason || ""} | events], true}

      :close, {events, false} ->
        {[{:close, 1000, ""} | events], true}

      _other, acc ->
        acc
    end)
  end

  defp ws_scheme("https"), do: :wss
  defp ws_scheme("http"), do: :ws
  defp ws_scheme("wss"), do: :wss
  defp ws_scheme("ws"), do: :ws

  defp default_port(scheme) when scheme in ["https", "wss"], do: 443
  defp default_port(_scheme), do: 80
end
