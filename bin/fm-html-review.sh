#!/usr/bin/env bash
# fm-html-review.sh - serve and verify one finalized HTML review artifact.
#
# BEGIN FM_HTML_REVIEW_HELP
# Usage:
#   fm-html-review.sh [--port <port>] <html-file>
#   fm-html-review.sh --stop <verified-url>
#
# This command is the canonical owner of Firstmate's captain-facing local HTML
# delivery contract.
# It copies the input into private Firstmate state, appends an inert fresh
# per-delivery identity marker, and serves those immutable bytes at one opaque
# IPv4-loopback URL without using Lavish sessions or state.
# It prints that URL only after a bounded proxy-free local request returns 200
# with text/html and matches the exact SHA-256, byte content, and marker.
# Native Linux uses that local proof; WSL additionally requires a bounded
# redirect-disabled and proxy-disabled request from Windows PowerShell against
# the exact same URL, with status 200, text/html, matching SHA-256 and marker,
# and unchanged requested and effective URLs.
# Unknown or contradictory runtimes, missing capabilities, malformed verifier
# output, transport failures, changed content, and every other ambiguity fail
# closed without emitting any URL-like string.
# A WSL response that proves the Windows namespace reached a wrong listener is
# retried with a fresh port-zero listener at most three times.
# The optional --port seam requests one explicit listener port and disables
# retries; it fails without disturbing an existing listener when occupied.
# On success the verified server remains alive until `--stop <verified-url>` is
# called; stop uses a private per-delivery secret and never kills by name or port.
# A failed launch cleans only the exact child process and private files created
# by that invocation.
# Success writes exactly the verified URL to stdout; diagnostics use stderr.
# END FM_HTML_REVIEW_HELP
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

show_help() {
  sed -n '/^# BEGIN FM_HTML_REVIEW_HELP$/,/^# END FM_HTML_REVIEW_HELP$/ {
    /^# BEGIN FM_HTML_REVIEW_HELP$/d
    /^# END FM_HTML_REVIEW_HELP$/d
    s/^# \{0,1\}//
    p
  }' "$0"
}

die() {
  printf 'fm-html-review: %s\n' "$1" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

state_root() {
  local home state
  home=${FM_HOME:-$FM_ROOT}
  state=${FM_STATE_OVERRIDE:-$home/state}
  printf '%s/html-reviews\n' "$state"
}

detect_runtime() {
  local override=${FM_HTML_REVIEW_PLATFORM_OVERRIDE:-} system release
  if [ -n "$override" ]; then
    case "$override" in
      linux|wsl) printf '%s\n' "$override"; return 0 ;;
      *) return 1 ;;
    esac
  fi

  system=$(uname -s 2>/dev/null) || return 1
  [ "$system" = Linux ] || return 1
  if [ -r /proc/sys/kernel/osrelease ]; then
    release=$(tr '[:upper:]' '[:lower:]' </proc/sys/kernel/osrelease) || return 1
  elif [ -r /proc/version ]; then
    release=$(tr '[:upper:]' '[:lower:]' </proc/version) || return 1
  else
    return 1
  fi

  case "$release" in
    *microsoft*) printf 'wsl\n' ;;
    *)
      if [ -n "${WSL_INTEROP:-}" ] || [ -n "${WSL_DISTRO_NAME:-}" ]; then
        return 1
      fi
      printf 'linux\n'
      ;;
  esac
}

random_hex() {
  local bytes=$1 value
  value=$(node -e 'process.stdout.write(require("crypto").randomBytes(Number(process.argv[1])).toString("hex"))' "$bytes" 2>/dev/null) || return 1
  case "$value" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#value}" -eq "$((bytes * 2))" ] || return 1
  printf '%s\n' "$value"
}

write_server_helper() {
  local target=$1
  sed 's/^+//' > "$target" <<'MJS'
+import { createHash } from 'node:crypto';
+import { readFileSync, writeFileSync } from 'node:fs';
+import { createServer } from 'node:http';
+
+const [artifactPath, artifactToken, expectedHash, marker, stopToken, rawPort, readyPath] = process.argv.slice(2);
+const port = Number(rawPort);
+if (!artifactPath || !/^[0-9a-f]{32}$/.test(artifactToken || '') ||
+    !/^[0-9a-f]{64}$/.test(expectedHash || '') || marker !== `fm-html-review:${artifactToken}` ||
+    !/^[0-9a-f]{64}$/.test(stopToken || '') || !Number.isInteger(port) ||
+    port < 0 || port > 65535 || !readyPath) process.exit(2);
+const artifact = readFileSync(artifactPath);
+const actualHash = createHash('sha256').update(artifact).digest('hex');
+if (actualHash !== expectedHash || !artifact.includes(Buffer.from(marker, 'utf8'))) process.exit(3);
+const artifactRoute = `/__firstmate_artifact/${artifactToken}?v=${expectedHash.slice(0, 16)}`;
+const stopRoute = `/__firstmate_stop/${stopToken}`;
+let stopping = false;
+const server = createServer((request, response) => {
+  if (request.method === 'GET' && request.url === artifactRoute) {
+    response.writeHead(200, {
+      'Cache-Control': 'no-store, max-age=0',
+      'Content-Length': artifact.length,
+      'Content-Type': 'text/html; charset=utf-8',
+      'X-Content-Type-Options': 'nosniff',
+    });
+    response.end(artifact);
+    return;
+  }
+  if (request.method === 'POST' && request.url === stopRoute && !stopping) {
+    stopping = true;
+    response.writeHead(200, { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' });
+    response.end('stopping\n', () => {
+      server.close(() => process.exit(0));
+      server.closeIdleConnections?.();
+      setTimeout(() => process.exit(0), 1000);
+    });
+    return;
+  }
+  response.writeHead(404, { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' });
+  response.end('not found\n');
+});
+const stopForSignal = () => {
+  if (stopping) return;
+  stopping = true;
+  server.close(() => process.exit(0));
+  server.closeAllConnections?.();
+  setTimeout(() => process.exit(0), 1000);
+};
+process.on('SIGINT', stopForSignal);
+process.on('SIGTERM', stopForSignal);
+server.on('error', () => process.exit(4));
+server.listen({ host: '127.0.0.1', port, exclusive: true }, () => {
+  const address = server.address();
+  if (!address || typeof address === 'string') process.exit(5);
+  writeFileSync(readyPath, `${address.port}\n`, { mode: 0o600 });
+});
MJS
}

write_result_helper() {
  local target=$1
  sed 's/^+//' > "$target" <<'MJS'
+import { readFileSync } from 'node:fs';
+const [resultPath, expectedUrl, expectedHash, expectedMarker, rawExit] = process.argv.slice(2);
+const verifierExit = Number(rawExit);
+try {
+  const raw = readFileSync(resultPath, 'utf8').trim();
+  if (!raw || /[\r\n]/.test(raw)) throw new Error('result is not one record');
+  const result = JSON.parse(raw);
+  if (!result || Array.isArray(result) || typeof result !== 'object') throw new Error('not an object');
+  if (result.requested_url !== expectedUrl || result.effective_url !== expectedUrl || result.url_ok !== true) {
+    throw new Error('URL identity mismatch');
+  }
+  if (!Number.isInteger(result.status) || result.status < 100 || result.status > 599) throw new Error('bad status');
+  if (typeof result.content_type !== 'string' || typeof result.sha256 !== 'string' ||
+      !Number.isInteger(result.bytes) || result.bytes < 0 || typeof result.identity_ok !== 'boolean' ||
+      typeof result.ok !== 'boolean' || result.expected_marker !== expectedMarker) throw new Error('bad fields');
+  if (!/^[0-9a-f]{64}$/.test(result.sha256)) throw new Error('bad hash');
+  const mediaType = result.content_type.split(';', 1)[0].trim().toLowerCase();
+  const exact = result.status === 200 && mediaType === 'text/html' &&
+    result.sha256 === expectedHash && result.identity_ok === true;
+  if (verifierExit === 0 && result.ok === true && exact) process.stdout.write('ok\n');
+  else if (verifierExit === 20 && result.ok === false && !exact) process.stdout.write('retry\n');
+  else throw new Error('inconsistent outcome');
+} catch {
+  process.exit(1);
+}
MJS
}

write_windows_helper() {
  local target=$1
  sed 's/^+//' > "$target" <<'POWERSHELL'
+param(
+  [Parameter(Mandatory = $true)][string]$Url,
+  [Parameter(Mandatory = $true)][string]$ExpectedSha256,
+  [Parameter(Mandatory = $true)][string]$ExpectedMarker,
+  [Parameter(Mandatory = $true)][int]$TimeoutSeconds
+)
+$ErrorActionPreference = 'Stop'
+$handler = $null
+$client = $null
+$response = $null
+try {
+  Add-Type -AssemblyName System.Net.Http
+  $handler = New-Object System.Net.Http.HttpClientHandler
+  $handler.AllowAutoRedirect = $false
+  $handler.UseProxy = $false
+  $client = New-Object System.Net.Http.HttpClient($handler)
+  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
+  $client.DefaultRequestHeaders.CacheControl = New-Object System.Net.Http.Headers.CacheControlHeaderValue
+  $client.DefaultRequestHeaders.CacheControl.NoCache = $true
+  $client.DefaultRequestHeaders.CacheControl.NoStore = $true
+  $response = $client.GetAsync($Url).GetAwaiter().GetResult()
+  $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
+  $sha = [System.Security.Cryptography.SHA256]::Create()
+  try { $actualSha256 = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
+  finally { $sha.Dispose() }
+  $content = [Text.Encoding]::UTF8.GetString($bytes)
+  $effectiveUrl = $response.RequestMessage.RequestUri.AbsoluteUri
+  $contentType = ''
+  if ($null -ne $response.Content.Headers.ContentType) { $contentType = $response.Content.Headers.ContentType.ToString() }
+  $identityOk = $content.Contains($ExpectedMarker)
+  $urlOk = ($effectiveUrl -ceq $Url)
+  $ok = ([int]$response.StatusCode -eq 200) -and
+    ($contentType.Split(';')[0].Trim().ToLowerInvariant() -eq 'text/html') -and
+    ($actualSha256 -ceq $ExpectedSha256) -and $identityOk -and $urlOk
+  [ordered]@{ ok = $ok; requested_url = $Url; effective_url = $effectiveUrl;
+    status = [int]$response.StatusCode; content_type = $contentType; bytes = $bytes.Length;
+    sha256 = $actualSha256; identity_ok = $identityOk; url_ok = $urlOk;
+    expected_marker = $ExpectedMarker } | ConvertTo-Json -Compress
+  if ($ok) { exit 0 }
+  exit 20
+} catch {
+  [ordered]@{ ok = $false; requested_url = $Url; error_type = $_.Exception.GetType().FullName } |
+    ConvertTo-Json -Compress
+  exit 21
+} finally {
+  if ($null -ne $response) { $response.Dispose() }
+  if ($null -ne $client) { $client.Dispose() }
+  if ($null -ne $handler) { $handler.Dispose() }
+}
POWERSHELL
}

owned_pid=''
owned_dir=''

stop_owned_pid() {
  if [ -n "$owned_pid" ]; then
    if kill -0 "$owned_pid" 2>/dev/null; then
      kill -TERM "$owned_pid" 2>/dev/null || true
    fi
    wait "$owned_pid" 2>/dev/null || true
    owned_pid=''
  fi
}

cleanup_owned_launch() {
  stop_owned_pid
  if [ -n "$owned_dir" ]; then
    rm -rf -- "$owned_dir"
    owned_dir=''
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT
  cleanup_owned_launch
  exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' HUP INT TERM

stop_review() {
  local verified_url=$1 root token url_port url_prefix dir metadata
  local pid port stop_token hash_prefix expected_hash stop_status stop_rc i

  if [[ "$verified_url" =~ ^http://127\.0\.0\.1:([0-9]+)/__firstmate_artifact/([0-9a-f]{32})\?v=([0-9a-f]{16})$ ]]; then
    url_port=${BASH_REMATCH[1]}
    token=${BASH_REMATCH[2]}
    url_prefix=${BASH_REMATCH[3]}
  else
    die "the stop target is not a verified Firstmate review URL"
  fi

  root=$(state_root)
  dir="$root/$token"
  metadata="$dir/state"
  [ -f "$metadata" ] || die "no owned server metadata exists for that review"
  mapfile -t fields < "$metadata" || die "owned server metadata is unreadable"
  [ "${#fields[@]}" -eq 5 ] || die "owned server metadata is malformed"
  pid=${fields[0]}
  port=${fields[1]}
  stop_token=${fields[2]}
  hash_prefix=${fields[3]}
  expected_hash=${fields[4]}
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die "owned server metadata is malformed"
  [[ "$port" =~ ^[1-9][0-9]*$ ]] || die "owned server metadata is malformed"
  [[ "$stop_token" =~ ^[0-9a-f]{64}$ ]] || die "owned server metadata is malformed"
  [[ "$hash_prefix" =~ ^[0-9a-f]{16}$ ]] || die "owned server metadata is malformed"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || die "owned server metadata is malformed"
  [ "$port" = "$url_port" ] || die "the stop target does not match owned server metadata"
  [ "$hash_prefix" = "$url_prefix" ] || die "the stop target does not match owned artifact metadata"

  if ! kill -0 "$pid" 2>/dev/null; then
    rm -rf -- "$dir"
    printf 'stopped\n'
    return 0
  fi

  stop_status="$dir/stop.status"
  if curl --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
      --request POST --output "$dir/stop.body" --write-out '%{http_code}' \
      "http://127.0.0.1:$port/__firstmate_stop/$stop_token" \
      > "$stop_status" 2> "$dir/stop.stderr"; then
    stop_rc=0
  else
    stop_rc=$?
  fi
  [ "$stop_rc" -eq 0 ] || die "the owned server did not accept its stop request"
  [ "$(cat "$stop_status")" = 200 ] || die "the owned server rejected its stop request"

  for ((i = 0; i < 100; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -rf -- "$dir"
      printf 'stopped\n'
      return 0
    fi
    sleep 0.05
  done
  die "the owned server did not stop within the lifecycle deadline"
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  show_help
  exit 0
fi

if [ "${1:-}" = --stop ]; then
  [ "$#" -eq 2 ] || die "--stop requires exactly one verified review URL"
  stop_review "$2"
  exit 0
fi

requested_port=0
html_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      [ "$#" -ge 2 ] || die "--port requires a value"
      requested_port=$2
      shift 2
      ;;
    --)
      shift
      [ "$#" -eq 1 ] || die "exactly one HTML file is required"
      html_file=$1
      shift
      ;;
    -*) die "unknown option" ;;
    *)
      [ -z "$html_file" ] || die "exactly one HTML file is required"
      html_file=$1
      shift
      ;;
  esac
done

[ -n "$html_file" ] || die "an HTML file is required"
[ -f "$html_file" ] && [ -r "$html_file" ] || die "the HTML input must be a readable regular file"
[[ "$requested_port" =~ ^[0-9]+$ ]] || die "the requested port must be an integer from 0 to 65535"
[ "$requested_port" -le 65535 ] || die "the requested port must be an integer from 0 to 65535"
command_exists node || die "node is required"
command_exists curl || die "curl is required"
command_exists sha256sum || die "sha256sum is required"

runtime=$(detect_runtime) || die "runtime classification is ambiguous"
review_root=$(state_root)
mkdir -p "$review_root" || die "cannot create private review state"
chmod 700 "$review_root" || die "cannot secure private review state"
umask 077

for ((i = 0; i < 10; i++)); do
  delivery_token=$(random_hex 16) || die "cannot generate artifact identity"
  delivery_dir="$review_root/$delivery_token"
  if mkdir "$delivery_dir" 2>/dev/null; then
    break
  fi
  delivery_dir=''
done
[ -n "${delivery_dir:-}" ] || die "cannot allocate private review state"
owned_dir=$delivery_dir

artifact="$delivery_dir/artifact.html"
cp -- "$html_file" "$artifact" || die "cannot finalize the HTML artifact"
marker="fm-html-review:$delivery_token"
printf '\n<!-- %s -->\n' "$marker" >> "$artifact" || die "cannot mark the finalized HTML artifact"
chmod 400 "$artifact" || die "cannot make the finalized HTML artifact read-only"
expected_hash=$(sha256sum "$artifact" | awk '{print $1}') || die "cannot hash the finalized HTML artifact"
[[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || die "cannot hash the finalized HTML artifact"
hash_prefix=${expected_hash:0:16}
stop_token=$(random_hex 32) || die "cannot generate server lifecycle identity"
SERVER_HELPER="$delivery_dir/server.mjs"
RESULT_HELPER="$delivery_dir/result.mjs"
WINDOWS_HELPER="$delivery_dir/verify.ps1"
write_server_helper "$SERVER_HELPER" || die "cannot prepare the private loopback server"
write_result_helper "$RESULT_HELPER" || die "cannot prepare the private verifier parser"
write_windows_helper "$WINDOWS_HELPER" || die "cannot prepare the private Windows verifier"

powershell_bin=''
windows_script=''
if [ "$runtime" = wsl ]; then
  command_exists timeout || die "WSL host verification requires GNU timeout"
  command_exists wslpath || die "WSL host verification requires wslpath"
  if command_exists powershell.exe; then
    powershell_bin=$(command -v powershell.exe)
  elif command_exists pwsh.exe; then
    powershell_bin=$(command -v pwsh.exe)
  else
    die "WSL host verification requires Windows PowerShell"
  fi
  if timeout --foreground -k 2s 10s "$powershell_bin" -NoLogo -NoProfile -NonInteractive \
      -Command '[Environment]::OSVersion.Platform.ToString()' \
      > "$delivery_dir/windows-capability.out" 2> "$delivery_dir/windows-capability.err"; then
    capability_rc=0
  else
    capability_rc=$?
  fi
  [ "$capability_rc" -eq 0 ] || die "Windows PowerShell capability verification failed"
  capability=$(tr -d '\r\n' < "$delivery_dir/windows-capability.out")
  [ "$capability" = Win32NT ] || die "Windows PowerShell runtime verification was ambiguous"
  windows_script=$(wslpath -w "$WINDOWS_HELPER" 2> "$delivery_dir/wslpath.err") || die "cannot translate the Windows verifier path"
  [ -n "$windows_script" ] || die "cannot translate the Windows verifier path"
fi

attempts=1
if [ "$runtime" = wsl ] && [ "$requested_port" -eq 0 ]; then
  attempts=3
fi
last_failure='verification failed'
verified_url=''

for ((attempt = 1; attempt <= attempts; attempt++)); do
  ready_file="$delivery_dir/ready"
  server_log="$delivery_dir/server.log"
  rm -f -- "$ready_file" "$server_log"
  node "$SERVER_HELPER" "$artifact" "$delivery_token" "$expected_hash" "$marker" \
    "$stop_token" "$requested_port" "$ready_file" > "$server_log" 2>&1 &
  server_pid=$!
  owned_pid=$server_pid

  ready=false
  for ((i = 0; i < 100; i++)); do
    if [ -s "$ready_file" ]; then
      ready=true
      break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  if [ "$ready" != true ]; then
    cleanup_owned_launch
    owned_dir=$delivery_dir
    die "the loopback listener could not start"
  fi

  port=$(tr -d '\r\n' < "$ready_file")
  [[ "$port" =~ ^[1-9][0-9]*$ ]] || die "the loopback listener returned ambiguous readiness"
  [ "$port" -le 65535 ] || die "the loopback listener returned ambiguous readiness"
  candidate="http://127.0.0.1:$port/__firstmate_artifact/$delivery_token?v=$hash_prefix"

  local_result="$delivery_dir/local.result"
  local_body="$delivery_dir/local.body"
  if curl --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
      --output "$local_body" --write-out '%{http_code}\t%{content_type}' "$candidate" \
      > "$local_result" 2> "$delivery_dir/local.stderr"; then
    local_rc=0
  else
    local_rc=$?
  fi
  if [ "$local_rc" -ne 0 ]; then
    last_failure='local verification transport failed'
    break
  fi
  IFS=$'\t' read -r local_status local_type < "$local_result" || true
  if [ "$local_status" != 200 ]; then
    last_failure='local verification did not return HTTP 200'
    break
  fi
  case "$local_type" in
    text/html|text/html\;*) ;;
    *) last_failure='local verification did not return text/html'; break ;;
  esac
  local_hash=$(sha256sum "$local_body" | awk '{print $1}') || {
    last_failure='local verification could not hash the response'
    break
  }
  if [ "$local_hash" != "$expected_hash" ] || ! cmp -s "$artifact" "$local_body"; then
    last_failure='local artifact identity mismatch'
    break
  fi
  if ! grep -Fq -- "$marker" "$local_body"; then
    last_failure='local artifact marker mismatch'
    break
  fi

  if [ "$runtime" = linux ]; then
    verified_url=$candidate
    break
  fi

  windows_out="$delivery_dir/windows.out"
  if timeout --foreground -k 2s 10s "$powershell_bin" -NoLogo -NoProfile -NonInteractive \
      -ExecutionPolicy Bypass -File "$windows_script" \
      -Url "$candidate" -ExpectedSha256 "$expected_hash" -ExpectedMarker "$marker" \
      -TimeoutSeconds 5 > "$windows_out" 2> "$delivery_dir/windows.stderr"; then
    windows_rc=0
  else
    windows_rc=$?
  fi
  if [ "$windows_rc" -eq 0 ] || [ "$windows_rc" -eq 20 ]; then
    if windows_class=$(node "$RESULT_HELPER" "$windows_out" "$candidate" "$expected_hash" \
        "$marker" "$windows_rc" 2> "$delivery_dir/windows-result.stderr"); then
      result_rc=0
    else
      result_rc=$?
    fi
    if [ "$result_rc" -ne 0 ]; then
      last_failure='Windows-side verification result was ambiguous'
      break
    fi
    case "$windows_class" in
      ok)
        verified_url=$candidate
        break
        ;;
      retry)
        last_failure='Windows-side verification reached the wrong listener'
        stop_owned_pid
        continue
        ;;
      *)
        last_failure='Windows-side verification result was ambiguous'
        break
        ;;
    esac
  else
    last_failure='Windows-side verification transport failed'
    break
  fi
done

if [ -z "$verified_url" ]; then
  die "$last_failure"
fi
kill -0 "$server_pid" 2>/dev/null || die "the verified loopback listener exited before handoff"

metadata_tmp="$delivery_dir/state.tmp"
printf '%s\n%s\n%s\n%s\n%s\n' \
  "$server_pid" "$port" "$stop_token" "$hash_prefix" "$expected_hash" > "$metadata_tmp" \
  || die "cannot record owned server lifecycle metadata"
chmod 600 "$metadata_tmp" || die "cannot secure owned server lifecycle metadata"
mv "$metadata_tmp" "$delivery_dir/state" || die "cannot publish owned server lifecycle metadata"

owned_pid=''
owned_dir=''
printf '%s\n' "$verified_url"
