#ifndef NEXTCAR_ESRECORD_INTERNAL_H
#define NEXTCAR_ESRECORD_INTERNAL_H

#include "esrecord_api.h"

#include "../include/engine.h"
#include "../include/simulator.h"
#include "../include/transmission.h"
#include "../include/vehicle.h"

#include <array>
#include <atomic>
#include <mutex>
#include <string>

namespace nextcar::recorder {

struct Instance {
    Simulator *simulator = nullptr;
    Engine *engine = nullptr;
    Transmission *transmission = nullptr;
    Vehicle *vehicle = nullptr;

    // Recording holds mutex for the complete native operation. State, progress
    // and readiness remain atomic so managed status polling never waits for the
    // recording call to finish.
    std::atomic<ESRecordState> state{ESRECORD_STATE_IDLE};
    std::atomic<std::int32_t> progress{0};
    std::atomic<bool> ready{false};

    std::string engineName;
    std::mutex mutex;
};

extern std::array<Instance, ESRECORD_MAX_INSTANCES> g_instances;
extern std::mutex g_compileMutex;

Instance *getInstance(std::int32_t instanceId);
void releaseSimulator(Instance &instance);
void releaseCompiledObjects(Instance &instance);
bool initialiseUnlocked(Instance &instance, std::int32_t instanceId);
inline bool initialiseUnlocked(Instance &instance) {
    const auto instanceId = static_cast<std::int32_t>(
        &instance - g_instances.data());
    return initialiseUnlocked(instance, instanceId);
}
double updateUnlocked(Instance &instance, float averageFps);
void persistCompilerLog(std::int32_t instanceId);
void writeInitialisationLog(std::int32_t instanceId, const std::string &message);

} // namespace nextcar::recorder

#endif // NEXTCAR_ESRECORD_INTERNAL_H
