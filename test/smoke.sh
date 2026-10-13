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

step "webfetch page text"
if command -v node >/dev/null 2>&1; then
  out="$(node --test-reporter=spec "$ROOT/test/pagetext.test.mjs" 2>&1)"
  if [[ $? -eq 0 ]]; then
    ok "pageText is linear and keeps the old output for closed HTML"
  else
    bad "pageText is linear and keeps the old output for closed HTML"
  fi
  printf '%s\n' "$out" | sed 's/^/      | /'
else
  skip "pageText test (node is not installed)"
fi

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
expect_file "settings.json seeded" "$LOCALCODE_HOME/settings.json"
expect_file "exa extension copied" "$LOCALCODE_HOME/extensions/exa.ts"
if [[ -e "$ROOT/config/models.json" ]]; then
  bad "no models.json ships in the repo"
else
  ok "no models.json ships in the repo"
fi

step "limits come from the gateway (fake gateway)"
FAKE="$(mktemp -d -t localcode-fake)"
cat >"$FAKE/ok.json" <<'JSON'
{"object":"list","data":[
 {"id":"model-a","context_window":131072,"max_model_len":131072,"max_output_tokens":32768,"limits":{"max_body_bytes":33554432,"requests_per_minute":30,"max_concurrent":2}},
 {"id":"model-b","context_window":65536,"max_output_tokens":8192,"limits":{"max_body_bytes":33554432,"max_concurrent":2}},
 {"id":"model-c","context_window":1000,"max_output_tokens":5000,"limits":{"max_body_bytes":33554432,"max_concurrent":2}}
]}
JSON
cat >"$FAKE/old.json" <<'JSON'
{"object":"list","data":[{"id":"model-a","max_model_len":131072}]}
JSON
cat >"$FAKE/small.json" <<'JSON'
{"object":"list","data":[{"id":"model-a","context_window":1000000,"max_output_tokens":4096,"limits":{"max_body_bytes":1000,"max_concurrent":2}}]}
JSON
mkdir -p "$FAKE/bin"
cat >"$FAKE/bin/pi" <<'SH'
#!/bin/sh
echo "FAKEPI dir=$PI_CODING_AGENT_DIR args=$*"
SH
chmod +x "$FAKE/bin/pi"

start_fake() {
  rm -f "$FAKE/port"
  node "$ROOT/test/fakegateway.mjs" "$FAKE/$1.json" "$FAKE/port" &
  FAKE_PID=$!
  for _ in $(seq 1 50); do [[ -s "$FAKE/port" ]] && break; sleep 0.1; done
  FAKE_URL="http://127.0.0.1:$(cat "$FAKE/port")/v1"
}

stop_fake() { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }

fake() {
  local home="$1"
  shift
  env -u LOCALCODE_MODEL LOCALCODE_HOME="$home" LOCALCODE_BASE_URL="$FAKE_URL" MASA_TOKEN=fake-token "$@"
}

if command -v node >/dev/null 2>&1; then
  start_fake ok
  H="$FAKE/home-ok"

  out="$(fake "$H" "$LOCALCODE" init 2>&1)"
  expect "init names the first model" 'model: +masa/model-a' "$out"
  expect "init reports gateway limits" 'context: +131072 tokens, max output 32768 tokens' "$out"
  m="$H/models.json"
  if [[ "$(jq -r '.providers.masa.models | map(.id) | join(",")' "$m")" == "model-a,model-b,model-c" ]]; then ok "models.json lists every gateway model"; else bad "models.json lists every gateway model"; fi
  if [[ "$(jq -r '.providers.masa.models[0] | "\(.contextWindow) \(.maxTokens)"' "$m")" == "131072 32768" ]]; then ok "model-a limits copied from the gateway"; else bad "model-a limits copied from the gateway"; fi
  if [[ "$(jq -r '.providers.masa.models[1] | "\(.contextWindow) \(.maxTokens)"' "$m")" == "65536 8192" ]]; then ok "model-b limits copied from the gateway"; else bad "model-b limits copied from the gateway"; fi
  if jq -e '.providers.masa.apiKey == "$MASA_TOKEN"' "$m" >/dev/null 2>&1 && ! grep -rqF "fake-token" "$H"; then ok "no literal token in the config dir"; else bad "no literal token in the config dir"; fi
  if [[ "$(jq -r '.providers.masa.baseUrl' "$m")" == "$FAKE_URL" ]]; then ok "baseUrl follows LOCALCODE_BASE_URL"; else bad "baseUrl follows LOCALCODE_BASE_URL"; fi
  if [[ "$(jq -r '.compaction.modelOverrides["masa/model-a"].reserveTokens' "$H/settings.json")" == "32768" ]]; then ok "reserveTokens follows the output cap"; else bad "reserveTokens follows the output cap"; fi
  if [[ "$(jq -r '.compaction.reserveTokens' "$H/settings.json")" == "16384" ]]; then ok "the user base reserveTokens is untouched"; else bad "the user base reserveTokens is untouched"; fi

  out="$(fake "$H" env LOCALCODE_MODEL=model-b "$LOCALCODE" config 2>&1)"
  expect "LOCALCODE_MODEL selects model-b with its own limits" 'model: +masa/model-b' "$out"
  expect "config shows model-b context" 'context: +65536 tokens' "$out"
  expect "config shows model-b output" 'max output: +8192 tokens' "$out"

  out="$(fake "$H" env LOCALCODE_MODEL=model-c "$LOCALCODE" init 2>&1)"
  if [[ "$(jq -r '.compaction.modelOverrides["masa/model-c"].reserveTokens' "$H/settings.json")" == "500" ]]; then ok "reserveTokens is capped at half the window"; else bad "reserveTokens is capped at half the window"; fi

  out="$(fake "$H" env LOCALCODE_MODEL=nope "$LOCALCODE" init 2>&1)"
  expect "unknown LOCALCODE_MODEL names the valid ids" 'not available.*model-a, model-b, model-c' "$out"

  out="$(PATH="$FAKE/bin:$PATH" fake "$H" env LOCALCODE_MODEL=model-b "$LOCALCODE" -p hi 2>&1)"
  expect "run uses the wrapper config dir" "FAKEPI dir=$H " "$out"
  expect "run passes the discovered model to pi" 'args=--model masa/model-b' "$out"

  out="$(fake "$H" "$LOCALCODE" models 2>&1)"
  expect "models lists limits" 'model-a +131072 +32768' "$out"
  out="$(fake "$H" "$LOCALCODE" models --write 2>&1 || true)"
  expect "models --write is gone" 'usage: localcode models' "$out"

  out="$(fake "$H" "$LOCALCODE" doctor 2>&1 || true)"
  expect "doctor lists model limits" 'model-b +context 65536 +max output 8192' "$out"
  expect "doctor passes a wide body budget" 'ok       request body budget' "$out"
  expect "doctor reads concurrency from the gateway" 'allows 2 concurrent requests' "$out"

  out="$(env LOCALCODE_HOME="$FAKE/home-badtoken" LOCALCODE_BASE_URL="$FAKE_URL" MASA_TOKEN=wrong "$LOCALCODE" init 2>&1)"
  expect "bad token shows the gateway reply" 'gateway returned no models.*bad token' "$out"
  out="$(env LOCALCODE_HOME="$FAKE/home-badtoken" LOCALCODE_BASE_URL="$FAKE_URL" MASA_TOKEN=wrong "$LOCALCODE" -p hi 2>&1; echo "rc=$?")"
  expect "run refuses to start on a bad token" 'rc=1' "$out"
  stop_fake

  out="$(env LOCALCODE_HOME="$FAKE/home-down" LOCALCODE_BASE_URL="http://127.0.0.1:1/v1" MASA_TOKEN=fake-token "$LOCALCODE" init 2>&1; echo "rc=$?")"
  expect "init survives an unreachable gateway" 'rc=0' "$out"
  expect "unreachable gateway names LOCALCODE_BASE_URL" 'cannot reach the gateway.*LOCALCODE_BASE_URL' "$out"

  start_fake old
  out="$(fake "$FAKE/home-old" "$LOCALCODE" -p hi 2>&1; echo "rc=$?")"
  expect "old llm_proxy without limits is refused" 'does not report context_window and max_output_tokens.*upgrade llm_proxy' "$out"
  expect "old llm_proxy makes run exit 1" 'rc=1' "$out"
  stop_fake

  start_fake small
  out="$(fake "$FAKE/home-small" "$LOCALCODE" doctor 2>&1 || true)"
  expect "doctor flags a body cap below the context budget" 'PROBLEM  request body budget' "$out"
  stop_fake
else
  skip "fake gateway checks (node is not installed)"
fi
rm -rf "$FAKE"

step "doctor"
out="$("$LOCALCODE" doctor 2>&1)"
doctor_rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
expect "doctor ran checks" 'MASA_TOKEN set' "$out"

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

step "version consistency"
script_version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/bin/localcode")"
pkg_version="$(jq -r .version "$ROOT/package.json")"
if [[ -n "$script_version" && "$script_version" == "$pkg_version" ]]; then
  ok "bin/localcode and package.json agree on $script_version"
else
  bad "version mismatch: bin/localcode=$script_version package.json=$pkg_version"
fi

step "update"
UPD="$(mktemp -d -t localcode-update)"
GITC=(git -c user.name=smoke -c user.email=smoke@example.invalid -c commit.gpgsign=false)
printf '{"tag_name": "v99.0.0"}' >"$UPD/latest.json"
out="$(LOCALCODE_RELEASES_URL="file://$UPD/latest.json" "$LOCALCODE" update --check 2>&1)"
expect "update --check reports a newer release" 'latest: +99\.0\.0\. Run: localcode update' "$out"
printf '{"tag_name": "v%s"}' "$script_version" >"$UPD/same.json"
out="$(LOCALCODE_RELEASES_URL="file://$UPD/same.json" "$LOCALCODE" update --check 2>&1)"
expect "update --check reports up to date" 'up to date' "$out"
out="$(LOCALCODE_RELEASES_URL="file://$UPD/missing.json" "$LOCALCODE" update --check 2>&1)"
expect "update --check survives an unreachable endpoint" 'latest: +unknown' "$out"
out="$(LOCALCODE_RELEASES_URL="file://$UPD/latest.json" "$LOCALCODE" doctor 2>&1 || true)"
expect "doctor notes a newer release" 'localcode 99\.0\.0 is available' "$out"
out="$("$LOCALCODE" update --bogus 2>&1 || true)"
expect "update rejects an unknown argument" 'usage: localcode update' "$out"

git init -q --bare -b main "$UPD/origin.git"
git init -q -b main "$UPD/clone"
mkdir -p "$UPD/clone"
cp -R "$ROOT/bin" "$ROOT/config" "$ROOT/extensions" "$UPD/clone/"
"${GITC[@]}" -C "$UPD/clone" add -A
"${GITC[@]}" -C "$UPD/clone" commit -q -m base
git -C "$UPD/clone" remote add origin "$UPD/origin.git"
git -C "$UPD/clone" push -q -u origin main
git clone -q "$UPD/origin.git" "$UPD/other"
printf 'new\n' >"$UPD/other/NEWFILE"
"${GITC[@]}" -C "$UPD/other" add -A
"${GITC[@]}" -C "$UPD/other" commit -q -m next
git -C "$UPD/other" push -q origin main
out="$(LOCALCODE_HOME="$UPD/home-clone" "$UPD/clone/bin/localcode" update 2>&1)"
expect "git clone update runs init after the pull" 'config dir: .*home-clone' "$out"
expect_exists "git clone update pulled the new commit" "$UPD/clone/NEWFILE"

printf '# local edit\n' >>"$UPD/clone/bin/localcode"
printf '# upstream edit\n' >>"$UPD/other/bin/localcode"
"${GITC[@]}" -C "$UPD/other" commit -q -am again
git -C "$UPD/other" push -q origin main
out="$(LOCALCODE_HOME="$UPD/home-clone" "$UPD/clone/bin/localcode" update 2>&1 || true)"
expect "git clone update names the fix when the pull fails" 'Commit or stash local changes' "$out"

KEG="$UPD/Cellar/localcode/0.0.0/libexec"
mkdir -p "$KEG" "$UPD/opt/localcode" "$UPD/fakebin"
cp -R "$ROOT/bin" "$ROOT/config" "$ROOT/extensions" "$KEG/"
mkdir -p "$UPD/opt/localcode/bin"
ln -s "$KEG/bin/localcode" "$UPD/opt/localcode/bin/localcode"
cat >"$UPD/fakebin/brew" <<FAKE
#!/bin/sh
echo "\$@" >>"$UPD/brew.log"
if [ "\$1" = "--prefix" ]; then
  echo "$UPD/opt/localcode"
fi
FAKE
chmod +x "$UPD/fakebin/brew"
out="$(PATH="$UPD/fakebin:$PATH" LOCALCODE_HOME="$UPD/home-brew" "$KEG/bin/localcode" update 2>&1)"
expect "brew update runs init after the upgrade" 'config dir: .*home-brew' "$out"
expect "brew update upgrades the tap formula" 'upgrade ordishs/tap/localcode' "$(cat "$UPD/brew.log")"

PLAIN="$UPD/plain"
mkdir -p "$PLAIN"
cp -R "$ROOT/bin" "$ROOT/config" "$ROOT/extensions" "$PLAIN/"
out="$("$PLAIN/bin/localcode" update 2>&1 || true)"
expect "unknown install names the fix" 'brew install ordishs/tap/localcode' "$out"
rm -rf "$UPD"

step "formula template"
tpl="$ROOT/packaging/localcode.rb.in"
expect "template has url and sha256 slots" '@URL@' "$(cat "$tpl")"
expect "template installs the wrapper tree" 'libexec.install "bin", "config", "extensions"' "$(cat "$tpl")"

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
