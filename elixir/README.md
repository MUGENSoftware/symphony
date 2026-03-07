# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> It runs Claude Code without the usual guardrails. Use it only in trusted environments.

## What It Does

Symphony is a long-running service that:

1. polls Linear for candidate issues,
2. creates one isolated workspace per issue,
3. launches Claude Code inside that workspace,
4. feeds Claude a workflow prompt from `WORKFLOW.md`,
5. keeps retrying or continuing work while the issue remains active,
6. cleans up workspaces when issues become terminal.

If you do not know Elixir, the important mental model is "scheduler plus workers":

- the scheduler is the orchestrator loop,
- the workers are Claude Code sessions running per issue,
- the workflow file is the runtime contract,
- the dashboard and logs are the main debugging surfaces.

## Five-Minute Local Run

Prerequisites:

- [mise](https://mise.jdx.dev/) for Erlang/Elixir version management
- a Linear personal API key in `LINEAR_API_KEY`
- a `WORKFLOW.md` that can clone and prepare your target repository

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
LINEAR_API_KEY=lin_api_xxx \
  mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

To enable the HTTP dashboard and JSON API locally:

```bash
LINEAR_API_KEY=lin_api_xxx \
  mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  ./WORKFLOW.md
```

## Minimal `WORKFLOW.md`

`WORKFLOW.md` is the main public interface for the runtime. It combines YAML front matter for config
with a Markdown prompt body for Claude.

```md
---
tracker:
  kind: linear
  project_slug: "your-linear-project-slug"
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
claude:
  command: claude --output-format stream-json
---

You are working on Linear issue {{ issue.identifier }}.

Title: {{ issue.title }}

Body:
{{ issue.description }}
```

If you omit the Markdown body, Symphony falls back to a built-in prompt template that includes the
issue identifier, title, and body.

## Runtime Entry Points

- `./bin/symphony [path-to-WORKFLOW.md]`
- `--logs-root <path>` writes log files under a different root
- `--port <port>` enables the optional Phoenix/Bandit dashboard and JSON API
- if no workflow path is passed, Symphony uses `./WORKFLOW.md`

The CLI requires the explicit acknowledgement flag:

```bash
--i-understand-that-this-will-be-running-without-the-usual-guardrails
```

## Documentation Map

Operator guides:

- [Getting Started](./docs/getting-started.md)
- [Workflow Reference](./docs/workflow-reference.md)
- [Operations Guide](./docs/operations.md)
- [Troubleshooting](./docs/troubleshooting.md)

Contributor guides:

- [Architecture Overview](./docs/architecture-overview.md)
- [Code Map](./docs/code-map.md)
- [Elixir For Readers](./docs/elixir-for-readers.md)

Specialized notes:

- [Logging Best Practices](./docs/logging.md)
- [Claude Code Token Accounting](./docs/token_accounting.md)

## Testing

```bash
make all
```

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
