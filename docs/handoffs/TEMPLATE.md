# NC-XXX handoff

## Metadata

- **Task:** NC-XXX — task name
- **Status:** `completed` / `blocked` / `partial`
- **Branch:** `agent/nc-XXX-short-description`
- **Base branch:** `master`
- **Base commit:** `<sha>`
- **Head commit:** `<sha>`
- **Date:** YYYY-MM-DD
- **Agent:** `<agent or session identifier>`

## Objective

State the assigned objective and the boundaries of the task.

## Summary of completed work

Describe the resulting repository state. Separate implemented work from investigation-only findings.

## Files changed

| Path | Change | Reason |
| --- | --- | --- |
| `path/to/file` | Added/updated/deleted | Why this change was necessary |

## Architecture decisions

List decisions made during the task and link any records stored in `docs/decisions/`. Write `None` when no architecture decision was required.

## Build and test status

Record exact commands and outcomes. Do not replace an unexecuted check with an assumption.

```text
<command>
<exit code and concise result>
```

- **Build:** passed / failed / not run
- **Tests:** passed / failed / not run
- **Reason for missing checks:** `<required when applicable>`

## Benchmarks

Link results in `docs/benchmarks/`, including hardware, build type, scenario, sample count, and measurement method. Write `Not applicable` when the task has no benchmark requirement.

## Known limitations and risks

Document unresolved technical debt, environmental constraints, compatibility risks, and any behavior that was intentionally left unchanged.

## Instructions for the next agent

1. Fetch the branch or accepted base commit.
2. Initialize all required submodules and dependencies.
3. Run the baseline commands listed above before changing code.
4. Review linked decisions and benchmark data.
5. Work only within the next task's scope.

Add task-specific startup steps, relevant files, and expected outputs below this list.

## Acceptance checklist

- [ ] Scope matches the assigned NC task.
- [ ] Required files and directories exist.
- [ ] Build status is recorded truthfully.
- [ ] Test status is recorded truthfully.
- [ ] No unrelated behavior changed.
- [ ] Next-agent instructions are executable and unambiguous.
