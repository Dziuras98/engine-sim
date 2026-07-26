# nEXTcAR recorder compatibility port

This directory contains the source-built native recorder used by the offline
nEXTcAR engine-audio toolchain.

## Current stage

```text
native source baseline:
31d09faf7b249320a8bf45e2b9bd7dfd8b7ff704

open-source engine-sim code baseline:
85f7c3b959a908ed5232ede4f1a4ac7eafe6b630

piranha source commit:
432f0b122bb1663b686c553c7e7269300afac3bc

recorder ABI:
2000

reference ABI:
1010

compatibility target:
0.1.14a-reference-pending
```

This stage replaces the historical, opaque precompiled recorder boundary with a
repeatable source build and a black-box comparison against the recorder DLL
pinned by `ESRecorder-nextcar`.

## Boundary

The recorder is an offline Windows x64 DLL. It is consumed by the separate
ESRecorder headless CLI and must never be linked into the Unreal runtime.

The exported C ABI preserves the function names used by ESRecorder while making
the wire layout explicit:

- four-byte Boolean/result fields compatible with `.NET UnmanagedType.Bool`;
- fixed-width integer fields;
- fixed enum values;
- compile-time size and offset assertions;
- runtime export/version/source-identity tests;
- version, source-revision and compatibility-target queries.

The released DLL is required to contain Boost.Filesystem statically. CI rejects
an external `boost_*.dll` dependency and records the complete export table and
SHA-256 identities of both the pinned reference DLL and source-built DLL.

## Source changes required by recording

The port keeps changes to the engine-sim source boundary small and reviewable:

- the scripting compiler also searches packaged `es/es/` modules;
- engine scripts may provide the existing recorder `convolution` parameter;
- the ignition module exposes a rev-limit override for fixed-RPM capture;
- recorder compilation is serialized because the existing script compiler owns
  static output state;
- static compiler outputs are reset before each execution;
- recording state and progress remain atomically observable while a native
  capture call owns the instance lock;
- each native instance owns and releases its simulator, engine, vehicle and
  transmission explicitly;
- failed or timed-out recordings remove partial WAV output;
- RPM and RIFF-size calculations reject integer overflow before recording;
- the headless impulse-response loader accepts validated mono PCM16 WAV without
  pulling the SDL/delta-studio UI stack into the DLL.

## Black-box parity contract

CI builds isolated managed hosts for:

```text
reference host: pinned ABI 1010 esrecord-lib.dll
source host:    source-built ABI 2000 esrecord-lib.dll
```

Both hosts receive byte-identical engine scripts. The historical script search
order loads `../../es/objects/objects.mr` before the packaged copy, so CI applies
the same ephemeral `convolution: 1.0` wrapper change to the shared checkout used
by both hosts. The EJ25 engine script itself remains unchanged.

The operating-point matrix is:

```text
RPM:       2000, 4000, 6000
throttle:  25%, 50%, 100%
frequency: 10000 Hz
length:    1 second
warmup:    60 updates
```

Engine identity, ABI identity, mono PCM16 format and frame count are exact
requirements. Power, torque and audio-distribution features use explicit
bounded tolerances:

```text
power:                0.25 hp or 0.25%
torque:               0.5 Nm or 0.25%
RMS level:            0.10 dB
DC mean:              0.5% of PCM full scale
zero-crossing rate:   0.001 absolute
crest factor:         2% relative
clipped samples:      256 samples
absolute peak:        512 PCM units
p50/p90/p95/p99 abs:  256 PCM units or 3% relative
```

Decoded PCM hashes, direct sample correlation and execution time remain in the
evidence artifact as diagnostics. They are not blocking requirements because
the frozen synthesizer calls global `rand()` from its asynchronous audio thread;
the exact random-call phase can vary with thread scheduling even when the
resulting telemetry and signal distribution remain equivalent.

A sequential multi-point batch is also recorded and published as diagnostic
evidence. The blocking comparison uses a fresh CLI process for every operating
point so cross-sample instance state is not conflated with native ABI parity.

## Frozen dependency compatibility

The pinned piranha source predates current Boost and calls the removed
`boost::filesystem::path::is_complete()` method. The standalone recorder build
mechanically replaces exactly one `path.cpp` translation unit with
`compat/piranha_path_boost_compat.cpp`. That file is identical in behavior to the
pinned source except that `Path::isAbsolute()` calls `is_absolute()`.

The piranha submodule remains immutable. CMake fails if the expected source
cannot be identified exactly once.

The frozen engine-sim `units.h` and `constants.h` define externally linked
`constexpr` values in headers. Recorder implementation files are therefore
compiled through one explicit translation unit instead of weakening the linker
with duplicate-symbol flags.

## Build

Requirements:

- Windows x64;
- Visual Studio C++ toolchain;
- CMake;
- vcpkg `boost-filesystem:x64-windows-static-md`;
- Flex and Bison compatible with the piranha scripting submodule;
- recursive Git submodules.

```powershell
$vcpkgRoot = $env:VCPKG_INSTALLATION_ROOT
& "$vcpkgRoot/vcpkg.exe" install boost-filesystem:x64-windows-static-md

cmake -S nextcar-recorder -B build-nextcar-recorder -A x64 `
  "-DCMAKE_TOOLCHAIN_FILE=$vcpkgRoot/scripts/buildsystems/vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows-static-md `
  -DFLEX_EXECUTABLE=C:/path/to/win_flex.exe `
  -DBISON_EXECUTABLE=C:/path/to/win_bison.exe

cmake --build build-nextcar-recorder --config Release `
  --target esrecord-lib `
           nextcar-recorder-abi-layout-test `
           nextcar-recorder-abi-runtime-test

ctest --test-dir build-nextcar-recorder -C Release `
  --output-on-failure -R nextcar-recorder-abi
```

## Acceptance sequence

The source DLL must not replace the binary pinned by ESRecorder until all of the
following are complete:

1. reproducible native build, layout test and native runtime export test;
2. managed loader validation against ABI 1010 and ABI 2000;
3. real `.mr` compile and short WAV recording fixture;
4. exact WAV structure and bounded telemetry/audio-feature checks;
5. nine-point black-box comparison with the pinned 0.1.14a reference DLL;
6. reviewed ESRecorder fork update followed by a reviewed Nextcar gitlink update.
