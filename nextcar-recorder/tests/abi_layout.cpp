#include "../esrecord_api.h"

#include <cstddef>
#include <cstdint>

static_assert(ESRECORD_ABI_VERSION == 2000);
static_assert(ESRECORD_MAX_INSTANCES == 8);

static_assert(sizeof(SampleConfig) == 280);
static_assert(offsetof(SampleConfig, overrideRevlimit) == 0);
static_assert(offsetof(SampleConfig, prerunCount) == 4);
static_assert(offsetof(SampleConfig, rpm) == 8);
static_assert(offsetof(SampleConfig, throttle) == 12);
static_assert(offsetof(SampleConfig, frequency) == 16);
static_assert(offsetof(SampleConfig, length) == 20);
static_assert(offsetof(SampleConfig, output) == 24);

static_assert(sizeof(SampleResult) == 24);
static_assert(offsetof(SampleResult, success) == 0);
static_assert(offsetof(SampleResult, power) == 4);
static_assert(offsetof(SampleResult, torque) == 8);
static_assert(offsetof(SampleResult, ratio) == 12);
static_assert(offsetof(SampleResult, millis) == 16);

static_assert(static_cast<std::int32_t>(ESRECORD_STATE_IDLE) == 0);
static_assert(static_cast<std::int32_t>(ESRECORD_STATE_COMPILING) == 1);
static_assert(static_cast<std::int32_t>(ESRECORD_STATE_PREPARING) == 2);
static_assert(static_cast<std::int32_t>(ESRECORD_STATE_WARMUP) == 3);
static_assert(static_cast<std::int32_t>(ESRECORD_STATE_RECORDING) == 4);

int main() {
    return 0;
}
