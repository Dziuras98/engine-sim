#ifndef NEXTCAR_ESRECORD_API_H
#define NEXTCAR_ESRECORD_API_H

#include <cstdint>

#if defined(_WIN32)
#define ESRECORD_API extern "C" __declspec(dllexport)
#else
#define ESRECORD_API extern "C" __attribute__((visibility("default")))
#endif

#define ESRECORD_MAX_INSTANCES 8
#define ESRECORD_ABI_VERSION 2000

// The numeric values are part of the managed/native ABI.
enum ESRecordState : std::int32_t {
    ESRECORD_STATE_IDLE = 0,
    ESRECORD_STATE_COMPILING = 1,
    ESRECORD_STATE_PREPARING = 2,
    ESRECORD_STATE_WARMUP = 3,
    ESRECORD_STATE_RECORDING = 4
};

// Win32 BOOL-compatible fields are used deliberately. Existing C# callers use
// UnmanagedType.Bool, which is a four-byte integer rather than a C++ bool.
struct SampleConfig {
    std::int32_t overrideRevlimit;
    std::int32_t prerunCount;
    std::int32_t rpm;
    std::int32_t throttle;
    std::int32_t frequency;
    std::int32_t length;
    char output[256];
};

struct SampleResult {
    std::int32_t success;
    float power;
    float torque;
    float ratio;
    std::int64_t millis;
};

static_assert(sizeof(SampleConfig) == 280, "SampleConfig ABI size changed");
static_assert(sizeof(SampleResult) == 24, "SampleResult ABI size changed");

ESRECORD_API std::int32_t ESRecord_Compile(std::int32_t instanceId, const char *path);
ESRECORD_API std::int32_t ESRecord_Initialise(std::int32_t instanceId);
ESRECORD_API double ESRecord_Update(std::int32_t instanceId, float averageFps);
ESRECORD_API SampleResult ESRecord_Record(std::int32_t instanceId, SampleConfig config);

ESRECORD_API std::int32_t ESRecord_GetSimState(std::int32_t instanceId);
ESRECORD_API ESRecordState ESRecord_GetState(std::int32_t instanceId, std::int32_t &progress);
ESRECORD_API std::int32_t ESRecord_GetVersion();
ESRECORD_API std::int32_t ESRecord_GetMaxInstances();
ESRECORD_API const char *ESRecord_GetEngineSimSourceRevision();
ESRECORD_API const char *ESRecord_GetCompatibilityTarget();

ESRECORD_API const char *ESRecord_Engine_GetName(std::int32_t instanceId = 0);
ESRECORD_API float ESRecord_Engine_GetRedline(std::int32_t instanceId = 0);
ESRECORD_API float ESRecord_Engine_GetDisplacement(std::int32_t instanceId = 0);

#endif // NEXTCAR_ESRECORD_API_H
