defmodule Gobusgo.ConfigFilesTest do
  # Verifies what the configuration files produce, by evaluating each file
  # with Config.Reader and inspecting the result. The data directory comes
  # from an environment variable, which is global state, so the cases run one
  # at a time and the variable is restored after each.
  use ExUnit.Case, async: false

  @config_path Path.expand("../../config/config.exs", __DIR__)
  @runtime_path Path.expand("../../config/runtime.exs", __DIR__)
  @data_dir_variable "GOBUSGO_DATA_DIR"
  @data_dir_default Path.expand("data")

  describe "config/runtime.exs base directory" do
    setup do
      data_dir = System.get_env(@data_dir_variable)

      on_exit(fn ->
        case data_dir do
          nil -> System.delete_env(@data_dir_variable)
          value -> System.put_env(@data_dir_variable, value)
        end
      end)
    end

    for {title, value, base_dir} <- [
          {"defaults to data under the working directory when unset", nil, @data_dir_default},
          {"defaults to data under the working directory when blank", "  ", @data_dir_default},
          {"is the configured absolute directory", "/var/lib/gobusgo", "/var/lib/gobusgo"},
          {"is a configured relative directory made absolute", "tmp/store",
           Path.expand("tmp/store")}
        ] do
      test title do
        case unquote(value) do
          nil -> System.delete_env(@data_dir_variable)
          value -> System.put_env(@data_dir_variable, value)
        end

        gobusgo = read(@runtime_path, :test)

        assert gobusgo[Gobusgo.Writer.LocalFile] == [base_dir: unquote(base_dir)]
        assert gobusgo[Gobusgo.Reader.LocalFile] == [base_dir: unquote(base_dir)]
      end
    end
  end

  describe "config/config.exs endpoint" do
    test "serves HTTP and reads the digested asset names in production" do
      endpoint = read(@config_path, :prod)[GobusgoWeb.Endpoint]

      assert endpoint[:server] == true
      assert endpoint[:cache_static_manifest] == "priv/static/cache_manifest.json"
    end

    for env <- [:dev, :test] do
      test "leaves serving to the command that starts the application in #{env}" do
        endpoint = read(@config_path, unquote(env))[GobusgoWeb.Endpoint]

        assert Keyword.has_key?(endpoint, :server) == false
        assert Keyword.has_key?(endpoint, :cache_static_manifest) == false
      end
    end
  end

  describe "config/config.exs logger" do
    test "logs from info upward in production" do
      assert get_in(read_all(@config_path, :prod), [:logger, :level]) == :info
    end

    for env <- [:dev, :test] do
      test "sets no level in #{env}" do
        assert get_in(read_all(@config_path, unquote(env)), [:logger, :level]) == nil
      end
    end
  end

  defp read(path, env), do: path |> read_all(env) |> Keyword.fetch!(:gobusgo)

  defp read_all(path, env), do: Config.Reader.read!(path, env: env, target: :host)
end
