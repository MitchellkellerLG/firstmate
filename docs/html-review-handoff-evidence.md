# HTML review handoff evidence

Date: 2026-07-15.

This record preserves the empirical evidence gathered by `artifact-owner-q3`, `artifact-host-v8`, and `artifact-tests-m4` for the broken HTML review handoff.

The operational contract is not duplicated here and is owned by the header and `--help` output of `bin/fm-html-review.sh`.

## Inspected baseline and versions

The ownership scout inspected detached commit `bf8caa6e422dc73275313379cd08448289f9ddec`.

```text
$ command -v lavish-axi
/mnt/c/Users/mitch/AppData/Roaming/npm/lavish-axi

$ lavish-axi --version
0.1.35

$ chrome-devtools-axi --version
0.1.26

$ node --version
v24.13.1

$ python3 --version
Python 3.14.3

$ sha256sum --version | sed -n '1p'
sha256sum (GNU coreutils) 9.4

$ uname -srm
Linux 6.6.87.2-microsoft-standard-WSL2 x86_64

$ sed -n '1,12p' /etc/os-release
PRETTY_NAME="Ubuntu 24.04.3 LTS"
VERSION_ID="24.04"

$ powershell.exe -NoLogo -NoProfile -NonInteractive -Command 'Write-Output ("PSVersion=" + $PSVersionTable.PSVersion.ToString())'
PSVersion=5.1.26100.8655
PSEdition=Desktop
CLRVersion=4.0.30319.42000
Is64Bit=True

$ powershell.exe -NoLogo -NoProfile -NonInteractive -Command '[Environment]::OSVersion.VersionString; [Environment]::MachineName'
Microsoft Windows NT 10.0.26200.0
THE-GOAT
```

The host scout also recorded WSL `2.6.3.0`, kernel `6.6.87.2-1`, and Windows `10.0.26200.8655` from `wsl.exe --version`.

## Broken handoff

The original agent opened the stateful review with this command.

```text
$ lavish-axi .lavish/portfolio-topology-review.html
session:
  file: /home/mitch/.treehouse/firstmate-397af3/3/firstmate/.lavish/portfolio-topology-review.html
  url: "http://127.0.0.1:4387/session/237ea873a5e1659e"
  status: opened
```

The captain received `session not found` twice for that URL.

The portable export was finalized with this command.

```text
$ lavish-axi end .lavish/portfolio-topology-review.html
$ lavish-axi export .lavish/portfolio-topology-review.html --out .lavish/portfolio-topology-review-portable.html
$ sha256sum portfolio-topology-review-portable.html
8201078f4ba06915beb0772463ced0128c22a506ccbb69978c2ff51216e477f7  portfolio-topology-review-portable.html
$ wc -c < portfolio-topology-review-portable.html
20530
```

The Linux-only fallback used this server command.

```text
$ python3 -m http.server 8765 --bind 0.0.0.0 --directory .lavish
```

Its Linux-local check returned this output.

```text
200 text/html 20530
```

The unverified `localhost` handoff reached another Python listener from Windows and returned this output.

```text
Error response

Error code: 404

Message: File not found.

Error code explanation: 404 - Nothing matches the given URI.
```

The intended WSL server log contained only the earlier agent-local requests and no request corresponding to the captain's later failure.

```text
127.0.0.1 ... "GET /portfolio-topology-review-portable.html HTTP/1.1" 200
127.0.0.1 ... "GET /portfolio-topology-review-portable.html HTTP/1.1" 200
```

The handoff succeeded only after the exact WSL-address URL was requested from Windows with this command.

```text
$ powershell.exe -NoProfile -Command "(Invoke-WebRequest -UseBasicParsing 'http://172.25.75.24:8765/portfolio-topology-review-portable.html').StatusCode"
200
```

## Cross-namespace identity probes

The host scout used a 198-byte HTML artifact containing marker `fm-artifact-host-v8::7f29c2b9e16a`.

Its SHA-256 was `19f77eda0ff24972268aa1cb8515c967d5b3da03065357405f2bbef1dd2646fb`.

With no competing Windows listener, the exact Windows-host request returned this output and PowerShell exited zero.

```json
{"ok":true,"requested_url":"http://127.0.0.1:36889/artifact.html?fm_probe=7f29c2b9e16a","effective_url":"http://127.0.0.1:36889/artifact.html?fm_probe=7f29c2b9e16a","status":200,"content_type":"text/html","bytes":198,"sha256":"19f77eda0ff24972268aa1cb8515c967d5b3da03065357405f2bbef1dd2646fb","identity_ok":true,"url_ok":true}
```

With a wrong Windows listener returning HTTP 200, Linux still returned the intended artifact and Windows returned this output.

```text
$ curl --silent --show-error --noproxy '*' --output - 'http://127.0.0.1:36919/artifact.html?fm_probe=7f29c2b9e16a' | sha256sum
19f77eda0ff24972268aa1cb8515c967d5b3da03065357405f2bbef1dd2646fb  -

{"ok":false,"requested_url":"http://127.0.0.1:36919/artifact.html?fm_probe=7f29c2b9e16a","effective_url":"http://127.0.0.1:36919/artifact.html?fm_probe=7f29c2b9e16a","status":200,"content_type":"text/html","bytes":22,"sha256":"0b16995a7e6f79183f2d37563b731d4017c00267d5beb28f5d5da2795d3a9b32","identity_ok":false,"url_ok":true}
powershell_exit=20
```

With the Windows listener returning HTTP 404, Linux still returned HTTP 200 and Windows returned this output.

```text
--- 404 split: Linux namespace status ---
status=200
--- 404 split: Windows host namespace ---
{"ok":false,"requested_url":"http://127.0.0.1:36919/artifact.html?fm_probe=7f29c2b9e16a","effective_url":"http://127.0.0.1:36919/artifact.html?fm_probe=7f29c2b9e16a","status":404,"content_type":"text/html","bytes":16,"sha256":"363adb0b1a2f2d8068af6c82981904766f80c298776ff5b305835ee60b11ee44","identity_ok":false,"url_ok":true}
powershell_exit=20
```

The unavailable-endpoint probe used a two-second HTTP timeout and returned this output after approximately 2.7 seconds including process startup.

```json
{"ok":false,"requested_url":"http://127.0.0.1:1/unavailable?fm_probe=7f29c2b9e16a","error_type":"System.Management.Automation.MethodInvocationException","error":"Exception calling \"GetResult\" with \"0\" argument(s): \"A task was canceled.\""}
```

PowerShell exited 21 for the unavailable endpoint.

## Lavish-state boundary

The regression scout isolated Lavish state, ended a session through its user endpoint, and then served the exported artifact independently.

The exact observed output follows.

```text
health={"ok":true,"app":"lavish-axi","version":"0.1.35"}
lavish_open status: opened
user_end={"status":"ended"}
ended_state=ended:user
lavish_plain_reopen status: user-ended
sessionless_after_status=200
expected_export_sha256=771d0135bd7536d1e8a39fbaae0bd3e349560fe13a28fa438d637057e0f98ff9
sessionless_after_sha256=771d0135bd7536d1e8a39fbaae0bd3e349560fe13a28fa438d637057e0f98ff9
```

The deterministic implementation coverage lives in `tests/fm-html-review.test.sh` rather than in this evidence record.
