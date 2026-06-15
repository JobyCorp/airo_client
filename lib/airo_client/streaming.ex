defmodule AiroClient.Streaming do
  @moduledoc """
  Consumes Airo's chat SSE stream and forwards events to a caller process as
  messages. Airo emits `data: {delta}` lines, a trailing
  `event: gateway.metadata` (the transparency trailer), and a final
  `data: [DONE]` sentinel — so unlike a plain delta parser, this reads the
  `event:` field to distinguish the metadata/error trailers from deltas.

  Runs synchronously in whatever process calls `run/5` (a task, in normal use).
  """

  @doc """
  Stream `body` to `path` on `req`, sending to `into` (tagged with `ref`):

      {:airo, ref, {:delta, chunk}}
      {:airo, ref, {:done, metadata}}
      {:airo, ref, {:error, reason}}
  """
  @spec run(Req.Request.t(), String.t(), map(), pid(), reference()) :: :ok
  def run(req, path, body, into, ref) do
    init = %{buffer: "", err: "", into: into, ref: ref}

    req
    |> Req.post(
      url: path,
      json: body,
      into: fn
        {:data, data}, {request, resp} ->
          state = Req.Response.get_private(resp, :airo_sse, init)

          state =
            if resp.status in 200..299,
              do: consume(data, state),
              else: %{state | err: state.err <> data}

          {:cont, {request, Req.Response.put_private(resp, :airo_sse, state)}}

        _other, acc ->
          {:cont, acc}
      end
    )
    |> finish(into, ref, init)
  end

  defp finish({:ok, %Req.Response{status: status}}, _into, _ref, _init) when status in 200..299 do
    # Deltas + the {:done, …} trailer were already sent inline.
    :ok
  end

  defp finish({:ok, %Req.Response{status: status} = resp}, into, ref, init) do
    err = Req.Response.get_private(resp, :airo_sse, init).err
    send(into, {:airo, ref, {:error, {:http, status, decode_error(err)}}})
    :ok
  end

  defp finish({:error, reason}, into, ref, _init) do
    send(into, {:airo, ref, {:error, {:transport, reason}}})
    :ok
  end

  ## SSE

  defp consume(data, state) do
    {events, rest} = split_events(state.buffer <> data)
    Enum.each(events, &dispatch(parse_event(&1), state))
    %{state | buffer: rest}
  end

  defp dispatch({:event, "gateway.metadata", data}, state),
    do: emit(state, {:done, decode(data, %{})})

  defp dispatch({:event, "gateway.error", data}, state),
    do: emit(state, {:error, decode(data, %{})})

  defp dispatch({:data, "[DONE]"}, _state), do: :ok
  defp dispatch({:data, json}, state), do: emit(state, {:delta, decode(json, nil)})
  defp dispatch(:ignore, _state), do: :ok

  defp emit(_state, {:delta, nil}), do: :ok
  defp emit(state, event), do: send(state.into, {:airo, state.ref, event})

  defp split_events(buffer) do
    case String.split(buffer, ~r/\r?\n\r?\n/) do
      [only] -> {[], only}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp parse_event(raw_event) do
    lines = String.split(raw_event, ~r/\r?\n/)

    event =
      Enum.find_value(lines, fn
        "event:" <> rest -> String.trim(rest)
        _ -> nil
      end)

    data =
      lines
      |> Enum.flat_map(fn
        "data:" <> rest -> [String.trim_leading(rest, " ")]
        _ -> []
      end)
      |> Enum.join("\n")

    cond do
      data == "" -> :ignore
      event != nil -> {:event, event, data}
      true -> {:data, data}
    end
  end

  defp decode(json, default) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      {:error, _} -> default
    end
  end

  defp decode_error(""), do: %{}
  defp decode_error(raw), do: decode(raw, raw)
end
