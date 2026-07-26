#include "../esrecord_api.h"

#include <cstring>
#include <filesystem>
#include <limits>

namespace {

bool equals(const char *actual, const char *expected) {
    return actual != nullptr && std::strcmp(actual, expected) == 0;
}

void setOutputPath(SampleConfig &config, const char *path) {
    std::strncpy(config.output, path, sizeof(config.output) - 1);
    config.output[sizeof(config.output) - 1] = '\0';
}

bool fileDoesNotExist(const char *path) {
    std::error_code error;
    return !std::filesystem::exists(path, error);
}

} // namespace

int main() {
    if (ESRecord_GetVersion() != ESRECORD_ABI_VERSION) return 1;
    if (ESRecord_GetMaxInstances() != ESRECORD_MAX_INSTANCES) return 2;

    if (!equals(
            ESRecord_GetEngineSimSourceRevision(),
            "31d09faf7b249320a8bf45e2b9bd7dfd8b7ff704"))
    {
        return 3;
    }

    if (!equals(
            ESRecord_GetCompatibilityTarget(),
            "0.1.14a-reference-pending"))
    {
        return 4;
    }

    std::int32_t progress = -1;
    if (ESRecord_GetState(-1, progress) != ESRECORD_STATE_IDLE) return 5;
    if (progress != 0) return 6;

    if (ESRecord_Compile(-1, nullptr) != 0) return 7;
    if (ESRecord_Initialise(-1) != 0) return 8;
    if (ESRecord_Update(-1, 60.0f) != 0.0) return 9;
    if (ESRecord_GetSimState(-1) != 0) return 10;

    SampleConfig invalidConfig{};
    const SampleResult invalidResult = ESRecord_Record(-1, invalidConfig);
    if (invalidResult.success != 0) return 11;

    if (!equals(ESRecord_Engine_GetName(-1), "")) return 12;
    if (ESRecord_Engine_GetRedline(-1) != -1.0f) return 13;
    if (ESRecord_Engine_GetDisplacement(-1) != -1.0f) return 14;

    // Managed ESRecorder allocates/resets a slot before compiling an engine.
    // An empty slot is valid but must not report a ready simulator yet.
    if (ESRecord_Initialise(0) != 1) return 15;
    if (ESRecord_GetSimState(0) != 0) return 16;
    if (!equals(ESRecord_Engine_GetName(0), "")) return 17;

    progress = -1;
    if (ESRecord_GetState(0, progress) != ESRECORD_STATE_IDLE) return 18;
    if (progress != 0) return 19;

    // Resetting an already empty slot is idempotent.
    if (ESRecord_Initialise(0) != 1) return 20;
    if (ESRecord_GetSimState(0) != 0) return 21;

    constexpr const char *rpmOverflowPath = "abi-runtime-rpm-overflow.wav";
    std::filesystem::remove(rpmOverflowPath);
    SampleConfig rpmOverflow{};
    rpmOverflow.overrideRevlimit = 1;
    rpmOverflow.rpm = std::numeric_limits<std::int32_t>::max();
    rpmOverflow.throttle = 50;
    rpmOverflow.frequency = 10000;
    rpmOverflow.length = 1;
    setOutputPath(rpmOverflow, rpmOverflowPath);
    if (ESRecord_Record(0, rpmOverflow).success != 0) return 22;
    if (!fileDoesNotExist(rpmOverflowPath)) return 23;

    constexpr const char *lengthOverflowPath = "abi-runtime-length-overflow.wav";
    std::filesystem::remove(lengthOverflowPath);
    SampleConfig lengthOverflow{};
    lengthOverflow.overrideRevlimit = 0;
    lengthOverflow.rpm = 2000;
    lengthOverflow.throttle = 50;
    lengthOverflow.frequency = 10000;
    lengthOverflow.length = std::numeric_limits<std::int32_t>::max();
    setOutputPath(lengthOverflow, lengthOverflowPath);
    if (ESRecord_Record(0, lengthOverflow).success != 0) return 24;
    if (!fileDoesNotExist(lengthOverflowPath)) return 25;

    SampleConfig unterminatedPath{};
    unterminatedPath.rpm = 2000;
    unterminatedPath.throttle = 50;
    unterminatedPath.frequency = 10000;
    unterminatedPath.length = 1;
    std::memset(unterminatedPath.output, 'x', sizeof(unterminatedPath.output));
    if (ESRecord_Record(0, unterminatedPath).success != 0) return 26;

    return 0;
}
