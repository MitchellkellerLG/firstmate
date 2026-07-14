# Watcher PID identity: WSL2 clock-drift false-negative (issue #433)

Evidence record for the fix that switched process identity fingerprinting from `ps -o lstart=` to `/proc/<pid>/stat` field 22 (`starttime`).
This is an incident/verification doc: it records the observed failure, the root cause, and the empirical checks behind the fix, not a mechanism narrative.
The owner of the identity contract itself is `bin/fm-wake-lib.sh` (`fm_pid_identity`, `fm_pid_starttime`, `fm_pid_identity_legacy`, `fm_pid_identity_matches`).

## Symptom (observed 2026-07-10 and 2026-07-14, WSL2)

- Host: `Linux 6.6.87.2-microsoft-standard-WSL2`.
- A single long-lived `bin/fm-watch.sh` process (pid and parentage unchanged, confirmed alive via direct `ps`/`pgrep` many times) repeatedly tripped `bin/fm-watch-arm.sh` "FAILED - no live watcher with a fresh beacon" more than a dozen times in a row.
- `bin/fm-turnend-guard.sh` raised false "TURN WOULD END BLIND" alarms against the same live, freshly-beating watcher.
- The turn-end guard's beacon-age read printed a negative delta ("last beat: -1s ago", "last beat: -2s ago") at least twice, direct evidence that the wall-clock read itself was unstable, not merely the identity comparison.

## Root cause

`fm_pid_identity` fingerprinted a process with `ps -o lstart=`, a wall-clock rendering of the process start time.
`ps` recomputes `lstart` from the *current* clock on every call.
On WSL2 the system clock drifts while the Windows host sleeps or is under load and is corrected afterward, so the rendered start time of the *same live process* changes between two reads:

- Identity recorded at lock acquisition: `Fri Jul 10 11:54:03 2026 bash $FM_ROOT/bin/fm-watch.sh`
- Live readouts of the same pid minutes later: `11:54:29`, then `11:54:36` (drift growing).

`fm_watcher_lock_matches_pid` read that mismatch as a recycled pid and declared a healthy watcher dead.

## Fix

Fingerprint with `/proc/<pid>/stat` field 22 (`starttime`, in clock ticks since boot) plus the command line from `/proc/<pid>/cmdline`.
`starttime` is measured against the monotonic boot clock, so it does not re-render across a wall-clock correction.
The `ps -o lstart=` form is retained as `fm_pid_identity_legacy` for two purposes: the portable fallback on hosts without procfs (macOS), and a mid-flight compat read so a lock record written in the old format before this landed is not treated as a dead watcher exactly once (see `fm_pid_identity_matches`).

## Empirical evidence

Commands run 2026-07-14 on the affected WSL2 host (`Linux 6.6.87.2-microsoft-standard-WSL2`), `CLK_TCK=100`:

```
$ read_starttime() { local s rest; s=$(cat /proc/$1/stat); rest=${s##*) }; set -- $rest; echo "${20}"; }
$ read_starttime 1        # init, started ~0.94s after boot
94
$ LC_ALL=C ps -p 1 -o lstart=
Mon Jul 13 13:01:26 2026
```

- `starttime` is a small integer of ticks since boot (pid 1 = `94` ticks ≈ 0.94s), a boot-relative quantity, not a wall-clock timestamp. The Linux `proc(5)` man page documents field 22 as "The time the process started after system boot ... in clock ticks", i.e. relative to boot, so it is unaffected by `date`/NTP/host-sleep wall-clock adjustments. A live process keeps the same `starttime` for its entire lifetime; a recycled pid necessarily gets a strictly later `starttime`.
- `ps -o lstart=` is a wall-clock rendering of that same boot-relative value: `ps` adds the current wall clock's offset at read time, which is exactly why a clock correction changes the rendered string for an unchanged process.

Deterministic regression test (`tests/fm-watcher-lock.test.sh`, `test_pid_identity_immune_to_clock_drift`):
mock `ps` so its `lstart` output drifts by a second across successive reads of the same live pid, then confirm the legacy (lstart) identity false-negatives across the two reads while the procfs-`starttime` identity stays byte-identical.
`test_pid_identity_matches_and_compat` covers the shared matcher: same-pid self-match, the legacy-format mid-flight compat path, and rejection of a foreign or empty stored identity.

Both tests, the full `tests/*.test.sh` suite, and `bin/fm-lint.sh` pass.
