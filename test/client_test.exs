defmodule FlagDash.ClientTest do
  use ExUnit.Case, async: true

  setup do
    name = String.to_atom("flagdash_req_#{System.unique_integer([:positive])}")

    Req.Test.stub(name, fn conn ->
      body =
        case conn.request_path do
          "/api/v1/server/flags" ->
            %{
              "evaluated" => %{"checkout-v2" => true, "theme" => "violet"},
              "flags" => [%{"key" => "checkout-v2"}]
            }

          "/api/v1/server/flags/checkout-v2" ->
            %{
              "flag" => %{
                "key" => "checkout-v2",
                "evaluated_value" => true,
                "evaluation_path" => "rule_match",
                "variation_key" => "on"
              }
            }

          "/api/v1/server/configs/api-url" ->
            %{"config" => %{"key" => "api-url", "value" => "https://api.example.test"}}

          "/api/v1/server/configs" ->
            %{"configs" => [%{"key" => "api-url", "value" => "https://api.example.test"}]}

          "/api/v1/server/ai-configs" ->
            %{
              "ai_configs" => [
                %{
                  "file_name" => "agent.md",
                  "file_type" => "agent",
                  "content" => "Be useful",
                  "folder" => nil
                }
              ]
            }

          "/api/v1/server/ai-configs/agent.md" ->
            %{"ai_config" => %{"file_name" => "agent.md", "content" => "Be useful"}}

          "/api/v1/server/translations/en/common" ->
            %{"catalog" => %{"messages" => %{"welcome" => "Hello {name}"}}}

          "/api/v1/server/experiments/checkout" ->
            %{"experiment" => %{"key" => "checkout", "variant_key" => "b"}}

          "/api/v1/server/experiment-events/batch" ->
            %{"accepted" => 1}

          _ ->
            %{"error" => "not found"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(if(body["error"], do: 404, else: 200), Jason.encode!(body))
    end)

    {:ok, client} =
      FlagDash.Client.new("sk_test",
        base_url: "https://example.test",
        region: "eu-west",
        req_options: [plug: {Req.Test, name}]
      )

    on_exit(fn -> FlagDash.Client.close(client) end)
    %{client: client}
  end

  test "evaluates and caches flags", %{client: client} do
    assert FlagDash.Client.flag(client, "checkout-v2")
    assert FlagDash.Client.flag(client, "theme", %{}, "default") == "violet"
    assert FlagDash.Client.all_flags(client)["checkout-v2"]
  end

  test "returns detailed evaluation and defaults safely", %{client: client} do
    assert %{value: true, reason: "rule_match", variation_key: "on"} =
             FlagDash.Client.flag_detail(client, "checkout-v2", %{user: %{id: "alice"}}, false)

    assert FlagDash.Client.flag(client, "missing", %{}, false) == false
  end

  test "reads configs, AI configs, and translations", %{client: client} do
    assert FlagDash.Client.config(client, "api-url") == "https://api.example.test"
    assert [%{"key" => "api-url"}] = FlagDash.Client.list_configs(client)
    assert FlagDash.Client.ai_config(client, "agent.md")["content"] == "Be useful"
    assert [%{"file_name" => "agent.md"}] = FlagDash.Client.list_ai_configs(client)

    assert FlagDash.Client.translation(client, "common.welcome", "en", variables: %{name: "Ada"}) ==
             "Hello Ada"
  end

  test "assigns experiments only with an identity and records outcomes", %{client: client} do
    assert FlagDash.Client.experiment(client, "checkout", %{}) == nil

    assert FlagDash.Client.experiment(client, "checkout", %{user: %{id: "alice"}})["variant_key"] ==
             "b"

    assert :ok =
             FlagDash.Client.track_experiment_metric(client, %{
               experiment_key: "checkout",
               event_name: "purchase",
               user_id: "alice"
             })
  end

  test "exposes an Erlang-compatible facade", %{client: client} do
    assert :flagdash_sdk.flag(client, "checkout-v2", false)
    assert :flagdash_sdk.config(client, "api-url", nil) == "https://api.example.test"
  end
end
