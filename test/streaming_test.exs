defmodule AiroClient.StreamingTest do
  use ExUnit.Case, async: true

  alias AiroClient.Streaming

  @sse """
  data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}

  data: {"choices":[{"index":0,"delta":{"content":"He"}}]}

  data: {"choices":[{"index":0,"delta":{"content":"llo"}}]}

  event: gateway.metadata
  data: {"provider":"vllm","model":"qwen3.5-9b","fallback_used":false,"latency_ms":42}

  data: [DONE]

  """

  # A Req with a test plug, built directly so we exercise Streaming.run/5
  # synchronously in this process (so the Req.Test stub is owned here).
  defp req(stub),
    do: Req.new(plug: {Req.Test, stub}, retry: false, decode_json: [keys: :strings])

  test "forwards deltas then a {:done, metadata} trailer, dropping [DONE]" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, @sse)
    end)

    ref = make_ref()

    assert :ok =
             Streaming.run(
               req(__MODULE__),
               "/v1/chat/completions",
               %{"model" => "x"},
               self(),
               ref
             )

    assert_received {:airo, ^ref,
                     {:delta, %{"choices" => [%{"delta" => %{"role" => "assistant"}}]}}}

    assert_received {:airo, ^ref, {:delta, %{"choices" => [%{"delta" => %{"content" => "He"}}]}}}
    assert_received {:airo, ^ref, {:delta, %{"choices" => [%{"delta" => %{"content" => "llo"}}]}}}
    assert_received {:airo, ^ref, {:done, %{"model" => "qwen3.5-9b", "fallback_used" => false}}}
    # [DONE] is consumed, not forwarded.
    refute_received {:airo, ^ref, {:delta, %{}}}
  end

  test "non-2xx surfaces as an {:error, {:http, status, body}} event" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
    end)

    ref = make_ref()
    Streaming.run(req(__MODULE__), "/v1/chat/completions", %{"model" => "x"}, self(), ref)

    assert_received {:airo, ^ref, {:error, {:http, 503, %{"error" => "down"}}}}
  end

  test "transport failure surfaces as an {:error, {:transport, _}} event" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    ref = make_ref()
    Streaming.run(req(__MODULE__), "/v1/chat/completions", %{"model" => "x"}, self(), ref)

    assert_received {:airo, ^ref, {:error, {:transport, _}}}
  end
end
