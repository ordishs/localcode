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

Do not write limits into config. `localcode` reads them from `GET /v1/models` on every
start. Confirm these again before relying on them. The gateway owner can change them.

- Each model entry reports `context_window`, `max_output_tokens`, and `limits`
  (`max_body_bytes`, `requests_per_minute`, `max_concurrent`).
- The gateway does not rewrite the `model` field. It rejects a model it does not list with
  HTTP 404 `model_not_found`, and a missing model with HTTP 400.
- Over-limit bodies return HTTP 413 `request body too large`.
- The gateway clamps larger `max_tokens` values to `max_output_tokens`.
- These facts were checked against `llm_proxy` run locally on the dev machine. The live
  gateway at llm.masa.gi needs the matching `llm_proxy` release before `localcode` works
  against it.

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
