defmodule Gobusgo.RequestId do
  @moduledoc """
  Request identifiers in the UUID version 7 layout: a Unix millisecond
  timestamp followed by random bits, so identifiers sort by creation time.
  `build/1` and `valid?/1` are pure; `generate/0` reads the clock and the
  random source.
  """

  alias Gobusgo.Assert

  @type t :: String.t()

  # https://www.rfc-editor.org/rfc/rfc9562#section-5.7 — checked 2026-10-01
  @timestamp_bit_count 48
  @version 7
  @variant 0b10
  @random_byte_count 10

  @unix_ms_max Integer.pow(2, @timestamp_bit_count) - 1
  @pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @doc "Returns a new identifier for the current time."
  @spec generate() :: t()
  def generate do
    build(%{
      unix_ms: System.system_time(:millisecond),
      random: :crypto.strong_rand_bytes(@random_byte_count)
    })
  end

  @doc """
  Returns the identifier for `unix_ms`, a Unix time in milliseconds that fits
  48 bits, and `random`, 10 random bytes of which 74 bits are used.
  """
  @spec build(%{unix_ms: non_neg_integer(), random: <<_::80>>}) :: t()
  def build(%{unix_ms: unix_ms, random: <<random_high::12, _unused::6, random_low::62>>})
      when is_integer(unix_ms) do
    Assert.condition(unix_ms >= 0, "unix_ms must be non-negative, got #{unix_ms}")
    Assert.condition(unix_ms <= @unix_ms_max, "unix_ms must fit 48 bits, got #{unix_ms}")

    <<time_low::binary-size(8), time_high::binary-size(4), version::binary-size(4),
      variant::binary-size(4), node::binary-size(12)>> =
      Base.encode16(
        <<unix_ms::size(@timestamp_bit_count), @version::4, random_high::12, @variant::2,
          random_low::62>>,
        case: :lower
      )

    id = Enum.join([time_low, time_high, version, variant, node], "-")
    Assert.condition(valid?(id), "built an invalid request identifier")
    id
  end

  @doc "Whether `candidate` is a lowercase UUID version 7 string."
  @spec valid?(term()) :: boolean()
  def valid?(candidate) when is_binary(candidate), do: Regex.match?(@pattern, candidate)
  def valid?(_candidate), do: false
end
