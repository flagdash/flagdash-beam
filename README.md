# FlagDash SDK for Elixir & Erlang

Feature flags, remote config, AI configs, translations and experiments for the
BEAM.

The client is a plain struct backed by a public ETS cache — no GenServer, no
supervision tree to wire up, and safe to share across processes.

## Installation

```elixir
def deps do
  [{:flagdash, "~> 0.1"}]
end
```

## Quick start

```elixir
{:ok, client} = FlagDash.Client.new(System.fetch_env!("FLAGDASH_SDK_KEY"))

if FlagDash.Client.flag(client, "checkout-v2", %{user_id: "alice"}, false) do
  # new checkout
end

FlagDash.Client.close(client)
```

Hold the client in your application state — `Application.put_env/3`, a
`:persistent_term`, or your own supervision tree — and reuse it. Each `new/2`
creates its own ETS table.

## API key tiers

The key decides which project and environment you read, and what you may reach.
There is no `environment` option anywhere in this SDK — the key carries it.

| Key | Prefix | Reaches |
|---|---|---|
| Client | `pk_` | Flag values and configs. |
| Server | `sk_` | The above, plus targeting rules, translations and experiments. |

## Configuration

```elixir
{:ok, client} =
  FlagDash.Client.new(sdk_key,
    base_url: "https://flagdash.io",   # self-hosted? point it here
    timeout: 5_000,                    # milliseconds
    cache_ttl: 60_000,                 # milliseconds
    region: "eu-west-1",               # omit to auto-detect
    req_options: []                    # passed through to Req
  )
```

`new/2` returns `{:error, :missing_sdk_key}` for an empty key rather than
raising. Region is detected from `FLY_REGION`, `AWS_REGION` and friends when
omitted, so region-scoped targeting works with no wiring.

## Feature flags

```elixir
alias FlagDash.Client

context = %{user_id: "alice", country: "GB"}

Client.flag(client, "checkout-v2", context, false)
Client.all_flags(client, context)

# Why did it resolve that way?
Client.flag_detail(client, "checkout-v2", context)
# %{"value" => true, "reason" => "rule_match", "variation_key" => "treatment"}

# Flag metadata without evaluating anything.
Client.list_flags(client)
```

**Include a `:user_id`** (or `:unit_id`) whenever you want a stable answer.
Percentage rollouts and A/B variations hash it, so a context without one
re-rolls on every call by design.

Any attribute you put in the context map can be targeted on:

```elixir
Client.flag(client, "beta-banner", %{
  user_id: "alice",
  country: "GB",
  plan: "premium"
}, false)
```

## Remote config

```elixir
Client.config(client, "rate_limit", 100)
Client.get_config(client, "rate_limit")   # the full record
Client.list_configs(client)
```

## AI configs

Prompts, agents, skills and rules, versioned per environment and editable
without a deploy.

```elixir
Client.ai_config(client, "support-agent.md")
Client.list_ai_configs(client, file_type: "agent")
```

## Translations

```elixir
Client.translation(client, "checkout.greeting", "fr",
  default: "Hello",
  variables: %{name: "Alice"}
)
```

The key is `namespace.message`. `{placeholders}` come from `:variables`, and
`:default` (falling back to the key itself) is returned whenever the catalogue,
namespace or message is missing — a lookup never raises.

## Experiments

```elixir
case Client.experiment(client, "checkout-redesign", %{user_id: "alice"}) do
  %{"variant" => "treatment"} -> # ...
  _ -> # control, or no assignment
end

Client.track_experiment_metric(client, %{
  experiment_key: "checkout-redesign",
  event_name: "purchase",
  user_id: "alice",
  value: 42.50,
  properties: %{currency: "GBP"}
})
```

`experiment/3` returns `nil` for a context with no identifier — an assignment
that cannot be stable is worse than none.

Unlike the other server SDKs, metrics here are **sent immediately** rather than
buffered: `track_experiment_metric/2` returns `:ok` or `{:error, reason}` and
there is no `flush`. Wrap it in a `Task` if you do not want the caller to wait.

## Caching

Reads are cached in ETS for `:cache_ttl` (60s by default), so a burst of `flag`
calls costs one request.

```elixir
Client.clear_cache(client)
Client.close(client)      # deletes the ETS table
```

`close/1` is what releases the table — a long-lived client never needs it, but a
short-lived one in a test should call it.

## From Erlang

The `flagdash_sdk` module wraps the common calls so you do not need Elixir
syntax:

```erlang
{ok, Client} = flagdash_sdk:new(<<"sk_...">>),
Enabled = flagdash_sdk:flag(Client, <<"checkout-v2">>, #{user_id => <<"alice">>}, false),
flagdash_sdk:close(Client).
```

`new/1,2`, `flag/3,4`, `all_flags/1,2`, `config/3`, `ai_config/2`,
`list_ai_configs/1`, `clear_cache/1` and `close/1` are exported. For anything
else, call `'Elixir.FlagDash.Client'` directly.

## Failure behaviour

Evaluation reads return the default you passed rather than raising, so an
outage degrades to your fallback values instead of taking a request path down.
Calls that fetch metadata return `{:ok, _}` / `{:error, _}` so an unreachable
host or a bad key stays visible.

## Security

Keep a server key on the server. A client key never receives targeting rules,
so an untrusted client cannot see who else you are targeting.

## License

MIT
## Backend session replay

```elixir
{:ok, replay} = FlagDash.BackendReplay.start_link(sdk_key: System.fetch_env!("FLAGDASH_REPLAY_KEY"), release: "2026.08")

if FlagDash.BackendReplay.start(replay) do
  FlagDash.BackendReplay.event(replay, "checkout_started", "action", %{items: 2})
  FlagDash.BackendReplay.breadcrumb(replay, "payment requested")
end

FlagDash.BackendReplay.stop(replay)
```

The recorder is opt-in and captures only explicit events. Sensitive keys are redacted and `context_headers/1` returns the opaque correlation header. Use a `replays:write` key and supervise the process for long-lived traces.
