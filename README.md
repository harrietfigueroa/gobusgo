# Gobusgo

Gobusgo is an Elixir application that consumes the [OneBusAway API](https://developer.onebusaway.org/api/where/methods) for Sound Transit.

## Requirements

Erlang/OTP 29.1.1 and Elixir 1.20.4 (OTP 29), pinned in `.tool-versions`. The HTTP client is [Req](https://hex.pm/packages/req); `plug` is a test-only dependency for `Req.Test`.

## Setup

Install [mise](https://mise.jdx.dev) with Homebrew (`brew install mise`), then install the pinned toolchain from the repository root.

```sh
mise install
mix deps.get
```

## Configuration

Configuration is read from environment variables: `ONEBUSAWAY_BASE_URL` and `ONEBUSAWAY_API_KEY`. Copy the template to `.env` (ignored by git), fill in the values, and export them into your shell.

```sh
cp .env.example .env
set -a; source .env; set +a
```

## Usage

`Gobusgo.OneBusAway.Agencies.fetch/2` requests agency discovery (`agencies-with-coverage`) and returns each agency with its coverage area, or an error value. It writes nothing to disk. With the environment variables exported, run it in `iex -S mix`:

```elixir
{:ok, settings} = Gobusgo.Config.one_bus_away()
{:ok, agencies} = Gobusgo.OneBusAway.Agencies.fetch(settings, [])
Enum.map(agencies, & &1.name)
```

The module documentation lists every error value.

`Gobusgo.OneBusAway.AgencyRecorder.record/2` makes the same request and stores the successful response through `Gobusgo.Writer`. With the default configuration the local file backend writes it under `data/` (ignored by git), at `raw/oba/agencies-with-coverage/dt=YYYY-MM-DD/<fetchedAt>_<requestId>_<dataHash12>.json`. A failed request stores nothing.

```elixir
{:ok, settings} = Gobusgo.Config.one_bus_away()
{:ok, recorded} = Gobusgo.OneBusAway.AgencyRecorder.record(settings, [])
recorded.destination
```

## Development

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

## Further reading

The OneBusAway integration contract is in [lib/gobusgo/one_bus_away/AGENTS.md](lib/gobusgo/one_bus_away/AGENTS.md). Engineering conventions are in [AGENTS.md](AGENTS.md).
