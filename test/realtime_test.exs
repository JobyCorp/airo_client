defmodule AiroClient.RealtimeTest do
  # Drives the relay against real Bandit WebSocket upstreams. connect/3 opens the
  # Mint socket in *this* process, so its messages arrive here and we feed them to
  # stream/2 — exercising the full relay without a consumer WebSock handler.
  use ExUnit.Case, async: false

  alias AiroClient.Realtime

  @echo_port 4321
  @reject_port 4322

  defp opts(port), do: [base_url: "http://localhost:#{port}", api_key: "airo_test_key"]

  describe "target/3" do
    test "builds a ws target with the /v1/realtime path, query and bearer" do
      assert {:ok, target} =
               Realtime.target("whisper", "transcription", opts(@echo_port))

      assert target.ws_scheme == :ws
      assert target.host == "localhost"
      assert target.port == @echo_port
      assert target.path =~ "/v1/realtime"
      assert target.path =~ "model=whisper"
      assert target.path =~ "intent=transcription"
      assert target.headers == [{"authorization", "Bearer airo_test_key"}]
    end

    test "uses wss/443 for an https base_url and tolerates a trailing /v1" do
      assert {:ok, target} =
               Realtime.target("m", "transcription",
                 base_url: "https://airo.internal/v1",
                 api_key: "k"
               )

      assert target.ws_scheme == :wss
      assert target.host == "airo.internal"
      assert target.port == 443
      assert target.path =~ "/v1/realtime"
    end

    test "trims stray whitespace in the model id" do
      assert {:ok, target} =
               Realtime.target("  whisper ", "transcription", opts(@echo_port))

      assert target.path =~ "model=whisper"
      refute target.path =~ "model=+"
    end

    test "errors when base_url / api_key are unconfigured" do
      assert {:error, {:config, _}} = Realtime.target("m", "transcription", api_key: "k")
      assert {:error, {:config, _}} = Realtime.target("m", "transcription", base_url: "http://x")
    end
  end

  describe "relay against a live echo upstream" do
    setup do
      start_supervised!({AiroClient.Test.EchoServer, port: @echo_port})
      :ok
    end

    test "relays a frame upstream and the echo back as an event" do
      assert {:ok, up} = Realtime.connect("echo", "transcription", opts(@echo_port))
      up = pump_until_open(up)

      assert {:ok, up} = Realtime.send_frame(up, {:text, "hello realtime"})

      {events, _up} = recv_events(up)
      assert {:frame, {:text, "hello realtime"}} in events
    end

    test "buffers frames sent before open, then flushes them on open" do
      assert {:ok, up} = Realtime.connect("echo", "transcription", opts(@echo_port))

      # Sent while still connecting → buffered.
      assert {:ok, up} = Realtime.send_frame(up, {:text, "early"})
      assert up.status == :connecting

      up = pump_until_open(up)
      {events, _up} = recv_events(up)
      assert {:frame, {:text, "early"}} in events
    end
  end

  describe "relay against an upstream that rejects the upgrade" do
    setup do
      start_supervised!({AiroClient.Test.RejectServer, port: @reject_port})
      :ok
    end

    test "surfaces a {:close, 1011, _} event instead of crashing" do
      assert {:ok, up} = Realtime.connect("ghost", "transcription", opts(@reject_port))

      events = pump_until_close(up)
      assert Enum.any?(events, &match?({:close, 1011, _}, &1))
    end
  end

  ## helpers

  defp pump_until_open(%Realtime{status: :open} = up), do: up

  defp pump_until_open(up) do
    receive do
      message ->
        case Realtime.stream(up, message) do
          {:ok, up, _events} -> pump_until_open(up)
          other -> flunk("unexpected stream result before open: #{inspect(other)}")
        end
    after
      5_000 -> flunk("timed out waiting for the upstream to open")
    end
  end

  defp recv_events(up) do
    receive do
      message ->
        case Realtime.stream(up, message) do
          {:ok, up, []} -> recv_events(up)
          {:ok, up, events} -> {events, up}
        end
    after
      5_000 -> flunk("timed out waiting for a relay event")
    end
  end

  defp pump_until_close(up) do
    receive do
      message ->
        case Realtime.stream(up, message) do
          {:ok, _up, events} ->
            if Enum.any?(events, &match?({:close, _, _}, &1)),
              do: events,
              else: pump_until_close(up)

          {:error, _up, reason} ->
            flunk("expected a close event, got error: #{inspect(reason)}")
        end
    after
      5_000 -> flunk("timed out waiting for a close event")
    end
  end
end
