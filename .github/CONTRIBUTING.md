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

## Ownership and permissions

@harrietfigueroa owns the repository, holds admin permission, and is the code owner of every path (see [CODEOWNERS](CODEOWNERS)). There are no other collaborators. A new contributor is added with write permission, and an addition to CODEOWNERS follows only when that contributor owns a path.

## Secrets

Never commit credentials. Local configuration lives in `.env`, which is ignored by git; `.env.example` lists the variable names without values.

## Style

Follow [AGENTS.md](../AGENTS.md).
