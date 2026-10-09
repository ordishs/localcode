#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCALCODE="$ROOT/bin/localcode"
export LOCALCODE_HOME="${SMOKE_HOME:-$(mktemp -d -t localcode-smoke)}"
OWN_HOME=0
if [[ -z "${SMOKE_HOME:-}" ]]; then
  OWN_HOME=1
fi
PASS=0
FAIL=0
SKIP=0

step() { printf '\n\033[1m--- %s\033[0m\n' "$1"; }
ok() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; SKIP=$((SKIP + 1)); }

expect() {
  local label="$1" pattern="$2" text="$3"
  if printf '%s' "$text" | grep -qE "$pattern"; then
    ok "$label"
  else
    bad "$label (wanted /$pattern/)"
    printf '%s\n' "$text" | sed 's/^/      | /' | head -12
  fi
}

expect_file() {
  local label="$1" path="$2"
  if [[ -s "$path" ]]; then
    ok "$label"
  else
    bad "$label (missing or empty: $path)"
  fi
}

expect_exists() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    ok "$label"
  else
    bad "$label (missing: $path)"
  fi
}

printf 'config dir: %s\n' "$LOCALCODE_HOME"

if ! command -v pi >/dev/null 2>&1; then
  printf 'pi is not installed. Install from https://pi.dev, then re-run.\n'
  exit 2
fi

step "version, help, config"
out="$("$LOCALCODE" version 2>&1)"
expect "version prints localcode" 'localcode [0-9]+\.[0-9]+' "$out"
out="$("$LOCALCODE" help 2>&1)"
expect "help lists commands" 'localcode doctor' "$out"
out="$("$LOCALCODE" config 2>&1)"
expect "config points at the wrapper dir" "$LOCALCODE_HOME" "$out"

step "init seeds the config dir"
out="$("$LOCALCODE" init 2>&1)"
expect "init reports the dir" 'config dir' "$out"
expect_file "models.json seeded" "$LOCALCODE_HOME/models.json"
expect_file "settings.json seeded" "$LOCALCODE_HOME/settings.json"
expect_file "exa extension copied" "$LOCALCODE_HOME/extensions/exa.ts"

if jq -e '.providers.masa.apiKey == "$MASA_TOKEN"' "$LOCALCODE_HOME/models.json" >/dev/null 2>&1; then
  ok "models.json holds no literal token"
else
  bad "models.json holds no literal token"
fi
ctx="$(jq -r '.providers.masa.models[0].contextWindow' "$LOCALCODE_HOME/models.json" 2>/dev/null)"
if [[ "$ctx" == "131072" ]]; then
  ok "context budget fits the 1 MB gateway cap"
else
  bad "context budget fits the 1 MB gateway cap (got ${ctx:-none})"
fi

step "doctor"
out="$("$LOCALCODE" doctor 2>&1)"
doctor_rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
expect "doctor ran checks" 'request body budget' "$out"

tok="${MASA_TOKEN:-${LOCAL_LLM_API_KEY:-}}"
if [[ -n "$tok" ]] && printf '%s' "$out" | grep -qF -- "$tok"; then
  bad "doctor hides the gateway token"
else
  ok "doctor hides the gateway token"
fi
if [[ -n "${EXA_API_KEY:-}" ]] && printf '%s' "$out" | grep -qF -- "$EXA_API_KEY"; then
  bad "doctor hides the Exa key"
else
  ok "doctor hides the Exa key"
fi

if [[ -z "${MASA_TOKEN:-${LOCAL_LLM_API_KEY:-}}" ]]; then
  skip "gateway checks (no MASA_TOKEN)"
  skip "model round trip"
  skip "web tools round trip"
else
  step "gateway"
  out="$("$LOCALCODE" models 2>&1)"
  expect "gateway lists a model" 'Qwen' "$out"
  out="$("$LOCALCODE" doctor 2>&1)"
  expect "gateway reachable" $'ok       gateway model list' "$out"

  step "model round trip through the gateway, with gh via bash"
  out="$("$LOCALCODE" --no-skills --no-prompt-templates --no-themes -p \
    "Do exactly two things. First, use the bash tool to run: gh --version. Second, use the bash tool to run: echo ready. Then answer in two lines: the first line of the gh version output, and the word that echo printed." 2>&1)"
  printf '%s\n' "$out" | sed 's/^/      | /' | tail -8
  expect "gh works inside the agent" 'gh version [0-9]' "$out"
  expect "bash echo works" 'ready' "$out"

  step "pi flag passthrough"
out="$("$LOCALCODE" --version 2>&1)"
if printf '%s' "$out" | grep -q 'unknown command'; then
  bad "a leading pi flag reaches pi"
  printf '%s\n' "$out" | sed 's/^/      | /' | head -4
else
  ok "a leading pi flag reaches pi  ($out)"
fi

step "bundled web tools"
  out="$("$LOCALCODE" --no-skills --no-prompt-templates --no-themes \
    -t webfetch -p "Call the webfetch tool on https://go.dev/dl/?mode=json and report the first version string in the response. If the tool errors, quote the error." 2>&1)"
  printf '%s\n' "$out" | sed 's/^/      | /' | tail -6
  expect "webfetch returns real page data" 'go1\.[0-9]+' "$out"

  if [[ -n "${EXA_API_KEY:-}" ]]; then
    out="$("$LOCALCODE" --no-skills --no-prompt-templates --no-themes \
      -t websearch -p "Call the websearch tool with query 'latest stable rust release'. Report the version number. If the tool errors, quote the error." 2>&1)"
    printf '%s\n' "$out" | sed 's/^/      | /' | tail -6
    if printf '%s' "$out" | grep -q 'EXA_API_KEY is missing'; then
      bad "websearch reached Exa"
    elif printf '%s' "$out" | grep -qE '1\.[0-9]{2}'; then
      ok "websearch returned a rust version"
    else
      bad "websearch returned a rust version"
    fi
  else
    skip "websearch round trip (no EXA_API_KEY)"
  fi

  step "config dir isolation"
  sessions="$(find "$LOCALCODE_HOME/sessions" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${sessions:-0}" -ge 1 ]]; then
    ok "sessions land in the wrapper dir ($sessions files)"
  else
    bad "sessions land in the wrapper dir"
  fi
fi

step "gh passthrough"
if command -v gh >/dev/null 2>&1; then
  out="$("$LOCALCODE" gh --version 2>&1)"
  expect "localcode gh runs the CLI" 'gh version' "$out"
else
  skip "gh passthrough (gh not installed)"
fi

step "exa toggle"
out="$("$LOCALCODE" exa off 2>&1)"
expect "exa off" 'off' "$out"
expect_exists "disable marker written" "$LOCALCODE_HOME/exa.disabled"
out="$("$LOCALCODE" config 2>&1)"
expect "config reports exa off" 'Exa off' "$out"
out="$("$LOCALCODE" exa on 2>&1)"
expect "exa on" 'on' "$out"

printf '\n\033[1m=== summary: %d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
printf 'config dir left at %s\n' "$LOCALCODE_HOME"
if [[ "$OWN_HOME" == "1" ]]; then
  rm -rf "$LOCALCODE_HOME"
  printf 'removed the temporary config dir\n'
fi
[[ "$FAIL" -eq 0 ]]
