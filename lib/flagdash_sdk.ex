defmodule :flagdash_sdk do
  @moduledoc "Erlang-callable facade for the FlagDash Elixir SDK."

  def new(sdk_key), do: FlagDash.Client.new(sdk_key)
  def new(sdk_key, options), do: FlagDash.Client.new(sdk_key, options)
  def flag(client, key, default), do: FlagDash.Client.flag(client, key, %{}, default)
  def flag(client, key, context, default), do: FlagDash.Client.flag(client, key, context, default)
  def all_flags(client), do: FlagDash.Client.all_flags(client)
  def all_flags(client, context), do: FlagDash.Client.all_flags(client, context)
  def config(client, key, default), do: FlagDash.Client.config(client, key, default)
  def ai_config(client, file_name), do: FlagDash.Client.ai_config(client, file_name)
  def list_ai_configs(client), do: FlagDash.Client.list_ai_configs(client)
  def clear_cache(client), do: FlagDash.Client.clear_cache(client)
  def close(client), do: FlagDash.Client.close(client)
end
