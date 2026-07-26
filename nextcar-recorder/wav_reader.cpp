#include "wav_reader.h"

#include <array>
#include <cstring>
#include <fstream>
#include <limits>

namespace nextcar::recorder {
namespace {

template <typename T>
bool readValue(std::ifstream &stream, T &value) {
    stream.read(reinterpret_cast<char *>(&value), sizeof(T));
    return stream.good();
}

bool readId(std::ifstream &stream, std::array<char, 4> &id) {
    stream.read(id.data(), static_cast<std::streamsize>(id.size()));
    return stream.good();
}

bool equals(const std::array<char, 4> &id, const char *expected) {
    return std::memcmp(id.data(), expected, id.size()) == 0;
}

bool skipBytes(std::ifstream &stream, const std::uint64_t size) {
    if (size > static_cast<std::uint64_t>(
            std::numeric_limits<std::streamoff>::max()))
    {
        return false;
    }

    stream.seekg(static_cast<std::streamoff>(size), std::ios::cur);
    return stream.good();
}

bool skipChunk(std::ifstream &stream, const std::uint32_t size) {
    return skipBytes(
        stream,
        static_cast<std::uint64_t>(size) + (size & 1U));
}

} // namespace

bool readMonoPcm16Wave(const std::string &path, Pcm16Wave &wave) {
    wave = {};

    std::ifstream stream(path, std::ios::binary);
    if (!stream.is_open()) {
        return false;
    }

    std::array<char, 4> id{};
    std::uint32_t riffSize = 0;
    if (!readId(stream, id) || !equals(id, "RIFF") ||
        !readValue(stream, riffSize) || riffSize < 4 ||
        !readId(stream, id) || !equals(id, "WAVE"))
    {
        return false;
    }

    std::uint16_t format = 0;
    std::uint16_t channels = 0;
    std::uint32_t sampleRate = 0;
    std::uint16_t bitsPerSample = 0;
    bool foundFormat = false;
    bool foundData = false;

    while (stream.good() && !foundData) {
        std::uint32_t chunkSize = 0;
        if (!readId(stream, id) || !readValue(stream, chunkSize)) {
            break;
        }

        if (equals(id, "fmt ")) {
            if (chunkSize < 16) {
                return false;
            }

            std::uint32_t byteRate = 0;
            std::uint16_t blockAlign = 0;
            if (!readValue(stream, format) ||
                !readValue(stream, channels) ||
                !readValue(stream, sampleRate) ||
                !readValue(stream, byteRate) ||
                !readValue(stream, blockAlign) ||
                !readValue(stream, bitsPerSample))
            {
                return false;
            }

            const std::uint32_t remaining = chunkSize - 16;
            if (!skipBytes(stream, remaining)) {
                return false;
            }
            if ((chunkSize & 1U) != 0 && !skipBytes(stream, 1)) {
                return false;
            }

            if (format != 1 || channels != 1 || bitsPerSample != 16 ||
                sampleRate == 0 || blockAlign != 2 ||
                byteRate != sampleRate * blockAlign)
            {
                return false;
            }

            foundFormat = true;
        }
        else if (equals(id, "data")) {
            if (!foundFormat ||
                (chunkSize % sizeof(std::int16_t)) != 0 ||
                chunkSize > static_cast<std::uint32_t>(
                    std::numeric_limits<std::streamsize>::max()))
            {
                return false;
            }

            const std::size_t sampleCount =
                chunkSize / sizeof(std::int16_t);
            wave.samples.resize(sampleCount);
            stream.read(
                reinterpret_cast<char *>(wave.samples.data()),
                static_cast<std::streamsize>(chunkSize));
            if (!stream.good()) {
                return false;
            }

            wave.sampleRate = static_cast<std::int32_t>(sampleRate);
            foundData = true;
        }
        else if (!skipChunk(stream, chunkSize)) {
            return false;
        }
    }

    return foundData && !wave.samples.empty();
}

} // namespace nextcar::recorder
