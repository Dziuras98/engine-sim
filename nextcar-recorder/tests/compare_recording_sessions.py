#!/usr/bin/env python3
"""Compare complete legacy and source-built ESRecorder recording sessions."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from pathlib import Path, PureWindowsPath
from typing import Any

import compare_recordings as recording


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare two ESRecorder manifests and every referenced WAV."
    )
    parser.add_argument("--reference-directory", type=Path, required=True)
    parser.add_argument("--source-directory", type=Path, required=True)
    parser.add_argument("--expected-samples", type=int, required=True)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--text-output", type=Path, required=True)
    return parser.parse_args()


def manifest_path(directory: Path) -> Path:
    return directory / "recording-manifest.json"


def measurements(manifest: dict[str, Any], path: Path) -> list[dict[str, Any]]:
    value = manifest.get("measurements")
    if not isinstance(value, list):
        raise ValueError(f"{path}: measurements must be an array")
    if not all(isinstance(item, dict) for item in value):
        raise ValueError(f"{path}: every measurement must be an object")
    return value


def sample_key(measurement: dict[str, Any]) -> tuple[int, int, int, int, int, bool]:
    sample = measurement.get("sample")
    if not isinstance(sample, dict):
        raise ValueError("Measurement sample must be an object")
    return (
        int(sample["rpm"]),
        int(sample["throttle"]),
        int(sample["frequency"]),
        int(sample["length"]),
        int(sample["warmupCount"]),
        bool(sample["overrideRevLimit"]),
    )


def index_measurements(
    items: list[dict[str, Any]],
) -> dict[tuple[int, int, int, int, int, bool], dict[str, Any]]:
    indexed: dict[tuple[int, int, int, int, int, bool], dict[str, Any]] = {}
    for item in items:
        key = sample_key(item)
        if key in indexed:
            raise ValueError(f"Duplicate measurement key: {key}")
        indexed[key] = item
    return indexed


def output_filename(measurement: dict[str, Any]) -> str:
    sample = measurement["sample"]
    raw = str(sample["outputPath"])
    return PureWindowsPath(raw).name


def main() -> int:
    args = parse_args()
    reference_manifest_path = manifest_path(args.reference_directory)
    source_manifest_path = manifest_path(args.source_directory)
    reference_manifest = recording.load_manifest(reference_manifest_path)
    source_manifest = recording.load_manifest(source_manifest_path)

    reference_engine = reference_manifest.get("engine")
    source_engine = source_manifest.get("engine")
    if not isinstance(reference_engine, dict) or not isinstance(source_engine, dict):
        raise ValueError("Manifest engine metadata must be objects")

    reference_items = measurements(reference_manifest, reference_manifest_path)
    source_items = measurements(source_manifest, source_manifest_path)
    if len(reference_items) != args.expected_samples:
        raise ValueError(
            f"Reference manifest contains {len(reference_items)} measurements; "
            f"expected {args.expected_samples}."
        )
    if len(source_items) != args.expected_samples:
        raise ValueError(
            f"Source manifest contains {len(source_items)} measurements; "
            f"expected {args.expected_samples}."
        )

    reference_index = index_measurements(reference_items)
    source_index = index_measurements(source_items)
    reference_keys = set(reference_index)
    source_keys = set(source_index)
    if reference_keys != source_keys:
        raise ValueError(
            "Measurement grids differ: "
            f"reference-only={sorted(reference_keys - source_keys)}, "
            f"source-only={sorted(source_keys - reference_keys)}"
        )

    failures: list[str] = []
    points: list[dict[str, Any]] = []
    elapsed_ratios: list[float] = []

    for key in sorted(reference_keys):
        reference_measurement = reference_index[key]
        source_measurement = source_index[key]
        reference_wav_path = args.reference_directory / output_filename(
            reference_measurement
        )
        source_wav_path = args.source_directory / output_filename(source_measurement)
        reference_wave, reference_samples = recording.read_wave(reference_wav_path)
        source_wave, source_samples = recording.read_wave(source_wav_path)
        comparison = recording.build_comparison(
            reference_engine,
            source_engine,
            reference_measurement,
            source_measurement,
            reference_wave,
            source_wave,
            reference_samples,
            source_samples,
        )
        point_failures = recording.exact_contract_failures(comparison)
        point_id = f"rpm={key[0]},throttle={key[1]},frequency={key[2]}"
        failures.extend(f"{point_id}: {failure}" for failure in point_failures)
        ratio = comparison.get("elapsedMillisecondsRatio")
        if isinstance(ratio, (int, float)):
            elapsed_ratios.append(float(ratio))

        points.append(
            {
                "key": {
                    "rpm": key[0],
                    "throttle": key[1],
                    "frequency": key[2],
                    "length": key[3],
                    "warmupCount": key[4],
                    "overrideRevLimit": key[5],
                },
                "reference": {
                    "measurement": reference_measurement,
                    "wave": asdict(reference_wave),
                },
                "source": {
                    "measurement": source_measurement,
                    "wave": asdict(source_wave),
                },
                "comparison": comparison,
                "contractFailures": point_failures,
            }
        )

    engine_checks = {
        "engine name differs": reference_engine.get("name") == source_engine.get("name"),
        "redline differs": float(reference_engine.get("redlineRpm", 0.0))
        == float(source_engine.get("redlineRpm", 0.0)),
        "displacement differs": float(reference_engine.get("displacementLitres", 0.0))
        == float(source_engine.get("displacementLitres", 0.0)),
        "reference ABI is not 1010": int(reference_engine.get("nativeLibraryVersion", 0))
        == 1010,
        "source ABI is not 2000": int(source_engine.get("nativeLibraryVersion", 0))
        == 2000,
    }
    failures.extend(message for message, passed in engine_checks.items() if not passed)

    performance = {
        "elapsedRatioMinimum": min(elapsed_ratios) if elapsed_ratios else None,
        "elapsedRatioMaximum": max(elapsed_ratios) if elapsed_ratios else None,
        "elapsedRatioMean": (
            sum(elapsed_ratios) / len(elapsed_ratios) if elapsed_ratios else None
        ),
        "note": "Execution time is diagnostic and is not part of the exact parity contract.",
    }
    report: dict[str, Any] = {
        "referenceEngine": reference_engine,
        "sourceEngine": source_engine,
        "expectedSamples": args.expected_samples,
        "points": points,
        "performance": performance,
        "contract": {
            "passed": not failures,
            "failures": failures,
            "requirements": [
                "ABI identities 1010 and 2000",
                "identical engine name, redline and displacement",
                "identical power and torque at every operating point",
                "identical mono PCM16 format and frame count",
                "identical decoded PCM samples at every operating point",
            ],
        },
    }

    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    lines = [
        "ESRecorder multi-point exact parity report",
        f"operating points: {len(points)}",
        f"reference ABI: {reference_engine.get('nativeLibraryVersion')}",
        f"source ABI: {source_engine.get('nativeLibraryVersion')}",
        f"exact contract passed: {not failures}",
        f"elapsed ratio min: {performance['elapsedRatioMinimum']}",
        f"elapsed ratio mean: {performance['elapsedRatioMean']}",
        f"elapsed ratio max: {performance['elapsedRatioMaximum']}",
    ]
    for point in points:
        key = point["key"]
        comparison = point["comparison"]
        lines.append(
            f"{key['rpm']} RPM / {key['throttle']}%: "
            f"PCM={comparison['pcmHashMatch']}, "
            f"power_delta={comparison['powerHorsepowerDelta']}, "
            f"torque_delta={comparison['torqueNewtonMetresDelta']}, "
            f"elapsed_ratio={comparison['elapsedMillisecondsRatio']}"
        )
    lines.extend(f"contract failure: {failure}" for failure in failures)
    args.text_output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 2 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
