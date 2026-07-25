#include "esrecord_internal.h"

#include "../include/ignition_module.h"
#include "../include/units.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <limits>
#include <string>
#include <vector>

namespace {

constexpr std::int32_t kOutputSampleRate = 44100;
constexpr std::size_t kAudioBufferSize = 2048;

std::string readOutputPath(const SampleConfig &config) {
    std::size_t length = 0;
    while (length < sizeof(config.output) && config.output[length] != '\0') {
        ++length;
    }

    if (length == sizeof(config.output)) {
        return {};
    }

    return std::string(config.output, length);
}

template <typename T>
void writeValue(std::ofstream &stream, const T &value) {
    stream.write(reinterpret_cast<const char *>(&value), sizeof(T));
}

void writeWaveHeader(std::ofstream &stream) {
    const std::int32_t placeholder = 0;
    const std::int32_t formatChunkSize = 16;
    const std::int16_t audioFormat = 1;
    const std::int16_t channels = 1;
    const std::int16_t bitDepth = 16;
    const std::int32_t bytesPerSecond =
        channels * kOutputSampleRate * bitDepth / 8;
    const std::int16_t bytesPerBlock = channels * bitDepth / 8;

    stream.write("RIFF", 4);
    writeValue(stream, placeholder);
    stream.write("WAVE", 4);
    stream.write("fmt ", 4);
    writeValue(stream, formatChunkSize);
    writeValue(stream, audioFormat);
    writeValue(stream, channels);
    writeValue(stream, kOutputSampleRate);
    writeValue(stream, bytesPerSecond);
    writeValue(stream, bytesPerBlock);
    writeValue(stream, bitDepth);
    stream.write("data", 4);
    writeValue(stream, placeholder);
}

void finaliseWaveHeader(
    std::ofstream &stream,
    const std::int32_t fileSize,
    const std::int32_t dataSize)
{
    const std::int32_t riffSize = fileSize - 8;
    stream.seekp(4, std::ios::beg);
    writeValue(stream, riffSize);
    stream.seekp(40, std::ios::beg);
    writeValue(stream, dataSize);
}

void appendInfoChunk(
    std::ofstream &stream,
    std::int32_t &fileSize,
    const std::string &engineName,
    const SampleConfig &config)
{
    const std::string trackName =
        std::to_string(config.rpm) + "RPM / " +
        std::to_string(config.throttle) + "%";
    const std::string author =
        "nEXTcAR ESRecord ABI 2 / engine-sim source "
        ES_ENGINE_SIM_SOURCE_REVISION;

    stream.write("LIST", 4);
    fileSize += 4;

    const std::streampos infoSizePosition = stream.tellp();
    std::int32_t infoSize = 4;
    writeValue(stream, infoSize);
    fileSize += sizeof(infoSize);
    stream.write("INFO", 4);
    fileSize += 4;

    const auto writeInfoField = [&](const char *id, const std::string &value) {
        stream.write(id, 4);
        fileSize += 4;
        infoSize += 4;

        const std::int32_t valueLength =
            static_cast<std::int32_t>(value.size() + 1);
        writeValue(stream, valueLength);
        fileSize += sizeof(valueLength);
        infoSize += sizeof(valueLength);

        stream.write(value.c_str(), valueLength);
        fileSize += valueLength;
        infoSize += valueLength;

        if ((valueLength & 1) != 0) {
            const char padding = 0;
            stream.write(&padding, 1);
            ++fileSize;
            ++infoSize;
        }
    };

    writeInfoField("INAM", trackName);
    writeInfoField("IART", author);
    writeInfoField("IPRD", engineName);

    const std::streampos end = stream.tellp();
    stream.seekp(infoSizePosition, std::ios::beg);
    writeValue(stream, infoSize);
    stream.seekp(end, std::ios::beg);
}

} // namespace

ESRECORD_API SampleResult ESRecord_Record(
    const std::int32_t instanceId,
    const SampleConfig config)
{
    using namespace nextcar::recorder;

    SampleResult result{};
    Instance *instance = getInstance(instanceId);
    const std::string outputPath = readOutputPath(config);

    if (instance == nullptr || outputPath.empty() ||
        config.rpm <= 0 ||
        config.throttle < 0 || config.throttle > 100 ||
        config.frequency <= 0 ||
        config.length <= 0 ||
        config.prerunCount < 0)
    {
        return result;
    }

    const std::int64_t targetSamples64 =
        static_cast<std::int64_t>(kOutputSampleRate) * config.length;
    if (targetSamples64 <= 0 ||
        targetSamples64 > std::numeric_limits<std::int32_t>::max())
    {
        return result;
    }

    std::lock_guard<std::mutex> lock(instance->mutex);
    if (instance->engine == nullptr ||
        instance->vehicle == nullptr ||
        instance->transmission == nullptr)
    {
        return result;
    }

    instance->state = ESRECORD_STATE_PREPARING;
    instance->progress = 0;

    std::ofstream output(outputPath, std::ios::out | std::ios::binary);
    if (!output.is_open()) {
        instance->state = ESRECORD_STATE_IDLE;
        return result;
    }

    writeWaveHeader(output);
    std::int32_t fileSize = 44;
    std::int32_t dataSize = 0;

    const auto started = std::chrono::steady_clock::now();
    if (!initialiseUnlocked(*instance)) {
        instance->state = ESRECORD_STATE_IDLE;
        return result;
    }

    const float throttleValue = config.throttle / 100.0f;
    instance->simulator->setSimulationFrequency(config.frequency);
    instance->simulator->m_dyno.m_enabled = false;
    instance->simulator->m_dyno.m_hold = true;
    instance->simulator->m_dyno.m_rotationSpeed = units::rpm(config.rpm);

    instance->engine->setSpeedControl(1.0);
    instance->simulator->m_starterMotor.m_enabled = true;
    instance->engine->getIgnitionModule()->m_enabled = true;

    if (config.overrideRevlimit != 0) {
        instance->engine->getIgnitionModule()->setRevlimit(
            units::rpm(config.rpm + 1000));
    }

    std::vector<std::int16_t> buffer(kAudioBufferSize);

    instance->state = ESRECORD_STATE_WARMUP;
    for (std::int32_t frame = 0; frame < config.prerunCount; ++frame) {
        updateUnlocked(*instance, 60.0f);

        if (frame > config.prerunCount / 2) {
            instance->simulator->m_dyno.m_enabled = true;
            instance->simulator->m_starterMotor.m_enabled = false;
            instance->engine->setSpeedControl(throttleValue);
        }

        if (frame > config.prerunCount / 2 + config.prerunCount / 4) {
            constexpr double rc = 0.1;
            constexpr double dt = 1.0 / 60.0;
            constexpr double alpha = dt / (dt + rc);

            const double torque = units::convert(
                instance->simulator->getFilteredDynoTorque(), units::Nm);
            const double power = units::convert(
                instance->simulator->getDynoPower(), units::hp);

            result.torque = static_cast<float>(
                (1.0 - alpha) * result.torque + alpha * torque);
            result.power = static_cast<float>(
                (1.0 - alpha) * result.power + alpha * power);
        }

        instance->simulator->readAudioOutput(
            static_cast<unsigned int>(buffer.size()), buffer.data());
        instance->progress = config.prerunCount == 0
            ? 100
            : static_cast<std::int32_t>(
                static_cast<double>(frame) / config.prerunCount * 100.0);
    }

    const std::int32_t targetSamples =
        static_cast<std::int32_t>(targetSamples64);
    std::int32_t samplesRecorded = 0;
    std::int32_t framesWithoutAudio = 0;
    instance->state = ESRECORD_STATE_RECORDING;
    instance->progress = 0;

    while (samplesRecorded < targetSamples) {
        updateUnlocked(*instance, 60.0f);

        constexpr double rc = 0.1;
        constexpr double dt = 1.0 / 60.0;
        constexpr double alpha = dt / (dt + rc);

        const double torque = units::convert(
            instance->simulator->getFilteredDynoTorque(), units::Nm);
        const double power = units::convert(
            instance->simulator->getDynoPower(), units::hp);
        result.torque = static_cast<float>(
            (1.0 - alpha) * result.torque + alpha * torque);
        result.power = static_cast<float>(
            (1.0 - alpha) * result.power + alpha * power);

        const int available = instance->simulator->readAudioOutput(
            static_cast<unsigned int>(buffer.size()), buffer.data());
        if (available <= 0) {
            if (++framesWithoutAudio > 6000) {
                instance->state = ESRECORD_STATE_IDLE;
                return SampleResult{};
            }
            continue;
        }
        framesWithoutAudio = 0;

        const std::int32_t remaining = targetSamples - samplesRecorded;
        const std::int32_t samplesToWrite =
            std::min<std::int32_t>(available, remaining);
        const std::int32_t bytesToWrite =
            samplesToWrite * static_cast<std::int32_t>(sizeof(std::int16_t));

        output.write(
            reinterpret_cast<const char *>(buffer.data()), bytesToWrite);
        if (!output.good()) {
            instance->state = ESRECORD_STATE_IDLE;
            return SampleResult{};
        }

        samplesRecorded += samplesToWrite;
        fileSize += bytesToWrite;
        dataSize += bytesToWrite;
        instance->progress = static_cast<std::int32_t>(
            static_cast<double>(samplesRecorded) / targetSamples * 100.0);
    }

    appendInfoChunk(output, fileSize, instance->engine->getName(), config);
    finaliseWaveHeader(output, fileSize, dataSize);
    output.flush();
    output.close();

    const auto finished = std::chrono::steady_clock::now();
    const std::int64_t elapsedMilliseconds =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            finished - started).count();

    result.millis = elapsedMilliseconds;
    result.ratio = elapsedMilliseconds <= 0
        ? 0.0f
        : static_cast<float>(config.length) /
            (static_cast<float>(elapsedMilliseconds) / 1000.0f);
    result.success = 1;

    instance->progress = 100;
    instance->state = ESRECORD_STATE_IDLE;
    return result;
}
