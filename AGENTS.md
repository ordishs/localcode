# AGENTS.md

Guardrails for work in this repository.

## Purpose

`localcode` wraps the pi coding agent and points it at the abila gateway. It owns
configuration and one bundled tool. It is not a fork of pi and not a model server. Keep it
small.

## Hard rules

- Never commit a token. `MASA_TOKEN` and `EXA_API_KEY` come from the environment. Do not
  paste a token into a commit, a test fixture, or a log line.
- Do not write outside the wrapper config dir. pi state belongs in `PI_CODING_AGENT_DIR`,
  which defaults to `~/.localcode`. Never mutate a colleague's `~/.pi`.
- `gh` runs with the colleague's real GitHub account. Read-only by default. Creating,
  pushing, commenting, merging, or deleting needs an explicit human request.
- Verify claims against the live gateway before encoding them in config. This model
  confabulates plausible version numbers, so re-check anything factual.

## Gateway facts

Confirm again before relying on these; the gateway owner can change them.

- Body cap 32 MiB. Over-limit requests return HTTP 413 `request body too large`.
- Output cap 32768 tokens. The gateway clamps larger `max_tokens` values.
- The gateway rewrites the `model` field. Client model choice has no effect.
- 2 concurrent requests and 30 requests per minute per token.
- The advertised model reports a 262144 context window. The default budget here is 262144
  tokens.

## Style

- No comments in code unless asked. Separate logic blocks with blank lines.
- Write text in Simplified Technical English. Keep chat short.
- No AI attribution in commit messages.
- Explain in `README.md`, not in code comments.
- User-facing failures must name the fix. A missing token should print the export to run.

## Checks before you claim done

```bash
./test/smoke.sh
./bin/localcode doctor
```

Report what actually ran and what did not. Do not call a check passing without a fresh
exit code.
