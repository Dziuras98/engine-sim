#include "../include/compiler.h"

#include <fstream>

namespace {

void appendCompilerTrace(const char *message) {
    std::ofstream trace("es/compiler_trace.log", std::ios::out | std::ios::app);
    if (trace.is_open()) {
        trace << message << '\n';
    }
}

void appendCompilerOutputTrace(
    const char *stage,
    const es_script::Compiler::Output &output,
    const bool executeResult)
{
    std::ofstream trace("es/compiler_trace.log", std::ios::out | std::ios::app);
    if (trace.is_open()) {
        trace << stage
            << ": execute_result=" << executeResult
            << ", engine=" << static_cast<const void *>(output.engine)
            << ", vehicle=" << static_cast<const void *>(output.vehicle)
            << ", transmission=" << static_cast<const void *>(output.transmission)
            << ", functions=" << output.functions.size()
            << '\n';
    }
}

} // namespace

es_script::Compiler::Output *es_script::Compiler::s_output = nullptr;

es_script::Compiler::Compiler() {
    m_compiler = nullptr;
}

es_script::Compiler::~Compiler() {
    assert(m_compiler == nullptr);
}

es_script::Compiler::Output *es_script::Compiler::output() {
    if (s_output == nullptr) {
        s_output = new Output;
    }

    return s_output;
}

void es_script::Compiler::initialize() {
    appendCompilerTrace("initialize: begin");
    m_compiler = new piranha::Compiler(&m_rules);
    m_compiler->setFileExtension(".mr");

    m_compiler->addSearchPath("../../es/");
    m_compiler->addSearchPath("../es/");
    m_compiler->addSearchPath("es/");
    m_compiler->addSearchPath("es/es/");

    m_rules.initialize();
    appendCompilerTrace("initialize: complete");
}

bool es_script::Compiler::compile(const piranha::IrPath &path) {
    appendCompilerTrace("compile: begin");
    bool successful = false;

    std::ofstream file("error_log.log", std::ios::out);
    piranha::IrCompilationUnit *unit = m_compiler->compile(path);
    if (unit == nullptr) {
        file << "Can't find file: " << path.toString() << "\n";
        appendCompilerTrace("compile: unit not found");
    }
    else {
        const piranha::ErrorList *errors = m_compiler->getErrorList();
        if (errors->getErrorCount() == 0) {
            appendCompilerTrace("compile: build program begin");
            unit->build(&m_program);
            appendCompilerTrace("compile: program initialize begin");
            m_program.initialize();
            appendCompilerTrace("compile: program initialize complete");

            successful = true;
        }
        else {
            for (int i = 0; i < errors->getErrorCount(); ++i) {
                printError(errors->getCompilationError(i), file);
            }
            appendCompilerTrace("compile: compiler errors recorded");
        }
    }

    file.close();
    appendCompilerTrace(successful ? "compile: success" : "compile: failure");

    return successful;
}

es_script::Compiler::Output es_script::Compiler::execute() {
    appendCompilerTrace("execute: begin");
    Output *currentOutput = output();
    *currentOutput = Output{};
    appendCompilerTrace("execute: output reset");

    // Preserve the historical interpreter contract: action nodes may populate
    // the output even when NodeProgram::execute() reports false for a void/root
    // program. Returning an empty object here discards valid side effects from
    // set_engine, set_vehicle and set_transmission.
    const bool result = m_program.execute();
    appendCompilerOutputTrace("execute: complete", *currentOutput, result);
    return *currentOutput;
}

void es_script::Compiler::destroy() {
    appendCompilerTrace("destroy: begin");
    m_program.free();
    appendCompilerTrace("destroy: program free complete");
    m_compiler->free();
    appendCompilerTrace("destroy: compiler free complete");

    delete m_compiler;
    m_compiler = nullptr;
    appendCompilerTrace("destroy: complete");
}

void es_script::Compiler::printError(
    const piranha::CompilationError *err,
    std::ofstream &file) const
{
    const piranha::ErrorCode_struct &errorCode = err->getErrorCode();
    file << err->getCompilationUnit()->getPath().getStem()
        << "(" << err->getErrorLocation()->lineStart << "): error "
        << errorCode.stage << errorCode.code << ": " << errorCode.info << std::endl;

    piranha::IrContextTree *context = err->getInstantiation();
    while (context != nullptr) {
        piranha::IrNode *instance = context->getContext();
        if (instance != nullptr) {
            const std::string instanceName = instance->getName();
            const std::string definitionName = (instance->getDefinition() != nullptr)
                ? instance->getDefinition()->getName()
                : "<Type Error>";
            const std::string formattedName = (instanceName.empty())
                ? "<unnamed> " + definitionName
                : instanceName + " " + definitionName;

            file
                << "       While instantiating: "
                << instance->getParentUnit()->getPath().getStem()
                << "(" << instance->getSummaryToken()->lineStart << "): "
                << formattedName << std::endl;
        }

        context = context->getParent();
    }
}
