#!/usr/bin/env python3
"""Compare complete legacy and source-built ESRecorder recording sessions."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path, PureWindowsPath
from typing import Any

import compare_recordings as recording


MeasurementKey = tuple[int, int, int, int, int, bool]
PCM_FULL_SCALE = 32768.0


@dataclass(frozen=True)
class StatisticalThresholds:
    power_relative: float
    power_absolute_hp: float
    torque_relative: float
    torque_absolute_nm: float
    rms_db: float
    mean_full_scale: float
    zero_crossing_rate: float
    crest_factor_relative: float
    clipped_samples: int
    peak_absolute: int
    amplitude_percentile_relative: float
    amplitude_percentile_absolute: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare two ESRecorder recording trees and every referenced WAV."
    )
    parser.add_argument("--reference-directory", type=Path, required=True)
    parser.add_argument("--source-directory", type=Path, required=True)
    parser.add_argument("--expected-samples", type=int, required=True)
    parser.add_argument(
        "--mode",
        choices=("exact", "statistical", "diagnostic"),
        required=True,
    )
    parser.add_argument("--power-relative-tolerance", type=float, default=0.0025)
    parser.add_argument("--power-absolute-tolerance-hp", type=float, default=0.25)
    parser.add_argument("--torque-relative-tolerance", type=float, default=0.0025)
    parser.add_argument("--torque-absolute-tolerance-nm", type=float, default=0.5)
    parser.add_argument("--rms-db-tolerance", type=float, default=0.10)
    parser.add_argument("--mean-full-scale-tolerance", type=float, default=0.005)
    parser.add_argument("--zero-crossing-rate-tolerance", type=float, default=0.001)
    parser.add_argument("--crest-factor-relative-tolerance", type=float, default=0.02)
    parser.add_argument("--clipped-sample-tolerance", type=int, default=256)
    parser.add_argument("--peak-absolute-tolerance", type=int, default=512)
    parser.add_argument(
        "--amplitude-percentile-relative-tolerance", type=float, default=0.03
    )
    parser.add_argument(
        "--amplitude-percentile-absolute-tolerance", type=float, default=256.0
    )
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--text-output", type=Path, required=True)
    return parser.parse_args()


def thresholds_from_args(args: argparse.Namespace) -> StatisticalThresholds:
    thresholds = StatisticalThresholds(
        power_relative=args.power_relative_tolerance,
        power_absolute_hp=args.power_absolute_tolerance_hp,
        torque_relative=args.torque_relative_tolerance,
        torque_absolute_nm=args.torque_absolute_tolerance_nm,
        rms_db=args.rms_db_tolerance,
        mean_full_scale=args.mean_full_scale_tolerance,
        zero_crossing_rate=args.zero_crossing_rate_tolerance,
        crest_factor_relative=args.crest_factor_relative_tolerance,
        clipped_samples=args.clipped_sample_tolerance,
        peak_absolute=args.peak_absolute_tolerance,
        amplitude_percentile_relative=args.amplitude_percentile_relative_tolerance,
        amplitude_percentile_absolute=args.amplitude_percentile_absolute_tolerance,
    )
    for name, value in asdict(thresholds).items():
        if value < 0:
            raise ValueError(f"Tolerance {name} must be non-negative, observed {value}")
    return thresholds


def measurements(manifest: dict[str, Any], path: Path) -> list[dict[str, Any]]:
    value = manifest.get("measurements")
    if not isinstance(value, list):
        raise ValueError(f"{path}: measurements must be an array")
    if not all(isinstance(item, dict) for item in value):
        raise ValueError(f"{path}: every measurement must be an object")
    return value


def sample_key(measurement: dict[str, Any]) -> MeasurementKey:
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


def output_filename(measurement: dict[str, Any]) -> str:
    sample = measurement["sample"]
    return PureWindowsPath(str(sample["outputPath"])).name


def engine_identity(engine: dict[str, Any]) -> tuple[str, float, float, int]:
    return (
        str(engine.get("name", "")),
        float(engine.get("redlineRpm", 0.0)),
        float(engine.get("displacementLitres", 0.0)),
        int(engine.get("nativeLibraryVersion", 0)),
    )


def load_session(
    directory: Path,
    expected_samples: int,
) -> tuple[dict[str, Any], dict[MeasurementKey, tuple[dict[str, Any], Path]]]:
    manifest_paths = sorted(directory.rglob("recording-manifest.json"))
    if not manifest_paths:
        raise ValueError(f"No recording manifests found below {directory}")

    session_engine: dict[str, Any] | None = None
    indexed: dict[MeasurementKey, tuple[dict[str, Any], Path]] = {}
    for manifest_path in manifest_paths:
        manifest = recording.load_manifest(manifest_path)
        engine = manifest.get("engine")
        if not isinstance(engine, dict):
            raise ValueError(f"{manifest_path}: engine metadata must be an object")
        if session_engine is None:
            session_engine = engine
        elif engine_identity(session_engine) != engine_identity(engine):
            raise ValueError(f"{manifest_path}: engine metadata changed within one session")

        for measurement in measurements(manifest, manifest_path):
            key = sample_key(measurement)
            if key in indexed:
                raise ValueError(f"Duplicate measurement key below {directory}: {key}")
            wav_path = manifest_path.parent / output_filename(measurement)
            if not wav_path.is_file():
                raise ValueError(f"Referenced WAV does not exist: {wav_path}")
            indexed[key] = (measurement, wav_path)

    if session_engine is None:
        raise ValueError(f"No engine metadata found below {directory}")
    if len(indexed) != expected_samples:
        raise ValueError(
            f"{directory}: observed {len(indexed)} measurements; "
            f"expected {expected_samples}."
        )
    return session_engine, indexed


def within_absolute_or_relative(
    reference: float,
    source: float,
    absolute_tolerance: float,
    relative_tolerance: float,
) -> bool:
    absolute_delta = abs(source - reference)
    if absolute_delta <= absolute_tolerance:
        return True
    if reference == 0.0:
        return False
    return absolute_delta / abs(reference) <= relative_tolerance


def relative_difference(reference: float, source: float) -> float | None:
    if reference == 0.0:
        return None
    return abs(source - reference) / abs(reference)


def statistical_contract_failures(
    reference_measurement: dict[str, Any],
    source_measurement: dict[str, Any],
    reference_wave: recording.WaveStats,
    source_wave: recording.WaveStats,
    comparison: dict[str, Any],
    thresholds: StatisticalThresholds,
) -> list[str]:
    failures: list[str] = []

    reference_power = float(reference_measurement.get("powerHorsepower", 0.0))
    source_power = float(source_measurement.get("powerHorsepower", 0.0))
    if not within_absolute_or_relative(
        reference_power,
        source_power,
        thresholds.power_absolute_hp,
        thresholds.power_relative,
    ):
        failures.append("power exceeds statistical tolerance")

    reference_torque = float(reference_measurement.get("torqueNewtonMetres", 0.0))
    source_torque = float(source_measurement.get("torqueNewtonMetres", 0.0))
    if not within_absolute_or_relative(
        reference_torque,
        source_torque,
        thresholds.torque_absolute_nm,
        thresholds.torque_relative,
    ):
        failures.append("torque exceeds statistical tolerance")

    rms_delta_db = comparison.get("waveRmsDeltaDb")
    if not isinstance(rms_delta_db, (int, float)) or abs(rms_delta_db) > thresholds.rms_db:
        failures.append("RMS level exceeds statistical tolerance")

    if abs(source_wave.mean - reference_wave.mean) > (
        thresholds.mean_full_scale * PCM_FULL_SCALE
    ):
        failures.append("DC mean exceeds statistical tolerance")

    if (
        abs(source_wave.zero_crossing_rate - reference_wave.zero_crossing_rate)
        > thresholds.zero_crossing_rate
    ):
        failures.append("zero-crossing rate exceeds statistical tolerance")

    reference_crest = reference_wave.crest_factor
    source_crest = source_wave.crest_factor
    if reference_crest is None or source_crest is None:
        if reference_crest != source_crest:
            failures.append("crest-factor availability differs")
    else:
        crest_difference = relative_difference(reference_crest, source_crest)
        if crest_difference is None or crest_difference > thresholds.crest_factor_relative:
            failures.append("crest factor exceeds statistical tolerance")

    if (
        abs(source_wave.clipped_samples - reference_wave.clipped_samples)
        > thresholds.clipped_samples
    ):
        failures.append("clipped-sample count exceeds statistical tolerance")

    if (
        abs(source_wave.peak_absolute - reference_wave.peak_absolute)
        > thresholds.peak_absolute
    ):
        failures.append("absolute peak exceeds statistical tolerance")

    percentile_names = ("absolute_p50", "absolute_p90", "absolute_p95", "absolute_p99")
    for name in percentile_names:
        reference_value = float(getattr(reference_wave, name))
        source_value = float(getattr(source_wave, name))
        if not within_absolute_or_relative(
            reference_value,
            source_value,
            thresholds.amplitude_percentile_absolute,
            thresholds.amplitude_percentile_relative,
        ):
            failures.append(f"{name} amplitude exceeds statistical tolerance")

    return failures


def main() -> int:
    args = parse_args()
    thresholds = thresholds_from_args(args)
    reference_engine, reference_index = load_session(
        args.reference_directory, args.expected_samples
    )
    source_engine, source_index = load_session(
        args.source_directory, args.expected_samples
    )

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

    for key in sorted(reference_keys):
        reference_measurement, reference_wav_path = reference_index[key]
        source_measurement, source_wav_path = source_index[key]
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
        exact_failures = recording.exact_contract_failures(comparison)
        point_id = f"rpm={key[0]},throttle={key[1]},frequency={key[2]}"

        structural_checks = {
            "WAV format differs": comparison["waveFormatMatch"],
            "WAV frame count differs": comparison["waveFrameCountDelta"] == 0,
            "PCM sample length differs": comparison["samples"]["sameLength"],
        }
        structural_failures = [
            message for message, passed in structural_checks.items() if not passed
        ]
        feature_failures: list[str] = []
        if args.mode == "exact":
            feature_failures = exact_failures
        elif args.mode == "statistical":
            feature_failures = statistical_contract_failures(
                reference_measurement,
                source_measurement,
                reference_wave,
                source_wave,
                comparison,
                thresholds,
            )

        point_failures = structural_failures + feature_failures
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
                "exactContractFailures": exact_failures,
                "structuralFailures": structural_failures,
                "featureContractFailures": feature_failures,
            }
        )

    performance = {
        "elapsedRatioMinimum": min(elapsed_ratios) if elapsed_ratios else None,
        "elapsedRatioMaximum": max(elapsed_ratios) if elapsed_ratios else None,
        "elapsedRatioMean": (
            sum(elapsed_ratios) / len(elapsed_ratios) if elapsed_ratios else None
        ),
        "note": "Execution time is diagnostic and is not a parity requirement.",
    }
    requirements = [
        "ABI identities 1010 and 2000",
        "identical engine name, redline and displacement",
        "identical mono PCM16 structure and frame count",
    ]
    if args.mode == "exact":
        requirements.extend(
            [
                "identical power and torque at every operating point",
                "identical decoded PCM samples at every operating point",
            ]
        )
    elif args.mode == "statistical":
        requirements.extend(
            [
                "power and torque within combined absolute/relative tolerances",
                "RMS, DC mean, crest factor, zero-crossing rate, clipping and peak within tolerances",
                "absolute-amplitude p50/p90/p95/p99 within tolerances",
                "PCM hashes and sample correlation retained as diagnostics only",
            ]
        )
    else:
        requirements.append(
            "batch telemetry and PCM differences are retained as diagnostics"
        )

    report: dict[str, Any] = {
        "mode": args.mode,
        "referenceEngine": reference_engine,
        "sourceEngine": source_engine,
        "expectedSamples": args.expected_samples,
        "points": points,
        "performance": performance,
        "contract": {
            "passed": not failures,
            "failures": failures,
            "requirements": requirements,
            "statisticalThresholds": asdict(thresholds),
        },
    }

    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    lines = [
        f"ESRecorder {args.mode} multi-point parity report",
        f"operating points: {len(points)}",
        f"reference ABI: {reference_engine.get('nativeLibraryVersion')}",
        f"source ABI: {source_engine.get('nativeLibraryVersion')}",
        f"contract passed: {not failures}",
        f"elapsed ratio min: {performance['elapsedRatioMinimum']}",
        f"elapsed ratio mean: {performance['elapsedRatioMean']}",
        f"elapsed ratio max: {performance['elapsedRatioMaximum']}",
    ]
    if args.mode == "statistical":
        lines.append(f"statistical thresholds: {json.dumps(asdict(thresholds), sort_keys=True)}")
    for point in points:
        key = point["key"]
        comparison = point["comparison"]
        lines.append(
            f"{key['rpm']} RPM / {key['throttle']}%: "
            f"PCM={comparison['pcmHashMatch']}, "
            f"power_delta={comparison['powerHorsepowerDelta']}, "
            f"torque_delta={comparison['torqueNewtonMetresDelta']}, "
            f"rms_delta_db={comparison['waveRmsDeltaDb']}, "
            f"zcr_delta={comparison['waveZeroCrossingRateDelta']}, "
            f"elapsed_ratio={comparison['elapsedMillisecondsRatio']}, "
            f"feature_failures={point['featureContractFailures']}"
        )
    lines.extend(f"contract failure: {failure}" for failure in failures)
    args.text_output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 2 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
