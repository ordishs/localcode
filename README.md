# localcode

Wraps the [pi](https://pi.dev) coding agent and points it at the abila inference gateway at
`https://llm.masa.gi`. Web search and fetching are yours to choose: a bundled Exa tool
works out of the box, and you can install your own package instead. GitHub access runs
through the `gh` CLI you already use.

## Prerequisites

- pi from https://pi.dev: `npm install -g @earendil-works/pi-coding-agent`. The Homebrew
  install below adds pi for you.
- A gateway token from the `llm_proxy` owner. Tokens are per person and usage is metered
  per token.
- Optional, for the bundled search tool: an Exa API key.
- Optional, for GitHub: `brew install gh` and `gh auth login`.

## Quick start

Install with Homebrew. It also installs `gh`, `jq`, and pi:

```bash
brew install ordishs/tap/localcode
export MASA_TOKEN=<your gateway token>
localcode doctor
localcode
```

`doctor` tells you what is missing and what it will do.

Or install from a clone:

```bash
git clone git@github.com:ordishs/localcode.git && cd localcode
export MASA_TOKEN=<your gateway token>
./bin/localcode doctor
./bin/localcode
```

Install the clone as a command if you prefer:

```bash
npm link        # then run: localcode doctor
```

## Update

```bash
localcode update            # upgrade, then refresh the config dir
localcode update --check    # only report the latest release
```

`update` detects how you installed localcode. A Homebrew install runs
`brew upgrade ordishs/tap/localcode`. A clone runs `git pull --ff-only`. Both then run
`localcode init`. `doctor` also tells you when a newer release exists.

`init` keeps your `settings.json` and `models.json`. It overwrites `extensions/exa.ts`.

## How it works

The wrapper sets `PI_CODING_AGENT_DIR` to its own config directory, so it never touches
your existing `~/.pi`. Everything it owns lives in one place:

| Path | Contents |
| --- | --- |
| `~/.localcode/models.json` | the `masa` provider and its budget |
| `~/.localcode/settings.json` | default model, thinking level, compaction |
| `~/.localcode/extensions/exa.ts` | bundled `websearch` and `webfetch` |
| `~/.localcode/npm/` | tooling you install |
| `~/.localcode/sessions/` | your sessions |

Override the location with `LOCALCODE_HOME`. Useful for a throwaway trial:

```bash
LOCALCODE_HOME=/tmp/localcode-trial ./bin/localcode doctor
```

## Web tooling

Two options, not both at once.

Bundled Exa tool, needs `EXA_API_KEY`:

```bash
export EXA_API_KEY=<key>
./bin/localcode
```

Your own package, for example the widely used `pi-web-access`:

```bash
./bin/localcode install npm:pi-web-access
./bin/localcode exa off
```

`pi-web-access` gives you more providers, PDF extraction, YouTube, GitHub cloning, and an
MCP server. It vendors a large dependency tree. The bundled tool is one small file and
needs an Exa key. `localcode packages` lists what you installed; `localcode remove`
removes it.

Both register web tools with different names: the bundled tool is `websearch` and
`webfetch`; `pi-web-access` registers `web_search` and `fetch_content`. Turning Exa off
when you install a package keeps the model from seeing four similar tools.

`webfetch` reads at most 2 MB and turns HTML into plain text. It removes script blocks,
style blocks, and comments. It replaces each other tag with a space. If a script block,
style block, comment, or tag has no end, `webfetch` drops the rest of the page. A browser
also hides the text after an open script block or comment, so a crafted page cannot use
one to send hidden text to the model. The conversion time is linear in the page size.

## GitHub

```bash
./bin/localcode gh auth status
./bin/localcode gh pr view 42
```

`gh` runs with your normal account. The token has `repo` scope, so write commands change
real repositories. The appended system prompt tells the model to stay read-only unless you
ask otherwise.

## Gateway limits that affect configuration

These were measured against the live gateway, not assumed:

- A request body over 1 MB returns HTTP 413 `request body too large`. A 1.3 MB test body
  was rejected. The default context budget is therefore 131072 tokens, about 4x headroom,
  not the 262144 the model advertises. Raise it with `LOCALCODE_CONTEXT` only if you know
  your bodies stay small.
- The gateway rewrites the `model` field to the one allowed model. A request for
  `totally-bogus-model-xyz` returned HTTP 200 with the configured model. The model choice
  is made by the gateway owner, not by you.
- The gateway allows 2 concurrent requests per token, so run one session per token.

Check what your token can actually use, and store it:

```bash
./bin/localcode models
./bin/localcode models --write
```

## Commands

```
localcode [pi args...]        start pi on the gateway model
localcode doctor              check pi, token, gateway, gh, and web tools
localcode init                create or refresh the config dir
localcode update [--check]    upgrade localcode, or only report the latest release
localcode models [--write]    list advertised models, or store one
localcode install <source>    install your own tooling into the config dir
localcode remove <source>     remove it
localcode packages            list installed tooling
localcode exa on|off          toggle the bundled Exa tools
localcode gh <args>           run GitHub CLI in this environment
localcode config              print resolved paths and settings
localcode version             print versions
```

Any unrecognised argument passes through to pi, so `./bin/localcode -p "hello"` works.

## Verify

```bash
make test
```

The suite runs `doctor`, the model round trip, the bundled web tools, and a `gh` call. It
uses a temporary config dir, so it does not touch yours.

`test/pagetext.test.mjs` tests the HTML-to-text step of `webfetch` and needs no token. It
loads `extensions/exa.ts` with Node type stripping and replaces the pi imports with stubs.
Crafted 2 MB pages must each convert in less than 1 second. HTML samples and closed random
markup must give the same text as the earlier regex version. Run it alone with
`node test/pagetext.test.mjs`.

## Release

Maintainers only. The Homebrew formula is rendered from `packaging/localcode.rb.in` into
the `ordishs/homebrew-tap` repo.

```bash
make release V=0.2.0                  # dry run, changes nothing
make release V=0.2.0 ARGS=--publish   # bump, test, tag, release, update the tap
```

Set `TAP_DIR` if your tap clone is not at `brew --repository ordishs/tap`.

## Limits

- pi 0.84.2 works. pi 0.86.0 or newer is better: third-party web tools then activate on
  demand instead of sitting in the prompt. `doctor` warns you.
- This model writes a short internal preamble before answering. A small `max_tokens`
  returns truncated text. Budget a few hundred tokens at minimum.
- No prompt content is stored by the gateway, but your search queries still leave the
  machine through the search provider.
