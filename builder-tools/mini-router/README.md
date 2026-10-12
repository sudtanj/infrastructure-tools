# mini-router

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works. Everything below is scoped
> to this folder; run these commands from inside it
> (`cd mini-router` first if you're at the repo root).

[mini-router](https://github.com/sudtanj/mini-router) is one
OpenAI-compatible **and** Anthropic-compatible endpoint in front of every
LLM provider you already pay for.

Point any OpenAI client *or* any Anthropic client at it, ask for a model,
and it picks a provider, translates the dialect if it has to, and falls
through to the next provider the moment anything goes wrong.

It is built to sit on a small always-on box on your own network - an Orange
Pi Zero 3 is the design target - in a ~2 MB binary that idles under 5 MB of
RAM and stays there while streaming.

## Quick start

Two compose files, depending on whether you want to build from source or
just run the published image:

- **`docker-compose.yml`** - builds locally from the `Dockerfile` here
  (which fetches mini-router's source itself).
- **`docker-compose.hub.yml`** - pulls
  [`sudtanj/mini-router`](https://hub.docker.com/r/sudtanj/mini-router).

```bash
cp .env.example .env
$EDITOR .env                 # at least one provider key + MINI_ROUTER_API_KEYS
docker compose -f docker-compose.hub.yml up -d
```

That is enough to serve requests naming a real model - `gpt-4o-mini`,
`claude-haiku-4-5`. Pools ship commented out, because a pool naming a
provider you have no key for is a startup error rather than a shrug. Open the
compose file's section 3 and uncomment the variant matching the keys you
filled in:

```yaml
      MINI_ROUTER_POOL_FAST: |
        openai:gpt-4o-mini
        anthropic:claude-haiku-4-5
```

One name, several provider models, in priority order. Then point your clients
at it:

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8080/v1", api_key="<MINI_ROUTER_API_KEYS>")
client.chat.completions.create(model="fast", messages=[{"role": "user", "content": "hi"}])

from anthropic import Anthropic
client = Anthropic(base_url="http://localhost:8080", api_key="<MINI_ROUTER_API_KEYS>")
client.messages.create(model="fast", max_tokens=256,
                       messages=[{"role": "user", "content": "hi"}])
```

Both of those can land on the *same* provider. `fast` resolves to whichever
member is healthy, and the answer is reshaped to match whichever SDK asked.

## Configuration

There is no config file. Every setting is an environment variable, which is
why this image mounts nothing: the `environment:` block in the compose files
*is* the configuration.

Both compose files are written as a full reference - every variable
mini-router reads is in there, grouped into seven sections, with the defaults
noted on the ones left commented. The split is secrets in `.env`, structure in
compose: a pool can only name providers you have a key for, so it belongs
next to the keys it depends on rather than in the file you never open.

The full list is also a flag away:

```bash
docker compose run --rm mini-router --help
```

And to see what your settings actually resolved to, before starting
anything for real:

```bash
docker compose run --rm mini-router --check
```

The three that matter most:

| Variable | What it does |
|---|---|
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GROQ_API_KEY`, ... | A provider key on its own registers that provider, with the right URL and dialect. Ten are recognised; see `.env.example`. |
| `MINI_ROUTER_POOL_<NAME>` | One client-facing name over several provider models, tried in the order written. Use YAML's `\|` to get a line per member (commas also work). |
| `MINI_ROUTER_API_KEYS` | What *your* clients present - a key you invent, not a provider's. mini-router swaps it for the provider's own on the way out, so a client never holds a provider credential. The compose files refuse to start without it. |

Anything not on the recognised list is spelled out with
`MINI_ROUTER_PROVIDER_<NAME>_URL`, `_PROTOCOL` and `_API_KEY` - your own
LiteLLM box, a corporate gateway, an Azure deployment. Section 2 of the
compose file has it, keyed off `MYPROXY_*` in `.env` so all three land
together: a provider with a URL and no protocol is a startup error, and one
with nothing at all simply does not exist.

One thing worth knowing before you write that section: **defining any
provider explicitly switches autodetection off**, so the ten keys above stop
registering on their own. If you want your proxy *and* the well-known
providers, set `MINI_ROUTER_AUTODETECT: "true"`. It works that way so a stray
`OPENAI_API_KEY` meant for some other tool cannot quietly join a pool you
spelled out by hand.

A variable mini-router does not recognise is a startup error naming the
variable, not a silent default - so a typo costs you a failed start, not a
week of confusion.

## What you get

- **Pools with spillover on anything.** Not just rate limits: a refused
  connection, a timeout, an expired key, a 400, a model the provider has
  never heard of - all of them move the request to the next member. When the
  list runs out the client gets the last provider's own error, status and
  message intact, reshaped into its own dialect.
- **Protocol translation both ways**, including streaming, tool calls and
  images. An OpenAI-shaped request can be served by Anthropic and come back
  OpenAI-shaped, and the reverse.
- **`Retry-After` is honoured**, so a rate-limited provider is parked for
  exactly as long as it asked rather than being hammered.
- **Prometheus metrics** at `/metrics` and a JSON view of the provider pool
  at `/admin/upstreams` - both removable with `MINI_ROUTER_METRICS=false` /
  `MINI_ROUTER_ADMIN=false`. There is no web UI anywhere in it.

## Notes on this image

- **Multi-arch, cross-compiled.** `linux/amd64` and `linux/arm64`. The Rust
  build runs on the build platform and cross-compiles, rather than being
  emulated under QEMU - a release build (LTO, one codegen unit) under
  emulation takes tens of minutes, and this keeps the arm64 image roughly as
  cheap as the amd64 one.
- **Pin the source.** `MINI_ROUTER_REF` is a build arg naming the git ref to
  build. Empty (the default) builds mini-router's default branch; set it to a
  tag for a reproducible image.
- **No shell tooling for the healthcheck.** mini-router probes itself with
  `--healthcheck`, so the image carries no `curl` or `wget` for it.
  `/healthz` is unauthenticated on purpose, so it keeps working with
  `MINI_ROUTER_REQUIRE_AUTH=true`.
- **Runs as uid 10001 with a read-only filesystem**, no capabilities, and
  `no-new-privileges`. Nothing is written to disk.
- **`ca-certificates` is the only runtime dependency.** Every provider API is
  https; without the trust store every request fails at the handshake.
