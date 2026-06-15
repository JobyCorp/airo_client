defmodule AiroClientTest do
  use ExUnit.Case, async: true

  @completion %{
    "id" => "chatcmpl-1",
    "object" => "chat.completion",
    "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "hi"}}]
  }

  defp opts(stub),
    do: [base_url: "http://airo.test", api_key: "airo_test", req_options: [plug: {Req.Test, stub}]]

  test "chat/2 posts to /v1/chat/completions with bearer auth and returns the body" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(raw)})
      Req.Test.json(conn, @completion)
    end)

    params = %{"model" => "qwen3.5-9b", "messages" => [%{"role" => "user", "content" => "yo"}]}
    assert {:ok, body} = AiroClient.chat(params, opts(__MODULE__))

    assert body["choices"] |> hd() |> get_in(["message", "content"]) == "hi"
    assert_received {:req, "/v1/chat/completions", ["Bearer airo_test"], sent}
    assert sent["model"] == "qwen3.5-9b"
  end

  test "chat/2 maps a non-2xx to {:error, {:http, status, body}}" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => %{"code" => "model_not_found"}})
    end)

    assert {:error, {:http, 404, %{"error" => %{"code" => "model_not_found"}}}} =
             AiroClient.chat(%{"model" => "ghost", "messages" => []}, opts(__MODULE__))
  end

  test "chat/2 maps a transport failure to {:error, {:transport, _}}" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, {:transport, _}} =
             AiroClient.chat(%{"model" => "x", "messages" => []}, opts(__MODULE__))
  end

  test "missing config returns {:error, {:config, _}}" do
    assert {:error, {:config, _}} = AiroClient.chat(%{"messages" => []}, api_key: "k")
    assert {:error, {:config, _}} = AiroClient.chat(%{"messages" => []}, base_url: "http://x")
  end
end
