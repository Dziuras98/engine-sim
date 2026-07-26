#!/usr/bin/env python3
"""Compare reference and source-built ESRecorder outputs without third-party packages."""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import math
import sys
import wave
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class WaveStats:
    path: str
    sha256: str
    channels: int
    sample_width_bytes: int
    sample_rate: int
    frame_count: int
    duration_seconds: float
    minimum: int
    maximum: int
    peak_absolute: int
    mean: float
    rms: float
    crest_factor: float | None
    zero_crossing_rate: float
    clipped_samples: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare one legacy ESRecorder recording with one source-built recording."
    )
    parser.add_argument("--reference-manifest", type=Path, required=True)
    parser.add_argument("--source-manifest", type=Path, required=True)
    parser.add_argument("--reference-wav", type=Path, required=True)
    parser.add_argument("--source-wav", type=Path, required=True)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--text-output", type=Path, required=True)
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_wave(path: Path) -> tuple[WaveStats, array.array[int]]:
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frame_count = wav.getnframes()
        raw = wav.readframes(frame_count)

    if channels != 1:
        raise ValueError(f"{path}: expected mono WAV, observed {channels} channels")
    if sample_width != 2:
        raise ValueError(
            f"{path}: expected PCM16 WAV, observed {sample_width * 8}-bit samples"
        )

    samples = array.array("h")
    samples.frombytes(raw)
    if sys.byteorder != "little":
        samples.byteswap()
    if len(samples) != frame_count:
        raise ValueError(
            f"{path}: decoded {len(samples)} samples for {frame_count} frames"
        )
    if not samples:
        raise ValueError(f"{path}: WAV contains no samples")

    count = len(samples)
    total = sum(samples)
    square_total = sum(float(sample) * float(sample) for sample in samples)
    mean = total / count
    rms = math.sqrt(square_total / count)
    peak = max(abs(min(samples)), abs(max(samples)))
    crossings = sum(
        1
        for previous, current in zip(samples, samples[1:])
        if (previous < 0 <= current) or (previous >= 0 > current)
    )
    clipped = sum(1 for sample in samples if sample in (-32768, 32767))

    stats = WaveStats(
        path=str(path),
        sha256=sha256(path),
        channels=channels,
        sample_width_bytes=sample_width,
        sample_rate=sample_rate,
        frame_count=frame_count,
        duration_seconds=frame_count / sample_rate,
        minimum=min(samples),
        maximum=max(samples),
        peak_absolute=peak,
        mean=mean,
        rms=rms,
        crest_factor=(peak / rms) if rms else None,
        zero_crossing_rate=crossings / max(1, count - 1),
        clipped_samples=clipped,
    )
    return stats, samples


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8-sig") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: manifest root must be an object")
    return value


def first_measurement(manifest: dict[str, Any], path: Path) -> dict[str, Any]:
    measurements = manifest.get("measurements")
    if not isinstance(measurements, list) or len(measurements) != 1:
        raise ValueError(f"{path}: expected exactly one measurement")
    measurement = measurements[0]
    if not isinstance(measurement, dict):
        raise ValueError(f"{path}: measurement must be an object")
    return measurement


def relative_delta(reference: float, source: float) -> float | None:
    if reference == 0:
        return None
    return (source - reference) / abs(reference)


def sample_comparison(
    reference: array.array[int], source: array.array[int]
) -> dict[str, Any]:
    count = min(len(reference), len(source))
    if count == 0:
        raise ValueError("Cannot compare empty sample arrays")

    sum_x = 0.0
    sum_y = 0.0
    sum_xx = 0.0
    sum_yy = 0.0
    sum_xy = 0.0
    absolute_difference = 0.0
    square_difference = 0.0
    maximum_absolute_difference = 0

    for x_raw, y_raw in zip(reference[:count], source[:count]):
        x = float(x_raw)
        y = float(y_raw)
        difference = y - x
        absolute = abs(y_raw - x_raw)
        sum_x += x
        sum_y += y
        sum_xx += x * x
        sum_yy += y * y
        sum_xy += x * y
        absolute_difference += absolute
        square_difference += difference * difference
        maximum_absolute_difference = max(maximum_absolute_difference, absolute)

    covariance = count * sum_xy - sum_x * sum_y
    variance_x = count * sum_xx - sum_x * sum_x
    variance_y = count * sum_yy - sum_y * sum_y
    denominator = math.sqrt(max(0.0, variance_x) * max(0.0, variance_y))

    return {
        "comparedSamples": count,
        "sameLength": len(reference) == len(source),
        "pearsonCorrelation": (covariance / denominator) if denominator else None,
        "meanAbsoluteDifference": absolute_difference / count,
        "rootMeanSquareDifference": math.sqrt(square_difference / count),
        "maximumAbsoluteDifference": maximum_absolute_difference,
    }


def main() -> int:
    args = parse_args()

    reference_manifest = load_manifest(args.reference_manifest)
    source_manifest = load_manifest(args.source_manifest)
    reference_measurement = first_measurement(reference_manifest, args.reference_manifest)
    source_measurement = first_measurement(source_manifest, args.source_manifest)
    reference_wave, reference_samples = read_wave(args.reference_wav)
    source_wave, source_samples = read_wave(args.source_wav)

    reference_engine = reference_manifest.get("engine", {})
    source_engine = source_manifest.get("engine", {})

    reference_power = float(reference_measurement.get("powerHorsepower", 0.0))
    source_power = float(source_measurement.get("powerHorsepower", 0.0))
    reference_torque = float(reference_measurement.get("torqueNewtonMetres", 0.0))
    source_torque = float(source_measurement.get("torqueNewtonMetres", 0.0))

    report: dict[str, Any] = {
        "reference": {
            "engine": reference_engine,
            "measurement": reference_measurement,
            "wave": asdict(reference_wave),
        },
        "source": {
            "engine": source_engine,
            "measurement": source_measurement,
            "wave": asdict(source_wave),
        },
        "comparison": {
            "engineNameMatch": reference_engine.get("name") == source_engine.get("name"),
            "redlineRpmDelta": float(source_engine.get("redlineRpm", 0.0))
            - float(reference_engine.get("redlineRpm", 0.0)),
            "displacementLitresDelta": float(
                source_engine.get("displacementLitres", 0.0)
            )
            - float(reference_engine.get("displacementLitres", 0.0)),
            "powerHorsepowerDelta": source_power - reference_power,
            "powerRelativeDelta": relative_delta(reference_power, source_power),
            "torqueNewtonMetresDelta": source_torque - reference_torque,
            "torqueRelativeDelta": relative_delta(reference_torque, source_torque),
            "waveFormatMatch": (
                reference_wave.channels == source_wave.channels
                and reference_wave.sample_width_bytes == source_wave.sample_width_bytes
                and reference_wave.sample_rate == source_wave.sample_rate
            ),
            "waveFrameCountDelta": source_wave.frame_count - reference_wave.frame_count,
            "waveRmsRatio": (
                source_wave.rms / reference_wave.rms if reference_wave.rms else None
            ),
            "waveRmsDeltaDb": (
                20.0 * math.log10(source_wave.rms / reference_wave.rms)
                if reference_wave.rms and source_wave.rms
                else None
            ),
            "samples": sample_comparison(reference_samples, source_samples),
        },
    }

    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    with args.json_output.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write("\n")

    comparison = report["comparison"]
    lines = [
        "ESRecorder black-box parity report",
        f"reference ABI: {reference_engine.get('nativeLibraryVersion')}",
        f"source ABI: {source_engine.get('nativeLibraryVersion')}",
        f"engine name match: {comparison['engineNameMatch']}",
        f"redline delta RPM: {comparison['redlineRpmDelta']:.6f}",
        f"displacement delta L: {comparison['displacementLitresDelta']:.9f}",
        f"power delta hp: {comparison['powerHorsepowerDelta']:.6f}",
        f"power relative delta: {comparison['powerRelativeDelta']}",
        f"torque delta Nm: {comparison['torqueNewtonMetresDelta']:.6f}",
        f"torque relative delta: {comparison['torqueRelativeDelta']}",
        f"WAV format match: {comparison['waveFormatMatch']}",
        f"WAV frame-count delta: {comparison['waveFrameCountDelta']}",
        f"WAV RMS delta dB: {comparison['waveRmsDeltaDb']}",
        f"sample correlation: {comparison['samples']['pearsonCorrelation']}",
        f"sample RMSE: {comparison['samples']['rootMeanSquareDifference']}",
        f"reference WAV SHA-256: {reference_wave.sha256}",
        f"source WAV SHA-256: {source_wave.sha256}",
    ]
    args.text_output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
