defmodule AiroClientTest do
  use ExUnit.Case, async: true

  @completion %{
    "id" => "chatcmpl-1",
    "object" => "chat.completion",
    "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "hi"}}]
  }

  defp opts(stub),
    do: [
      base_url: "http://airo.test",
      api_key: "airo_test",
      req_options: [plug: {Req.Test, stub}]
    ]

  describe "chat/2" do
    test "posts to /v1/chat/completions with bearer auth and returns the body" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          test_pid,
          {:req, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
           Jason.decode!(raw)}
        )

        Req.Test.json(conn, @completion)
      end)

      params = %{"model" => "qwen3.5-9b", "messages" => [%{"role" => "user", "content" => "yo"}]}
      assert {:ok, body} = AiroClient.chat(params, opts(__MODULE__))

      assert body["choices"] |> hd() |> get_in(["message", "content"]) == "hi"
      assert_received {:req, "/v1/chat/completions", ["Bearer airo_test"], sent}
      assert sent["model"] == "qwen3.5-9b"
    end

    test "maps a non-2xx to {:error, {:http, status, body}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"code" => "model_not_found"}})
      end)

      assert {:error, {:http, 404, %{"error" => %{"code" => "model_not_found"}}}} =
               AiroClient.chat(%{"model" => "ghost", "messages" => []}, opts(__MODULE__))
    end

    test "maps a transport failure to {:error, {:transport, _}}" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:transport, _}} =
               AiroClient.chat(%{"model" => "x", "messages" => []}, opts(__MODULE__))
    end
  end

  describe "other capabilities" do
    test "embeddings/2 posts to /v1/embeddings" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/embeddings"
        Req.Test.json(conn, %{"data" => [%{"embedding" => [0.1, 0.2]}]})
      end)

      assert {:ok, %{"data" => [%{"embedding" => [0.1, 0.2]}]}} =
               AiroClient.embeddings(%{"model" => "bge", "input" => "x"}, opts(__MODULE__))
    end

    test "rerank/2 posts to /v1/rerank" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/rerank"
        Req.Test.json(conn, %{"results" => [%{"index" => 0, "relevance_score" => 0.9}]})
      end)

      assert {:ok, %{"results" => _}} =
               AiroClient.rerank(
                 %{"model" => "rr", "query" => "q", "documents" => ["a"]},
                 opts(__MODULE__)
               )
    end

    test "speech/2 returns binary audio + content type" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg", nil)
        |> Plug.Conn.send_resp(200, <<1, 2, 3>>)
      end)

      assert {:ok, {<<1, 2, 3>>, "audio/mpeg"}} =
               AiroClient.speech(%{"model" => "tts", "input" => "hi"}, opts(__MODULE__))
    end

    test "transcribe/3 uploads multipart and returns JSON" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        [ct] = Plug.Conn.get_req_header(conn, "content-type")
        send(test_pid, {:ct, ct})
        Req.Test.json(conn, %{"text" => "transcribed"})
      end)

      path = Path.join(System.tmp_dir!(), "airo-#{System.unique_integer([:positive])}.wav")
      File.write!(path, "RIFFfake")

      assert {:ok, %{"text" => "transcribed"}} =
               AiroClient.transcribe(path, %{"model" => "whisper"}, opts(__MODULE__))

      assert_received {:ct, "multipart/form-data" <> _}
      File.rm(path)
    end

    test "transcribe/3 accepts in-memory bytes" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"text" => "ok"}) end)

      assert {:ok, %{"text" => "ok"}} =
               AiroClient.transcribe({"RIFF", "a.wav"}, %{"model" => "whisper"}, opts(__MODULE__))
    end

    test "models/1 returns the list of ids" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET" and conn.request_path == "/v1/models"

        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [%{"id" => "chat"}, %{"id" => "qwen3.5-9b"}]
        })
      end)

      assert {:ok, ["chat", "qwen3.5-9b"]} = AiroClient.models(opts(__MODULE__))
    end
  end

  describe "config" do
    test "missing base_url or api_key returns {:error, {:config, _}}" do
      assert {:error, {:config, _}} = AiroClient.chat(%{"messages" => []}, api_key: "k")
      assert {:error, {:config, _}} = AiroClient.chat(%{"messages" => []}, base_url: "http://x")
    end
  end
end
