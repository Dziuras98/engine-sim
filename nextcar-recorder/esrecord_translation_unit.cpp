// The frozen engine-sim units/constants headers define externally linked
// constexpr values in headers. Compiling multiple recorder translation units
// would therefore violate the ODR under MSVC. Keep the recorder implementation
// in one translation unit until those shared headers are modernized separately.

// The managed recorder contract creates/resets an instance before compiling an
// engine script. The first source-port implementation incorrectly reused the
// post-compile simulator initialiser for this export. Rename that implementation
// internally and expose the slot-reset contract below without introducing a
// second translation unit.
#define ESRecord_Initialise ESRecord_InitialiseCompiledState
#include "esrecord_engine.cpp"
#undef ESRecord_Initialise

#include "esrecord_record.cpp"

ESRECORD_API std::int32_t ESRecord_Initialise(const std::int32_t instanceId) {
    using namespace nextcar::recorder;

    Instance *instance = getInstance(instanceId);
    if (instance == nullptr) {
        return 0;
    }

    std::lock_guard<std::mutex> lock(instance->mutex);
    releaseCompiledObjects(*instance);
    instance->state = ESRECORD_STATE_IDLE;
    instance->progress = 0;
    instance->ready = false;
    return 1;
}
