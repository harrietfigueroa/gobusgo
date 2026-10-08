defmodule GobusgoWeb.ConnectionFactsTest do
  # Verifies the facts as a pure function of what a browser connects with:
  # parameters inside their rules, and parameters a browser should never
  # send, each of which has to come out as nil and never as the text sent.
  use ExUnit.Case, async: true

  alias GobusgoWeb.ConnectionFacts

  @firefox "Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0"

  defp facts(connect_params, changes \\ %{}) do
    ConnectionFacts.from_connect(
      Map.merge(
        %{
          page: "vehicle",
          connect_params: connect_params,
          user_agent: @firefox,
          host: "gobusgo.example.org"
        },
        changes
      )
    )
  end

  defp client(values), do: %{"client" => values}

  describe "from_connect/1" do
    test "holds every fact a browser supplies" do
      params = %{
        "_mounts" => 0,
        "client" => %{
          "viewport_width" => 390,
          "language" => "en-US",
          "referrer_host" => "Example.ORG"
        }
      }

      assert facts(params) == %{
               page: "vehicle",
               reconnect: false,
               device_class: "desktop",
               browser_family: "firefox",
               viewport_width_bucket: "under-480",
               language: "en",
               referrer_host: "example.org"
             }
    end

    for {label, connect_params} <- [
          {"no parameters", nil},
          {"empty parameters", %{}},
          {"parameters that are no map", "x"},
          {"a client that is no map", %{"client" => "x"}}
        ] do
      test "holds nil for every fact of the browser's with #{label}" do
        assert %{
                 reconnect: nil,
                 viewport_width_bucket: nil,
                 language: nil,
                 referrer_host: nil
               } = facts(unquote(Macro.escape(connect_params)))
      end
    end

    for {mount_count, reconnect} <- [{0, false}, {1, true}, {7, true}] do
      test "says reconnect is #{reconnect} after #{mount_count} earlier mounts" do
        assert %{reconnect: unquote(reconnect)} = facts(%{"_mounts" => unquote(mount_count)})
      end
    end

    for mount_count <- [-1, "1", 1.5, nil, [1]] do
      test "holds no reconnect for a mount count of #{inspect(mount_count)}" do
        assert %{reconnect: nil} = facts(%{"_mounts" => unquote(mount_count)})
      end
    end

    for {width, bucket} <- [
          {1, "under-480"},
          {479, "under-480"},
          {480, "480-767"},
          {767, "480-767"},
          {768, "768-1023"},
          {1_023, "768-1023"},
          {1_024, "1024-1439"},
          {1_439, "1024-1439"},
          {1_440, "1440-and-over"},
          {100_000, "1440-and-over"}
        ] do
      test "puts a viewport #{width} wide in the bucket #{bucket}" do
        assert %{viewport_width_bucket: unquote(bucket)} =
                 facts(client(%{"viewport_width" => unquote(width)}))
      end
    end

    for width <- [0, -5, 100_001, "390", 390.5, nil] do
      test "holds no bucket for a viewport width of #{inspect(width)}" do
        assert %{viewport_width_bucket: nil} =
                 facts(client(%{"viewport_width" => unquote(width)}))
      end
    end

    test "names every bucket it can return" do
      assert ConnectionFacts.viewport_width_buckets() == [
               "1440-and-over",
               "1024-1439",
               "768-1023",
               "480-767",
               "under-480"
             ]
    end

    for {tag, language} <- [
          {"en", "en"},
          {"en-US", "en"},
          {"ES-419", "es"},
          {"zh-Hant-TW", "zh"},
          {"fil", "fil"}
        ] do
      test "reads the language #{language} out of #{tag}" do
        assert %{language: unquote(language)} = facts(client(%{"language" => unquote(tag)}))
      end
    end

    for tag <- [
          "",
          "e",
          "english",
          "en_US",
          "en US",
          "<b>",
          String.duplicate("en-", 12) <> "x",
          5,
          nil
        ] do
      test "holds no language for #{inspect(tag)}" do
        assert %{language: nil} = facts(client(%{"language" => unquote(tag)}))
      end
    end

    for host <- ["example.org", "news.example.co.uk", "localhost", "xn--bcher-kva.example"] do
      test "holds the referrer host #{host}" do
        assert %{referrer_host: unquote(host)} =
                 facts(client(%{"referrer_host" => unquote(host)}))
      end
    end

    for host <- [
          "",
          "example.org/path",
          "example.org?q=1",
          "https://example.org",
          "user@example.org",
          "example.org:8080",
          "-example.org",
          "exa mple.org",
          String.duplicate("a", 254),
          5,
          nil
        ] do
      test "holds no referrer host for #{inspect(host)}" do
        assert %{referrer_host: nil} = facts(client(%{"referrer_host" => unquote(host)}))
      end
    end

    for host <- ["gobusgo.example.org", "GOBUSGO.example.org"] do
      test "holds no referrer host for the page's own host, sent as #{host}" do
        assert %{referrer_host: nil} = facts(client(%{"referrer_host" => unquote(host)}))
      end
    end

    test "holds a referrer host when the page's own host is not known" do
      assert %{referrer_host: "example.org"} =
               facts(client(%{"referrer_host" => "example.org"}), %{host: nil})
    end

    for {label, user_agent} <- [{"no user agent", nil}, {"a user agent that is no text", 5}] do
      test "calls the device and the browser unknown for #{label}" do
        assert %{device_class: "unknown", browser_family: "unknown"} =
                 facts(%{}, %{user_agent: unquote(user_agent)})
      end
    end

    test "keeps nothing of the user agent" do
      refute facts(%{}) |> Map.values() |> Enum.any?(&(&1 == @firefox))
    end
  end
end
