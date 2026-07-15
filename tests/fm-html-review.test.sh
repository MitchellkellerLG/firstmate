#!/usr/bin/env bash
# Focused behavior tests for the canonical sessionless HTML review handoff.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HTML_REVIEW="$ROOT/bin/fm-html-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-html-review-tests)
TEST_HOME="$TMP_ROOT/home"
mkdir -p "$TEST_HOME"
review_url=''
occupied_pid=''

cleanup_review() {
  if [ -n "$review_url" ]; then
    FM_HOME="$TEST_HOME" FM_HTML_REVIEW_PLATFORM_OVERRIDE=linux \
      "$HTML_REVIEW" --stop "$review_url" >/dev/null 2>&1 || true
  fi
  if [ -n "$occupied_pid" ]; then
    kill "$occupied_pid" 2>/dev/null || true
    wait "$occupied_pid" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_review EXIT

test_native_linux_serves_exact_identified_html() {
  local artifact stdout stderr rc body status content_type token hash_one hash_two stop_out
  artifact="$TMP_ROOT/review.html"
  stdout="$TMP_ROOT/stdout"
  stderr="$TMP_ROOT/stderr"
  body="$TMP_ROOT/body"
  printf '<!doctype html><html><body>native-linux-review</body></html>\n' > "$artifact"

  set +e
  FM_HOME="$TEST_HOME" FM_HTML_REVIEW_PLATFORM_OVERRIDE=linux \
    "$HTML_REVIEW" "$artifact" > "$stdout" 2> "$stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "native Linux delivery"
  [ ! -s "$stderr" ] || fail "native Linux delivery should not write stderr"
  [ "$(wc -l < "$stdout")" -eq 1 ] || fail "native Linux delivery should print exactly one line"
  review_url=$(cat "$stdout")
  [[ "$review_url" =~ ^http://127\.0\.0\.1:[0-9]+/__firstmate_artifact/([0-9a-f]{32})\?v=[0-9a-f]{16}$ ]] \
    || fail "native Linux delivery should print one opaque loopback URL"
  token=${BASH_REMATCH[1]}

  status=$(curl --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
    --output "$body" --write-out '%{http_code}' "$review_url")
  [ "$status" = 200 ] || fail "native Linux URL should return HTTP 200"
  content_type=$(curl --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
    --output /dev/null --write-out '%{content_type}' "$review_url")
  case "$content_type" in
    text/html|text/html\;*) ;;
    *) fail "native Linux URL should return text/html" ;;
  esac
  assert_grep 'native-linux-review' "$body" "served body should contain the finalized review"
  assert_grep "fm-html-review:$token" "$body" "served body should contain its per-delivery marker"
  hash_one=$(sha256sum "$body" | awk '{print $1}')
  curl --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
    --output "$TMP_ROOT/body-second" "$review_url"
  hash_two=$(sha256sum "$TMP_ROOT/body-second" | awk '{print $1}')
  [ "$hash_one" = "$hash_two" ] || fail "repeated requests should return immutable exact bytes"

  stop_out=$(FM_HOME="$TEST_HOME" FM_HTML_REVIEW_PLATFORM_OVERRIDE=linux \
    "$HTML_REVIEW" --stop "$review_url")
  [ "$stop_out" = stopped ] || fail "owned lifecycle stop should confirm completion"
  review_url=''
  pass "fm-html-review serves exact identified HTML on native Linux and stops its owned server"
}

make_wsl_fakes() {
  local fakebin=$1
  cat > "$fakebin/wslpath" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -w ] && [ "$#" -eq 2 ] || exit 2
printf '%s\n' "$2"
SH
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' -Command '*)
    printf 'Win32NT\n'
    exit 0
    ;;
esac
url=''
expected_hash=''
marker=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -Url) url=$2; shift 2 ;;
    -ExpectedSha256) expected_hash=$2; shift 2 ;;
    -ExpectedMarker) marker=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$url" ] && [ -n "$expected_hash" ] && [ -n "$marker" ] || exit 22
printf '%s\n' "$url" >> "$FM_TEST_PS_LOG"
case "${FM_TEST_PS_SCENARIO:-}" in
  wrong)
    printf '{"ok":false,"requested_url":"%s","effective_url":"%s","status":200,"content_type":"text/html","bytes":13,"sha256":"%064d","identity_ok":false,"url_ok":true,"expected_marker":"%s"}\n' \
      "$url" "$url" 0 "$marker"
    exit 20
    ;;
  missing)
    printf '{"ok":false,"requested_url":"%s","effective_url":"%s","status":404,"content_type":"text/html","bytes":9,"sha256":"%064d","identity_ok":false,"url_ok":true,"expected_marker":"%s"}\n' \
      "$url" "$url" 0 "$marker"
    exit 20
    ;;
  transport) exit 21 ;;
  *) exit 23 ;;
esac
SH
  chmod +x "$fakebin/wslpath" "$fakebin/powershell.exe"
}

assert_fail_closed() {
  local stdout=$1 stderr=$2 label=$3 combined
  [ ! -s "$stdout" ] || fail "$label should keep stdout empty"
  combined=$(cat "$stdout" "$stderr")
  assert_not_contains "$combined" 'http://' "$label should not expose an HTTP URL"
  assert_not_contains "$combined" 'https://' "$label should not expose an HTTPS URL"
}

run_wsl_failure() {
  local scenario=$1 case_dir fakebin artifact stdout stderr rc expected_calls calls candidate
  case_dir="$TMP_ROOT/wsl-$scenario"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$case_dir/home"
  make_wsl_fakes "$fakebin"
  artifact="$case_dir/review.html"
  stdout="$case_dir/stdout"
  stderr="$case_dir/stderr"
  printf '<!doctype html><html><body>wsl-%s</body></html>\n' "$scenario" > "$artifact"
  : > "$case_dir/powershell.log"

  set +e
  PATH="$fakebin:$PATH" FM_HOME="$case_dir/home" FM_HTML_REVIEW_PLATFORM_OVERRIDE=wsl \
    FM_TEST_PS_SCENARIO="$scenario" FM_TEST_PS_LOG="$case_dir/powershell.log" \
    "$HTML_REVIEW" "$artifact" > "$stdout" 2> "$stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "WSL $scenario should fail verification"
  assert_fail_closed "$stdout" "$stderr" "WSL $scenario"
  if [ "$scenario" = transport ]; then expected_calls=1; else expected_calls=3; fi
  calls=$(wc -l < "$case_dir/powershell.log")
  [ "$calls" -eq "$expected_calls" ] || fail "WSL $scenario should use $expected_calls verifier attempt(s)"
  while IFS= read -r candidate; do
    if curl --silent --noproxy '*' --connect-timeout 1 --max-time 1 "$candidate" >/dev/null 2>&1; then
      fail "WSL $scenario should clean each rejected listener"
    fi
  done < "$case_dir/powershell.log"
  [ ! -d "$case_dir/home/state/html-reviews" ] ||
    [ -z "$(find "$case_dir/home/state/html-reviews" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    fail "WSL $scenario should remove private launch state"
}

test_wsl_wrong_identity_fails_closed() {
  run_wsl_failure wrong
  pass "fm-html-review rejects Windows HTTP 200 with the wrong artifact identity"
}

test_wsl_404_fails_closed() {
  run_wsl_failure missing
  pass "fm-html-review rejects Windows HTTP 404 after Linux-local success"
}

test_wsl_transport_fails_closed() {
  run_wsl_failure transport
  pass "fm-html-review rejects a Windows verifier transport failure"
}

test_ambiguous_runtime_fails_closed() {
  local case_dir artifact stdout stderr rc
  case_dir="$TMP_ROOT/ambiguous"
  mkdir -p "$case_dir/home"
  artifact="$case_dir/review.html"
  stdout="$case_dir/stdout"
  stderr="$case_dir/stderr"
  printf '<html><body>ambiguous</body></html>\n' > "$artifact"
  set +e
  FM_HOME="$case_dir/home" FM_HTML_REVIEW_PLATFORM_OVERRIDE=ambiguous \
    "$HTML_REVIEW" "$artifact" > "$stdout" 2> "$stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ambiguous runtime should fail"
  assert_fail_closed "$stdout" "$stderr" "ambiguous runtime"
  pass "fm-html-review fails closed when runtime classification is ambiguous"
}

test_occupied_port_preserves_unrelated_listener() {
  local case_dir artifact stdout stderr ready port rc existing_body
  case_dir="$TMP_ROOT/occupied"
  mkdir -p "$case_dir/home"
  ready="$case_dir/ready"
  cat > "$case_dir/listener.mjs" <<'MJS'
import { writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
const server = createServer((_request, response) => {
  response.writeHead(200, { 'Content-Type': 'text/plain' });
  response.end('unrelated-listener\n');
});
server.listen({ host: '127.0.0.1', port: 0 }, () => {
  writeFileSync(process.argv[2], `${server.address().port}\n`);
});
MJS
  node "$case_dir/listener.mjs" "$ready" > "$case_dir/listener.log" 2>&1 &
  occupied_pid=$!
  for ((i = 0; i < 100; i++)); do
    [ -s "$ready" ] && break
    kill -0 "$occupied_pid" 2>/dev/null || fail "unrelated listener exited during setup"
    sleep 0.05
  done
  [ -s "$ready" ] || fail "unrelated listener did not become ready"
  port=$(tr -d '\r\n' < "$ready")
  artifact="$case_dir/review.html"
  stdout="$case_dir/stdout"
  stderr="$case_dir/stderr"
  printf '<html><body>occupied</body></html>\n' > "$artifact"

  set +e
  FM_HOME="$case_dir/home" FM_HTML_REVIEW_PLATFORM_OVERRIDE=linux \
    "$HTML_REVIEW" --port "$port" "$artifact" > "$stdout" 2> "$stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "occupied explicit port should fail"
  assert_fail_closed "$stdout" "$stderr" "occupied port"
  existing_body=$(curl --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:$port/")
  [ "$existing_body" = unrelated-listener ] || fail "occupied port failure should preserve the unrelated listener"
  kill "$occupied_pid"
  wait "$occupied_pid" 2>/dev/null || true
  occupied_pid=''
  pass "fm-html-review preserves an unrelated listener on an occupied port"
}

test_lavish_state_is_irrelevant() {
  local case_dir fakebin artifact stdout stderr rc url
  case_dir="$TMP_ROOT/lavish-independent"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$case_dir/home/.lavish-axi" "$case_dir/fm-home"
  printf '{not valid lavish state\n' > "$case_dir/home/.lavish-axi/state.json"
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'invoked\n' >> "$FM_TEST_LAVISH_LOG"
exit 99
SH
  chmod +x "$fakebin/lavish-axi"
  : > "$case_dir/lavish.log"
  artifact="$case_dir/review.html"
  stdout="$case_dir/stdout"
  stderr="$case_dir/stderr"
  printf '<html><body>lavish-independent</body></html>\n' > "$artifact"
  set +e
  PATH="$fakebin:$PATH" HOME="$case_dir/home" FM_HOME="$case_dir/fm-home" \
    FM_HTML_REVIEW_PLATFORM_OVERRIDE=linux FM_TEST_LAVISH_LOG="$case_dir/lavish.log" \
    "$HTML_REVIEW" "$artifact" > "$stdout" 2> "$stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "Lavish-independent delivery"
  [ ! -s "$stderr" ] || fail "Lavish-independent delivery should not write stderr"
  [ ! -s "$case_dir/lavish.log" ] || fail "fm-html-review must never invoke lavish-axi"
  url=$(cat "$stdout")
  FM_HOME="$case_dir/fm-home" FM_HTML_REVIEW_PLATFORM_OVERRIDE=linux \
    "$HTML_REVIEW" --stop "$url" >/dev/null
  pass "fm-html-review is independent of invalid Lavish state and never invokes lavish-axi"
}

test_native_linux_serves_exact_identified_html
test_wsl_wrong_identity_fails_closed
test_wsl_404_fails_closed
test_wsl_transport_fails_closed
test_ambiguous_runtime_fails_closed
test_occupied_port_preserves_unrelated_listener
test_lavish_state_is_irrelevant
