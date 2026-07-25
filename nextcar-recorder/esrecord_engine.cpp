#include "esrecord_internal.h"
#include "wav_reader.h"

#include "../include/impulse_response.h"
#include "../include/synthesizer.h"
#include "../include/units.h"
#include "../scripting/include/compiler.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <limits>

namespace nextcar::recorder {

std::array<Instance, ESRECORD_MAX_INSTANCES> g_instances;
std::mutex g_compileMutex;

Instance *getInstance(const std::int32_t instanceId) {
    if (instanceId < 0 || instanceId >= ESRECORD_MAX_INSTANCES) {
        return nullptr;
    }

    return &g_instances[static_cast<std::size_t>(instanceId)];
}

void releaseSimulator(Instance &instance) {
    instance.ready = false;

    if (instance.simulator != nullptr) {
        instance.simulator->releaseSimulation();
        delete instance.simulator;
        instance.simulator = nullptr;
    }
}

void releaseCompiledObjects(Instance &instance) {
    releaseSimulator(instance);

    if (instance.vehicle != nullptr) {
        delete instance.vehicle;
        instance.vehicle = nullptr;
    }

    if (instance.transmission != nullptr) {
        delete instance.transmission;
        instance.transmission = nullptr;
    }

    if (instance.engine != nullptr) {
        instance.engine->destroy();
        delete instance.engine;
        instance.engine = nullptr;
    }

    instance.engineName.clear();
}

void persistCompilerLog(const std::int32_t instanceId) {
    namespace fs = std::filesystem;

    std::error_code error;
    fs::create_directories("es", error);

    const fs::path source = "error_log.log";
    const fs::path destination =
        fs::path("es") / ("error_log" + std::to_string(instanceId) + ".log");

    if (!fs::exists(source, error)) {
        return;
    }

    fs::copy_file(source, destination, fs::copy_options::overwrite_existing, error);
    if (!error) {
        fs::remove(source, error);
    }
}

bool initialiseUnlocked(Instance &instance) {
    releaseSimulator(instance);

    if (instance.engine == nullptr ||
        instance.vehicle == nullptr ||
        instance.transmission == nullptr)
    {
        return false;
    }

    instance.simulator =
        instance.engine->createSimulator(instance.vehicle, instance.transmission);
    if (instance.simulator == nullptr) {
        return false;
    }

    instance.engine->calculateDisplacement();

    const double simulationFrequency =
        instance.engine->getSimulationFrequency();
    if (!std::isfinite(simulationFrequency) ||
        simulationFrequency < 1.0 ||
        simulationFrequency > static_cast<double>(std::numeric_limits<int>::max()))
    {
        releaseSimulator(instance);
        return false;
    }
    instance.simulator->setSimulationFrequency(
        static_cast<int>(simulationFrequency));

    Synthesizer::AudioParameters audioParameters =
        instance.simulator->synthesizer().getAudioParameters();
    audioParameters.convolution =
        static_cast<float>(instance.engine->getInitialConvolution());
    audioParameters.inputSampleNoise =
        static_cast<float>(instance.engine->getInitialJitter());
    audioParameters.airNoise =
        static_cast<float>(instance.engine->getInitialNoise());
    audioParameters.dF_F_mix =
        static_cast<float>(instance.engine->getInitialHighFrequencyGain());
    instance.simulator->synthesizer().setAudioParameters(audioParameters);

    for (int i = 0; i < instance.engine->getExhaustSystemCount(); ++i) {
        ImpulseResponse *response =
            instance.engine->getExhaustSystem(i)->getImpulseResponse();
        if (response == nullptr) {
            continue;
        }

        Pcm16Wave wave;
        if (!readMonoPcm16Wave(response->getFilename(), wave) ||
            wave.sampleRate != 44100 ||
            wave.samples.size() > static_cast<std::size_t>(
                std::numeric_limits<int>::max()))
        {
            releaseSimulator(instance);
            return false;
        }

        instance.simulator->synthesizer().initializeImpulseResponse(
            wave.samples.data(),
            static_cast<int>(wave.samples.size()),
            static_cast<float>(response->getVolume()),
            i);
    }

    instance.simulator->startAudioRenderingThread();
    instance.ready = true;
    return true;
}

double updateUnlocked(Instance &instance, const float averageFps) {
    if (instance.simulator == nullptr) {
        return 0.0;
    }

    const double averageFrameRate =
        std::clamp(static_cast<double>(averageFps), 30.0, 1000.0);
    instance.simulator->startFrame(1.0 / averageFrameRate);

    const auto started = std::chrono::steady_clock::now();
    const int iterationCount = instance.simulator->getFrameIterationCount();
    while (instance.simulator->simulateStep()) {
        // Complete the deterministic frame without UI or real-time pacing.
    }
    const auto finished = std::chrono::steady_clock::now();

    instance.simulator->endFrame();
    if (iterationCount <= 0) {
        return 0.0;
    }

    const auto duration = finished - started;
    return (duration.count() / 1E9) / iterationCount;
}

} // namespace nextcar::recorder

ESRECORD_API std::int32_t ESRecord_Compile(
    const std::int32_t instanceId,
    const char *path)
{
    using namespace nextcar::recorder;

    Instance *instance = getInstance(instanceId);
    if (instance == nullptr || path == nullptr || path[0] == '\0') {
        return 0;
    }

    std::lock_guard<std::mutex> instanceLock(instance->mutex);
    std::lock_guard<std::mutex> compilerLock(g_compileMutex);
    instance->state = ESRECORD_STATE_COMPILING;
    instance->progress = 0;

    Engine *engine = nullptr;
    Vehicle *vehicle = nullptr;
    Transmission *transmission = nullptr;

    es_script::Compiler compiler;
    compiler.initialize();
    const bool compiled = compiler.compile(path);
    persistCompilerLog(instanceId);

    if (compiled) {
        const es_script::Compiler::Output output = compiler.execute();
        engine = output.engine;
        vehicle = output.vehicle;
        transmission = output.transmission;
    }

    compiler.destroy();

    if (!compiled || engine == nullptr) {
        instance->state = ESRECORD_STATE_IDLE;
        return 0;
    }

    if (vehicle == nullptr) {
        Vehicle::Parameters parameters;
        parameters.mass = units::mass(1597, units::kg);
        parameters.diffRatio = 3.42;
        parameters.tireRadius = units::distance(10, units::inch);
        parameters.dragCoefficient = 0.25;
        parameters.crossSectionArea =
            units::distance(6.0, units::foot) *
            units::distance(6.0, units::foot);
        parameters.rollingResistance = 2000.0;

        vehicle = new Vehicle;
        vehicle->initialize(parameters);
    }

    if (transmission == nullptr) {
        static const double gearRatios[] = {
            2.97, 2.07, 1.43, 1.00, 0.84, 0.56
        };

        Transmission::Parameters parameters;
        parameters.GearCount = 6;
        parameters.GearRatios = gearRatios;
        parameters.MaxClutchTorque = units::torque(1000.0, units::ft_lb);

        transmission = new Transmission;
        transmission->initialize(parameters);
    }

    releaseCompiledObjects(*instance);
    instance->engine = engine;
    instance->vehicle = vehicle;
    instance->transmission = transmission;
    instance->engineName = engine->getName();

    const bool initialised = initialiseUnlocked(*instance);
    instance->state = ESRECORD_STATE_IDLE;
    return initialised ? 1 : 0;
}

ESRECORD_API std::int32_t ESRecord_Initialise(const std::int32_t instanceId) {
    using namespace nextcar::recorder;

    Instance *instance = getInstance(instanceId);
    if (instance == nullptr) {
        return 0;
    }

    std::lock_guard<std::mutex> lock(instance->mutex);
    return initialiseUnlocked(*instance) ? 1 : 0;
}

ESRECORD_API double ESRecord_Update(
    const std::int32_t instanceId,
    const float averageFps)
{
    using namespace nextcar::recorder;

    Instance *instance = getInstance(instanceId);
    if (instance == nullptr) {
        return 0.0;
    }

    std::lock_guard<std::mutex> lock(instance->mutex);
    return updateUnlocked(*instance, averageFps);
}

ESRECORD_API std::int32_t ESRecord_GetSimState(const std::int32_t instanceId) {
    using namespace nextcar::recorder;

    Instance *instance = getInstance(instanceId);
    return instance != nullptr && instance->ready.load() ? 1 : 0;
}

ESRECORD_API ESRecordState ESRecord_GetState(
    const std::int32_t instanceId,
    std::int32_t &progress)
{
    using namespace nextcar::recorder;

    Instance *instance = getInstance(instanceId);
    if (instance == nullptr) {
        progress = 0;
        return ESRECORD_STATE_IDLE;
    }

    progress = instance->progress.load();
    return instance->state.load();
}

ESRECORD_API std::int32_t ESRecord_GetVersion() {
    return ESRECORD_ABI_VERSION;
}

ESRECORD_API std::int32_t ESRecord_GetMaxInstances() {
    return ESRECORD_MAX_INSTANCES;
}

ESRECORD_API const char *ESRecord_GetEngineSimSourceRevision() {
    return ES_ENGINE_SIM_SOURCE_REVISION;
}

ESRECORD_API const char *ESRecord_GetCompatibilityTarget() {
    return ES_ENGINE_SIM_COMPATIBILITY_TARGET;
}

ESRECORD_API const char *ESRecord_Engine_GetName(const std::int32_t instanceId) {
    using namespace nextcar::recorder;

    Instance *instance = getInstance(instanceId);
    if (instance == nullptr) {
        return "";
    }

    std::lock_guard<std::mutex> lock(instance->mutex);
    if (instance->engine == nullptr) {
        instance->engineName.clear();
    }
    else {
        instance->engineName = instance->engine->getName();
    }

    return instance->engineName.c_str();
}

ESRECORD_API float ESRecord_Engine_GetRedline(const std::int32_t instanceId) {
    using namespace nextcar::recorder;

    Instance *instance = getInstance(instanceId);
    if (instance == nullptr) {
        return -1.0f;
    }

    std::lock_guard<std::mutex> lock(instance->mutex);
    return instance->engine == nullptr
        ? -1.0f
        : static_cast<float>(units::toRpm(instance->engine->getRedline()));
}

ESRECORD_API float ESRecord_Engine_GetDisplacement(const std::int32_t instanceId) {
    using namespace nextcar::recorder;

    Instance *instance = getInstance(instanceId);
    if (instance == nullptr) {
        return -1.0f;
    }

    std::lock_guard<std::mutex> lock(instance->mutex);
    return instance->engine == nullptr
        ? -1.0f
        : static_cast<float>(units::convert(
            instance->engine->getDisplacement(), units::L));
}
