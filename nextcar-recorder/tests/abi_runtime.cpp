#include "../esrecord_api.h"

#include <cmath>
#include <cstring>

namespace {

bool equals(const char *actual, const char *expected) {
    return actual != nullptr && std::strcmp(actual, expected) == 0;
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

    return 0;
}
