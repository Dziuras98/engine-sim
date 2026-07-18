# nEXTcAR engine-sim integration plan

## Purpose

This document defines the ordered work packages for integrating the current `engine-sim` codebase with Unreal Engine 5. Tasks are intentionally sequential. Each agent must start from the accepted result of the preceding task, keep behavioral changes within its assigned scope, and leave a handoff in `docs/handoffs/NC-XXX.md`.

## Working rules

- Use a dedicated branch named `agent/nc-XXX-short-description`.
- Do not combine adjacent work packages without an explicit scope change.
- Record architecture choices in `docs/decisions/`.
- Store repeatable performance procedures and results in `docs/benchmarks/`.
- Preserve a reproducible build and test command in every handoff.
- Do not modify engine behavior unless the active task explicitly requires it.

## Ordered work packages

| ID | Work package | Primary outcome | Depends on |
| --- | --- | --- | --- |
| NC-001 | Repeatable Release build | A documented, repeatable Windows Release build from a clean clone with all submodules and dependencies resolved. | NC-000 |
| NC-002 | Headless runner without SDL/GUI | A command-line runner that can load an engine configuration and advance the simulation without the desktop application or rendering/UI path. | NC-001 |
| NC-003 | Export audio to WAV | Deterministic offline PCM/WAV export from a scripted headless run, with sample rate, channel count, duration, and input scenario recorded. | NC-002 |
| NC-004 | `NextCarEngineAdapter` API | A narrow C++ facade for lifecycle, engine loading, simulation stepping, control inputs, PCM retrieval, and telemetry access. | NC-003 |
| NC-005 | CPU benchmark for R4/V8/V12 | A repeatable benchmark suite and baseline results for representative inline-four, V8, and V12 configurations. | NC-004 |
| NC-006 | C++ Unreal Engine plugin | An Unreal Engine 5 C++ plugin/module that builds the adapter inside an Unreal project without adding gameplay behavior yet. | NC-005 |
| NC-007 | Lock-free PCM buffer | A bounded single-producer/single-consumer PCM transport between the simulation producer and Unreal audio consumer, with overflow/underflow behavior defined. | NC-006 |
| NC-008 | RPM/throttle/load control | Runtime control of engine state from game inputs and vehicle/drivetrain load, with stable input ranges and update rates. | NC-007 |
| NC-009 | Telemetry and underrun detection | Runtime telemetry for RPM, load, simulation cost, buffer fill, overruns, underruns, and audio continuity. | NC-008 |
| NC-010 | Vehicle and test map | One controllable vehicle, one engine, one simple test map, gearbox controls, and procedural engine audio connected end to end. | NC-009 |
| NC-011 | License and attribution documentation | Audited license obligations and third-party notices for `engine-sim`, submodules, bundled libraries, assets, and Unreal integration artifacts. | NC-010 |
| NC-012 | Generator-versus-samples comparison recording | Standardized recordings and an evaluation report comparing procedural generation with a sample-based reference under matched driving scenarios. | NC-011 |

## Completion contract for every task

A task is complete only when:

1. its scoped acceptance criteria are met;
2. relevant build and tests have been run, or a concrete blocker is documented;
3. no unrelated behavioral changes are included;
4. decisions and benchmark data are stored in the designated directories;
5. `docs/handoffs/NC-XXX.md` contains exact commands, results, known limitations, and instructions for the next agent.
