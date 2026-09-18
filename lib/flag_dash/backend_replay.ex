defmodule FlagDash.BackendReplay do
  @moduledoc "Privacy-safe explicit event timeline for trusted Elixir/Erlang backends."
  use GenServer

  @sensitive ~r/pass(word)?|secret|token|authorization|cookie|session|api[-_]?key|credit|card|cvv|cvc|otp|ssn/i

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def start(replay), do: GenServer.call(replay, :start)

  def event(replay, name, category \\ "action", attributes \\ %{}),
    do: GenServer.cast(replay, {:event, name, category, attributes})

  def breadcrumb(replay, message, attributes \\ %{}),
    do: event(replay, message, "breadcrumb", attributes)

  def capture_exception(replay, exception, attributes \\ %{}),
    do: event(replay, inspect(exception.__struct__), "exception", attributes)

  def context_headers(replay), do: GenServer.call(replay, :context_headers)
  def flush(replay), do: GenServer.call(replay, :flush, :infinity)
  def stop(replay), do: GenServer.stop(replay, :normal, :infinity)

  @impl true
  def init(options) do
    {:ok,
     %{
       sdk_key: Keyword.fetch!(options, :sdk_key),
       base_url:
         options |> Keyword.get(:base_url, "https://flagdash.io") |> String.trim_trailing("/"),
       identity: options[:identity],
       release: options[:release],
       metadata: sanitize(options[:metadata] || %{}),
       req_options: options[:req_options] || [],
       id: nil,
       sequence: 0,
       events: [],
       started_at: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_call(:start, _from, state) do
    payload = %{
      type: "trace",
      platform: "elixir",
      sdk_name: "flagdash-elixir",
      started_at: DateTime.to_iso8601(state.started_at),
      identity: state.identity,
      release: state.release,
      metadata: state.metadata
    }

    case api(state, "/api/v1/replay-sessions/start", payload) do
      {:ok, 204, _} -> {:reply, false, state}
      {:ok, status, %{"id" => id}} when status in 200..299 -> {:reply, true, %{state | id: id}}
      _ -> {:reply, false, state}
    end
  end

  def handle_call(:context_headers, _from, %{id: nil} = state), do: {:reply, %{}, state}

  def handle_call(:context_headers, _from, state),
    do: {:reply, %{"x-flagdash-replay-id" => state.id}, state}

  def handle_call(:flush, _from, state) do
    {result, state} = flush_all(state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:event, name, category, attributes}, state) do
    if state.id && is_binary(name) && name != "" && length(state.events) < 1_000 do
      event = %{
        name: String.slice(name, 0, 100),
        category: to_string(category) |> String.slice(0, 40),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        attributes: sanitize(attributes)
      }

      {:noreply, %{state | events: state.events ++ [event]}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    {_result, state} = flush_all(state)

    if state.id do
      duration = DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)

      api(state, "/api/v1/replay-sessions/#{state.id}/complete", %{
        ended_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        duration_ms: duration
      })
    end

    :ok
  end

  defp flush_all(%{id: nil} = state), do: {:ok, state}
  defp flush_all(%{events: []} = state), do: {:ok, state}

  defp flush_all(state) do
    {batch, rest} = Enum.split(state.events, 100)
    body = Jason.encode_to_iodata!(batch)

    payload = %{
      sequence: state.sequence,
      byte_size: IO.iodata_length(body),
      event_count: length(batch),
      content_encoding: "identity"
    }

    with {:ok, status, %{"upload" => upload}} when status in 200..299 <-
           api(state, "/api/v1/replay-sessions/#{state.id}/chunks/presign", payload),
         {:ok, %Req.Response{status: upload_status}} when upload_status in 200..299 <-
           Req.put(
             upload["url"],
             [body: body, headers: upload["headers"] || []] ++ state.req_options
           ) do
      flush_all(%{state | events: rest, sequence: state.sequence + 1})
    else
      _ -> {{:error, :upload_failed}, state}
    end
  end

  defp api(state, path, payload) do
    case Req.post(
           state.base_url <> path,
           [json: payload, auth: {:bearer, state.sdk_key}] ++ state.req_options
         ) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sanitize(value), do: sanitize(value, 0)
  defp sanitize(_value, depth) when depth > 8, do: "[REDACTED]"

  defp sanitize(value, depth) when is_map(value) do
    value
    |> Enum.take(500)
    |> Map.new(fn {key, item} ->
      {key,
       if(Regex.match?(@sensitive, to_string(key)),
         do: "[REDACTED]",
         else: sanitize(item, depth + 1)
       )}
    end)
  end

  defp sanitize(value, depth) when is_list(value),
    do: value |> Enum.take(500) |> Enum.map(&sanitize(&1, depth + 1))

  defp sanitize(value, _depth) when is_binary(value), do: String.slice(value, 0, 2_000)

  defp sanitize(value, _depth) when is_nil(value) or is_boolean(value) or is_number(value),
    do: value

  defp sanitize(_value, _depth), do: "[REDACTED]"
end
