defmodule FlagDashSdk.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :flagdash,
      version: @version,
      elixir: ">= 1.15.0",
      start_permanent: Mix.env() == :prod,
      description: "Official FlagDash SDK for Elixir and Erlang",
      package: package(),
      deps: deps(),
      name: "FlagDash SDK",
      source_url: "https://github.com/flagdash/flagdash-beam",
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "flagdash",
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "Documentation" => "https://flagdash.com/docs#sdk-elixir",
        "GitHub" => "https://github.com/flagdash/flagdash-beam"
      }
    ]
  end
end
