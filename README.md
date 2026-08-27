> ## Archived — not maintained
>
> This repository is no longer part of the OpenSOP project and receives no
> updates. It is kept read-only for reference.
>
> **OpenSOP lives on:**
>
> - The standard and the local-first CLI: **https://github.com/opensop/opensop**
> - The public SOP library: **https://github.com/opensop/sops**
> - The site: **https://opensop.ai**
>
> OpenSOP is local-first. `opensop run` executes processes on your machine with
> bash and jq — it never required this server.
>
> The `/sop/*` server profile is still specified in
> [`SPEC.md` §4](https://github.com/opensop/opensop/blob/main/SPEC.md); there is
> simply no maintained implementation of it. Anyone is free to build one, and
> this code remains here as a starting point.

# opensop-rails — OpenSOP reference server

A Rails implementation of the **[OpenSOP](https://github.com/Chosen9115/opensop) specification**: it serves the `/sop/*` REST API, executes processes, stores instance state, and owns a shared audit log. Humans and agents drive it through the same `opensop` CLI (`opensop --remote …`) or any client that speaks the spec.

> **You may not need this.** OpenSOP is local-first: the [`opensop` CLI](https://github.com/Chosen9115/opensop/tree/main/cli) runs processes on your machine with no server. Run `opensop-rails` when you want **shared orchestration, a monitoring UI, a team audit log, or the hosted REST API** — it's one reference implementation of the spec, not a requirement.

## Where things live

| | Repo |
|---|---|
| The standard (spec + CLI) | **[Chosen9115/opensop](https://github.com/Chosen9115/opensop)** — `SPEC.md`, the HTTP contract (`docs/API.md`), and the local-first CLI (`cli/`) |
| This reference server | **Chosen9115/opensop-rails** (you are here) |

The `/sop/*` API contract is owned by [`opensop/SPEC.md`](https://github.com/Chosen9115/opensop/blob/main/SPEC.md). This server must stay compatible with it. Anyone can build an alternative server against the same spec.

## Stack

Rails 8 · Ruby 3.3 · PostgreSQL · Solid Queue · Hotwire (Turbo + Stimulus) · Tailwind · RSpec.

## Quick start

```bash
# Docker (recommended)
docker compose up

# or local dev
bin/setup
bin/dev          # http://localhost:3000
```

Set `OPENSOP_API_TOKEN` (the API fails closed in production without it). See [`docs/deploy-fly.md`](docs/deploy-fly.md) for deployment and [`docs/architecture.md`](docs/architecture.md) for the runtime internals.

## Talking to it from the CLI

```bash
opensop --server http://localhost:3000 list
opensop --remote run lead-qualification   # uses your configured server
```

## License

See [`LICENSE`](LICENSE).
