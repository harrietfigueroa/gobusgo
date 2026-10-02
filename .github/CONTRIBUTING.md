# Contributing

Local setup (toolchain versions, environment variables, running the application) is documented in the [README](../README.md). Read it first.

## Checks

Every pull request must pass the same three checks CI runs:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

Run `mix format` to fix formatting failures.

## Pull requests

Fill in the pull request template: a change summary and testing evidence. Keep each pull request to one Linear issue.

## Secrets

Never commit credentials. Local configuration lives in `.env`, which is ignored by git; `.env.example` lists the variable names without values.

## Style

Follow [AGENTS.md](../AGENTS.md).
