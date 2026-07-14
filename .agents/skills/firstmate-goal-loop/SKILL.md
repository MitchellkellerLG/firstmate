---
name: firstmate-goal-loop
description: >-
  Agent-only reference for firstmate's optional goal-loop completion bar on ship tasks.
  Use before dispatching a ship task with a stronger done-condition bar (large, ambiguous, or first-time-trust work), and when a goal-loop task reports done, to run the independent checker before the normal no-mistakes/PR flow proceeds.
  Covers when to reach for --goal-loop, the fresh-checker spawn, the diff scoring against the crewmate's done-condition block, the bounded fix loop, and escalation.
user-invocable: false
metadata:
  internal: true
---

# firstmate-goal-loop

Goal-loop is an opt-in stronger completion bar for a single ship task, ported into firstmate's idiom from the captain's `write-goal-prompt` eval-loop shape.
It is NOT a change to the default brief.
Routine ship work - a bug fix, a small feature, the bulk of dispatch volume - stays as lightweight as it is today, dispatched with a plain ship brief.
Reach for goal-loop only when the task is large, ambiguous, or first-time-trust work where "the pipeline passed" is not enough assurance on its own.

Two parts make it up, and each has exactly one owner: the brief-authoring mechanics live in `bin/fm-brief.sh`'s `--goal-loop` flag and its header; the firstmate-side checker lifecycle lives here.

## Dispatch: authoring the goal-loop brief

Scaffold the ship brief with `bin/fm-brief.sh <id> <repo> --goal-loop` (it is ship-only; the script rejects it for scout and secondmate briefs), then fill `{TASK}` as usual.
The flag adds a "Done condition" section that has the crewmate write a done-condition block to `data/<id>/done-condition.md` before it implements anything, and gates the definition of done on the independent check below.
The block names a reward signal, a mechanical gate, a qualitative gate, and a done threshold; the exact wording the crewmate follows is owned by the scaffold, not restated here.
Everything else about the task - spawn, supervise, delivery mode - is the ordinary ship lifecycle (`AGENTS.md` sections 7-8).

## Checker: when the goal-loop crewmate reports `done`

Do NOT proceed straight to no-mistakes validation / the PR flow.
Run one independent verification round first:

1. Confirm the crewmate actually authored `data/<id>/done-condition.md`.
   If it is missing, the goal-loop contract was not met: steer the crewmate to write it before you accept `done` (it is a `needs-decision`-style resume, not a checker round).
2. Capture the diff to be reviewed with `bin/fm-review-diff.sh <id>` (it compares against the authoritative base, and includes no-mistakes fix rounds when a PR head is recorded), and save it to a file firstmate owns, e.g. `bin/fm-review-diff.sh <id> > data/<id>/goal-loop-diff.patch`.
   The checker spawns as a fresh scout in its own isolated worktree - a different pooled clone that will not have the original `fm/<id>` branch present - so it cannot recompute the diff itself; firstmate hands it the captured file.
3. Spawn a SEPARATE crewmate as a scout on the same repo: `bin/fm-brief.sh <checker-id> <repo> --scout` then `bin/fm-spawn.sh <checker-id> projects/<repo> --scout`.
   This checker is fresh, with no memory of how the work was produced.
   Give its `{TASK}` the checker contract below, with the real absolute paths to the captured diff (`data/<id>/goal-loop-diff.patch`) and the done-condition block (`data/<id>/done-condition.md`) so the checker reads both directly rather than trying to derive the diff from a branch it does not have.
4. When the checker reports `done`, read its report at `data/<checker-id>/report.md` for the verdict, then tear the checker down (`bin/fm-teardown.sh <checker-id>` - a scout worktree is scratch once the report exists).

Route on the verdict:

- **Pass** - the goal-loop gate is cleared. Proceed with the original task's normal delivery-mode flow (no-mistakes validation / direct-PR / local-only) exactly as any ship task.
- **Fail** - resume the ORIGINAL crewmate as a `needs-decision`-style steer carrying the checker's specific feedback and the failing gate, and have it revise. This is one round.

## Bounded loop and escalation

The default cycle cap is 3 rounds (matching the eval-loop's usual `max_cycles`), counted per original task.
Each round is: original crewmate revises -> fresh checker scores the new diff.
Reuse the same checker `{TASK}` contract each round, always with a fresh checker crewmate (never one that saw a prior round).
If the checker still fails after the third round, stop looping and escalate to the captain in outcome language: the work is not meeting its own done-condition, with the checker's latest feedback, for a decision (accept as-is, redirect, or abandon).
Do not silently keep spinning past the cap.

## The checker's `{TASK}` contract

Fill the checker scout brief's `{TASK}` with this, substituting the real ids/paths:

> You are an independent reviewer. Open your report by stating plainly that you did NOT write the code under review and have no knowledge of how it was produced.
> Read the done-condition block at `data/<id>/done-condition.md` and the branch diff at `data/<id>/goal-loop-diff.patch`, both handed to you by firstmate; do not try to recompute the diff from a branch, which is not present in your worktree.
> Score the diff against that block: run or reason about the mechanical gate, and judge the qualitative gate against what the diff actually does.
> Write `data/<checker-id>/report.md` with a single explicit verdict line - `VERDICT: PASS` or `VERDICT: FAIL` - the reward-signal and mechanical-gate results, and, on FAIL, the specific properties the diff is missing so the author can fix them.
> Do not fix the code yourself; you only score it.

The checker judges only against the crewmate's own done-condition block, not against a fresh opinion of what the task should have been - the block is the contract.

## Maintaining this file

Keep this for the goal-loop lifecycle only.
The brief-authoring mechanics belong to `bin/fm-brief.sh`; do not restate them here beyond the one-line pointer.
Prefer pointers to the authoritative script or `AGENTS.md` section over copied detail.
