defmodule FlagDash.BackendReplayTest do
  use ExUnit.Case, async: true

  test "uploads a bounded redacted backend timeline" do
    owner = self()
    name = String.to_atom("flagdash_replay_req_#{System.unique_integer([:positive])}")

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, conn.request_path, body})

      response =
        case conn.request_path do
          "/api/v1/replay-sessions/start" ->
            %{"id" => "rpl_elixir"}

          "/api/v1/replay-sessions/rpl_elixir/chunks/presign" ->
            %{"upload" => %{"url" => "https://example.test/upload", "headers" => %{}}}

          _ ->
            %{}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end)

    {:ok, replay} =
      FlagDash.BackendReplay.start_link(
        sdk_key: "sk_test",
        base_url: "https://example.test",
        req_options: [plug: {Req.Test, name}],
        metadata: %{api_key: "hidden"}
      )

    assert FlagDash.BackendReplay.start(replay)

    FlagDash.BackendReplay.event(replay, "checkout_started", "action", %{
      password: "hidden",
      items: 2
    })

    assert FlagDash.BackendReplay.context_headers(replay) == %{
             "x-flagdash-replay-id" => "rpl_elixir"
           }

    assert :ok = FlagDash.BackendReplay.flush(replay)
    assert_receive {:request, "/upload", uploaded}
    assert uploaded =~ "checkout_started"
    refute uploaded =~ ~s("hidden")
    FlagDash.BackendReplay.stop(replay)
  end
end
