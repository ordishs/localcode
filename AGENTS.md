# AGENTS.md

Guardrails for work in this repository.

## Purpose

`localcode` wraps the pi coding agent and points it at the abila gateway. It owns
configuration and one bundled tool. It is not a fork of pi and not a model server. Keep it
small.

This file guides agents that work in a clone of this repository. The package does not ship
it. Rules that apply to every user live in `config/system.md`, which the wrapper appends to
the pi system prompt. Put a user rule in `config/system.md`, not here.

## Hard rules

- Never commit a token. `MASA_TOKEN` and `EXA_API_KEY` come from the environment. Do not
  paste a token into a commit, a test fixture, or a log line.
- Do not write pi state outside the config dir. The config dir is `LOCALCODE_HOME`, default
  `~/.localcode`. The wrapper passes it to pi as `PI_CODING_AGENT_DIR`. Never change the
  user's `~/.pi`.
- `gh` runs with the user's real GitHub account. Read-only by default. Creating,
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
- Over-limit bodies return HTTP 413. The live gateway answers with an nginx HTML page
  `413 Request Entity Too Large`, not a JSON body. Match on the status code only.
- The live gateway accepts `max_tokens` of 1000000 with HTTP 200. It does not reject a
  larger value. Unverified: whether it clamps the value to `max_output_tokens`. Three probes
  ended before the cap. `localcode` sends `max_output_tokens` as `maxTokens`, so it does
  not depend on a clamp.
- These facts were checked against the live gateway at llm.masa.gi on 2026-10-14.

## Style

- No comments in code unless asked. Separate logic blocks with blank lines.
- Write text in Simplified Technical English. Keep chat short.
- Use one term for one concept. Do not swap synonyms. Say "gateway", "config dir", and
  "user" every time.
- Keep each sentence to 20 words or fewer. Give one action per step.
- No AI attribution in commit messages.
- Explain in `README.md`, not in code comments.
- User-facing failures must name the fix. A missing token should print the export to run.

## Explanations

- When the user asks you to explain numbers or system behavior, you may write a throwaway
  HTML file. Use a slider or a diagram instead of long text.
- Write the file to the system temp directory. This is the only write allowed outside the
  repo and the config dir. Never write it into the repo or `~/.pi`.
- Use no CDN links and no network calls. The file must work offline.
- Delete the file when the user has seen it. Never commit it.

## Checks before you claim done

```bash
./test/smoke.sh
./bin/localcode doctor
```

`doctor` exits 1 on any `PROBLEM` line. A missing `EXA_API_KEY` is a `note`, not a
`PROBLEM`. Report what actually ran and what did not. Do not call a check passing without a
fresh exit code.
