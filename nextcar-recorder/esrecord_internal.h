#ifndef NEXTCAR_ESRECORD_INTERNAL_H
#define NEXTCAR_ESRECORD_INTERNAL_H

#include "esrecord_api.h"

#include "../include/engine.h"
#include "../include/simulator.h"
#include "../include/transmission.h"
#include "../include/vehicle.h"

#include <array>
#include <mutex>
#include <string>

namespace nextcar::recorder {

struct Instance {
    Simulator *simulator = nullptr;
    Engine *engine = nullptr;
    Transmission *transmission = nullptr;
    Vehicle *vehicle = nullptr;
    ESRecordState state = ESRECORD_STATE_IDLE;
    std::int32_t progress = 0;
    std::string engineName;
    std::mutex mutex;
};

extern std::array<Instance, ESRECORD_MAX_INSTANCES> g_instances;
extern std::mutex g_compileMutex;

Instance *getInstance(std::int32_t instanceId);
void releaseSimulator(Instance &instance);
void releaseCompiledObjects(Instance &instance);
bool initialiseUnlocked(Instance &instance);
double updateUnlocked(Instance &instance, float averageFps);
void persistCompilerLog(std::int32_t instanceId);

} // namespace nextcar::recorder

#endif // NEXTCAR_ESRECORD_INTERNAL_H
