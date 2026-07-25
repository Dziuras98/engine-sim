#ifndef NEXTCAR_WAV_READER_H
#define NEXTCAR_WAV_READER_H

#include <cstdint>
#include <string>
#include <vector>

namespace nextcar::recorder {

struct Pcm16Wave {
    std::int32_t sampleRate = 0;
    std::vector<std::int16_t> samples;
};

bool readMonoPcm16Wave(const std::string &path, Pcm16Wave &wave);

} // namespace nextcar::recorder

#endif // NEXTCAR_WAV_READER_H
