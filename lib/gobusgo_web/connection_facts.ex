defmodule GobusgoWeb.ConnectionFacts do
  @viewport_width_max 100_000
  @language_bytes_max 35
  @host_bytes_max 253

  @moduledoc """
  The facts of a page's connection that a usage record keeps, read out of
  what the browser sends when the page connects. Everything here is pure.

  The connect parameters are the browser's and are validated here: a value
  that is missing or breaks its rule is `nil` in the facts, and never the
  text the browser sent.

    * `reconnect` is whether LiveView's `_mounts` parameter, the count of
      earlier mounts of the page in the browser, is above zero.
    * `viewport_width_bucket` names the bucket that `client.viewport_width`,
      a width in CSS pixels from 1 to #{@viewport_width_max}, falls in.
    * `language` is the primary subtag of `client.language`, a language tag
      of at most #{@language_bytes_max} bytes, in lower case: `en` for
      `en-US`.
    * `referrer_host` is `client.referrer_host`, a host name of at most
      #{@host_bytes_max} bytes, in lower case, and `nil` when it is the host
      the page itself is served from.

  The device class and the browser family come from the user agent through
  `Gobusgo.Usage.UserAgent`, and the user agent is not part of the facts.
  """

  alias Gobusgo.Usage.Records
  alias Gobusgo.Usage.UserAgent

  @type source :: %{
          page: String.t(),
          connect_params: map() | nil,
          user_agent: String.t() | nil,
          host: String.t() | nil
        }

  # The lower bound of each bucket, the widest first, with the bucket's name.
  @viewport_width_buckets [
    {1_440, "1440-and-over"},
    {1_024, "1024-1439"},
    {768, "768-1023"},
    {480, "480-767"},
    {1, "under-480"}
  ]

  # A language tag's primary subtag is two or three letters.
  # https://www.rfc-editor.org/rfc/rfc5646#section-2.1 — checked 2026-10-08
  @language_pattern ~r/\A([A-Za-z]{2,3})(-[A-Za-z0-9]{1,8})*\z/

  @host_pattern ~r/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/

  @doc "The name of every viewport width bucket, the widest first."
  @spec viewport_width_buckets() :: [String.t(), ...]
  def viewport_width_buckets, do: Enum.map(@viewport_width_buckets, &elem(&1, 1))

  @doc """
  The facts of the connection of `page`. `connect_params` are the parameters
  the browser connected with, `user_agent` its user agent, and `host` the
  host the page is served from; each is `nil` when not known.
  """
  @spec from_connect(source()) :: Records.connection()
  def from_connect(%{page: page, connect_params: connect_params, user_agent: user_agent} = source)
      when is_binary(page) do
    params = if is_map(connect_params), do: connect_params, else: %{}
    client = if is_map(params["client"]), do: params["client"], else: %{}
    %{device_class: device_class, browser_family: browser_family} = classify(user_agent)

    %{
      page: page,
      reconnect: reconnect(params["_mounts"]),
      device_class: device_class,
      browser_family: browser_family,
      viewport_width_bucket: viewport_width_bucket(client["viewport_width"]),
      language: language(client["language"]),
      referrer_host: referrer_host(client["referrer_host"], source.host)
    }
  end

  defp classify(user_agent) when is_binary(user_agent), do: UserAgent.classify(user_agent)
  defp classify(_other), do: UserAgent.classify(nil)

  defp reconnect(mount_count) when is_integer(mount_count) and mount_count >= 0,
    do: mount_count > 0

  defp reconnect(_other), do: nil

  defp viewport_width_bucket(width)
       when is_integer(width) and width >= 1 and width <= @viewport_width_max do
    Enum.find_value(@viewport_width_buckets, fn {width_min, name} ->
      if width >= width_min, do: name
    end)
  end

  defp viewport_width_bucket(_other), do: nil

  defp language(tag) when is_binary(tag) and byte_size(tag) <= @language_bytes_max do
    case Regex.run(@language_pattern, tag) do
      [_tag, primary | _rest] -> String.downcase(primary)
      nil -> nil
    end
  end

  defp language(_other), do: nil

  defp referrer_host(host, own_host)
       when is_binary(host) and byte_size(host) <= @host_bytes_max do
    host = String.downcase(host)
    own_host = if is_binary(own_host), do: String.downcase(own_host)

    case host =~ @host_pattern and host != own_host do
      true -> host
      false -> nil
    end
  end

  defp referrer_host(_other, _own_host), do: nil
end
