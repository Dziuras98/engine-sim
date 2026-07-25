# nEXTcAR recorder compatibility port

This directory contains the source-built native recorder used by the offline
nEXTcAR engine-audio toolchain.

## Current stage

```text
native source baseline:
31d09faf7b249320a8bf45e2b9bd7dfd8b7ff704

open-source engine-sim code baseline:
85f7c3b959a908ed5232ede4f1a4ac7eafe6b630

recorder ABI:
2000

compatibility target:
0.1.14a-reference-pending
```

This stage replaces the historical, opaque precompiled recorder boundary with a
repeatable source build. It does **not** yet claim acoustic or telemetry parity
with the Community Edition 0.1.14a executable.

## Boundary

The recorder is an offline Windows x64 DLL. It is consumed by the separate
ESRecorder headless CLI and must never be linked into the Unreal runtime.

The exported C ABI preserves the function names used by ESRecorder while making
the wire layout explicit:

- four-byte Boolean/result fields compatible with `.NET UnmanagedType.Bool`;
- fixed-width integer fields;
- fixed enum values;
- compile-time size and offset assertions;
- version, source-revision and compatibility-target queries.

## Source changes required by recording

The port keeps changes to the engine-sim source boundary small and reviewable:

- the scripting compiler also searches packaged `es/es/` modules;
- engine scripts may provide the existing recorder `convolution` parameter;
- the ignition module exposes a rev-limit override for fixed-RPM capture;
- recorder compilation is serialized because the existing script compiler owns
  static output state;
- each native instance owns and releases its simulator, engine, vehicle and
  transmission explicitly.

## Build

Requirements:

- Windows x64;
- Visual Studio 2022 C++ toolchain;
- CMake;
- Flex and Bison compatible with the piranha scripting submodule;
- recursive Git submodules.

```powershell
cmake -S nextcar-recorder -B build-nextcar-recorder -A x64 `
  -DFLEX_EXECUTABLE=C:/path/to/win_flex.exe `
  -DBISON_EXECUTABLE=C:/path/to/win_bison.exe

cmake --build build-nextcar-recorder --config Release `
  --target esrecord-lib nextcar-recorder-abi-test

ctest --test-dir build-nextcar-recorder -C Release `
  --output-on-failure -R nextcar-recorder-abi
```

## Acceptance sequence

The source DLL must not replace the binary pinned by ESRecorder until all of the
following are complete:

1. reproducible native build and ABI test;
2. managed loader validation against ABI 2000;
3. real `.mr` compile and short WAV recording fixture;
4. deterministic WAV/header/telemetry checks;
5. fixture-corpus comparison with the 0.1.14a reference executable;
6. reviewed ESRecorder fork update followed by a reviewed Nextcar gitlink update.
