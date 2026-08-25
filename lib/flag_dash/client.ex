defmodule FlagDash.Client do
  @moduledoc """
  Server-side FlagDash client with explicit endpoint tier and bounded TTL cache.

  The client is a value, not a background process. It owns a private ETS table
  for cached reads and starts no timer while idle. Call `close/1` when the
  process that created a long-lived client no longer needs it.
  """

  @default_base_url "https://flagdash.io"
  @default_timeout 5_000
  @default_cache_ttl 60_000

  @type context :: map()
  @type option ::
          {:base_url, String.t()}
          | {:timeout, non_neg_integer()}
          | {:cache_ttl, non_neg_integer()}
          | {:region, String.t() | nil}
          | {:req_options, keyword()}

  @type t :: %__MODULE__{
          sdk_key: String.t(),
          base_url: String.t(),
          timeout: non_neg_integer(),
          cache_ttl: non_neg_integer(),
          region: String.t() | nil,
          cache: :ets.tid(),
          req_options: keyword()
        }

  defstruct [:sdk_key, :base_url, :timeout, :cache_ttl, :region, :cache, req_options: []]

  @spec new(String.t(), [option()]) :: {:ok, t()} | {:error, :missing_sdk_key}
  def new(sdk_key, opts \\ [])

  def new(sdk_key, opts) when is_binary(sdk_key) and byte_size(sdk_key) > 0 do
    cache = :ets.new(:flagdash_sdk_cache, [:set, :public, read_concurrency: true])

    {:ok,
     %__MODULE__{
       sdk_key: sdk_key,
       base_url: opts |> Keyword.get(:base_url, @default_base_url) |> String.trim_trailing("/"),
       timeout: Keyword.get(opts, :timeout, @default_timeout),
       cache_ttl: Keyword.get(opts, :cache_ttl, @default_cache_ttl),
       region: Keyword.get(opts, :region, detect_region()),
       cache: cache,
       req_options: Keyword.get(opts, :req_options, [])
     }}
  end

  def new(_, _), do: {:error, :missing_sdk_key}

  @spec flag(t(), String.t(), context(), term()) :: term()
  def flag(client, key, context \\ %{}, default \\ false) do
    if map_size(context) == 0 do
      case cached(client, {:flag, key}) do
        {:ok, value} -> value
        :miss -> client |> all_flags() |> Map.get(key, default)
      end
    else
      case flag_detail(client, key, context, default) do
        %{value: value} -> value
        _ -> default
      end
    end
  end

  @spec flag_detail(t(), String.t(), context(), term()) :: map()
  def flag_detail(client, key, context \\ %{}, default \\ nil) do
    case request(client, :get, "/server/flags/#{encode_segment(key)}",
           params: context_params(client, context)
         ) do
      {:ok, %{"flag" => flag}} ->
        %{
          key: flag["key"] || key,
          value: Map.get(flag, "evaluated_value", default),
          reason: flag["evaluation_path"] || "default",
          variation_key: flag["variation_key"]
        }

      {:error, _} ->
        %{key: key, value: default, reason: "default", variation_key: nil}
    end
  end

  @spec all_flags(t(), context()) :: map()
  def all_flags(client, context \\ %{}) do
    if map_size(context) == 0 do
      case cached(client, :all_flags) do
        {:ok, values} -> values
        :miss -> fetch_all_flags(client, context)
      end
    else
      fetch_all_flags(client, context)
    end
  end

  @spec list_flags(t()) :: [map()]
  def list_flags(client) do
    case request(client, :get, "/server/flags", params: context_params(client, %{})) do
      {:ok, %{"flags" => flags}} when is_list(flags) -> flags
      _ -> []
    end
  end

  @spec config(t(), String.t(), term()) :: term()
  def config(client, key, default \\ nil) do
    with :miss <- cached(client, {:config, key}),
         {:ok, %{"config" => config}} <-
           request(client, :get, "/server/configs/#{encode_segment(key)}") do
      value = Map.get(config, "value", default)
      put_cache(client, {:config, key}, value)
      value
    else
      {:ok, value} -> value
      _ -> default
    end
  end

  @spec get_config(t(), String.t()) :: map() | nil
  def get_config(client, key) do
    case request(client, :get, "/server/configs/#{encode_segment(key)}") do
      {:ok, %{"config" => config}} -> config
      _ -> nil
    end
  end

  @spec list_configs(t()) :: [map()]
  def list_configs(client) do
    case request(client, :get, "/server/configs") do
      {:ok, %{"configs" => configs}} when is_list(configs) -> configs
      _ -> []
    end
  end

  @spec ai_config(t(), String.t()) :: map() | nil
  def ai_config(client, file_name) do
    with :miss <- cached(client, {:ai_config, file_name}),
         {:ok, %{"ai_config" => config}} <-
           request(client, :get, "/server/ai-configs/#{encode_segment(file_name)}") do
      put_cache(client, {:ai_config, file_name}, config)
      config
    else
      {:ok, config} -> config
      _ -> nil
    end
  end

  @spec list_ai_configs(t(), keyword()) :: [map()]
  def list_ai_configs(client, opts \\ []) do
    configs =
      case request(client, :get, "/server/ai-configs") do
        {:ok, %{"ai_configs" => values}} when is_list(values) -> values
        _ -> []
      end

    Enum.filter(configs, fn config ->
      (is_nil(opts[:file_type]) or config["file_type"] == to_string(opts[:file_type])) and
        (not Keyword.has_key?(opts, :folder) or config["folder"] == opts[:folder])
    end)
  end

  @spec translation(t(), String.t(), String.t(), keyword()) :: String.t()
  def translation(client, key, locale, opts \\ []) do
    with [namespace, message_key] <- String.split(key, ".", parts: 2),
         {:ok, %{"catalog" => catalog}} <-
           request(
             client,
             :get,
             "/server/translations/#{encode_segment(locale)}/#{encode_segment(namespace)}"
           ),
         pattern when is_binary(pattern) <- get_in(catalog, ["messages", message_key]) do
      interpolate(pattern, Keyword.get(opts, :variables, %{}))
    else
      _ -> Keyword.get(opts, :default, key)
    end
  end

  @spec experiment(t(), String.t(), context()) :: map() | nil
  def experiment(client, key, context) do
    if identity(context) do
      case request(client, :get, "/server/experiments/#{encode_segment(key)}",
             params: context_params(client, context)
           ) do
        {:ok, %{"experiment" => experiment}} -> experiment
        _ -> nil
      end
    end
  end

  @spec track_experiment_metric(t(), map()) :: :ok | {:error, term()}
  def track_experiment_metric(client, event) do
    event = stringify_keys(event)

    body = %{
      "events" => [
        %{
          "event_id" => event["event_id"] || event_id(),
          "experiment_key" => event["experiment_key"],
          "event_name" => event["event_name"],
          "user_id" => event["user_id"],
          "value" => event["value"],
          "properties" => event["properties"] || %{},
          "occurred_at" => event["occurred_at"] || DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ]
    }

    case request(client, :post, "/server/experiment-events/batch", json: body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec clear_cache(t()) :: :ok
  def clear_cache(client) do
    :ets.delete_all_objects(client.cache)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec close(t()) :: :ok
  def close(client) do
    :ets.delete(client.cache)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fetch_all_flags(client, context) do
    case request(client, :get, "/server/flags", params: context_params(client, context)) do
      {:ok, %{"evaluated" => values}} when is_map(values) ->
        if map_size(context) == 0 do
          put_cache(client, :all_flags, values)
          Enum.each(values, fn {key, value} -> put_cache(client, {:flag, key}, value) end)
        end

        values

      _ ->
        %{}
    end
  end

  defp request(client, method, path, opts \\ []) do
    request_opts =
      [
        method: method,
        url: client.base_url <> "/api/v1" <> path,
        auth: {:bearer, client.sdk_key},
        receive_timeout: client.timeout,
        retry: false
      ]
      |> Keyword.merge(client.req_options)
      |> Keyword.merge(opts)

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp context_params(client, context) do
    context
    |> stringify_keys()
    |> flatten_user()
    |> maybe_put_region(client.region)
  end

  defp flatten_user(%{"user" => user} = context) when is_map(user) do
    context
    |> Map.delete("user")
    |> Map.merge(
      Map.new(user, fn
        {key, value} when key in ["id", :id] -> {"user_id", value}
        {key, value} -> {"user_#{key}", value}
      end)
    )
  end

  defp flatten_user(context), do: context
  defp maybe_put_region(context, nil), do: context
  defp maybe_put_region(context, region), do: Map.put_new(context, "region", region)

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp identity(context) do
    context[:user_id] || context["user_id"] || context[:unit_id] || context["unit_id"] ||
      get_in(context, [:user, :id]) || get_in(context, ["user", "id"])
  end

  defp interpolate(pattern, variables) do
    variables = stringify_keys(variables)

    Regex.replace(~r/\{([\w.]+)\}/, pattern, fn whole, key ->
      to_string(Map.get(variables, key, whole))
    end)
  end

  defp cached(%{cache_ttl: 0}, _key), do: :miss

  defp cached(client, key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(client.cache, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      [{^key, _, _}] ->
        :ets.delete(client.cache, key)
        :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp put_cache(%{cache_ttl: 0}, _key, _value), do: :ok

  defp put_cache(client, key, value) do
    expires_at = System.monotonic_time(:millisecond) + client.cache_ttl
    true = :ets.insert(client.cache, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp detect_region do
    ~w(FLAGDASH_REGION FLY_REGION AWS_REGION AWS_DEFAULT_REGION VERCEL_REGION GOOGLE_CLOUD_REGION RAILWAY_REPLICA_REGION RENDER_REGION)
    |> Enum.find_value(&System.get_env/1)
  end

  defp event_id do
    "evt_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
