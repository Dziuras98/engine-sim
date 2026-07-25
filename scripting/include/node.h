#ifndef ATG_ENGINE_SIM_NODE_H
#define ATG_ENGINE_SIM_NODE_H

#include "piranha.h"

#include <map>
#include <string>

namespace es_script {
    class Node : public piranha::Node {
    protected:
        struct InputTarget {
            enum class Type {
                Object,
                Atomic
            };

            piranha::pNodeInput *input = nullptr;
            void *memoryTarget = nullptr;
            Type type = Type::Atomic;
            bool optional = false;
        };

    public:
        Node() {
            /* void */
        }

        virtual ~Node() {
            for (auto i : m_inputMap) {
                delete i.second.input;
            }
        }

        template <typename T_Out>
        T_Out readAtomicInput(const std::string &name) {
            T_Out out;
            (*m_inputMap[name].input)->fullCompute(&out);

            return out;
        }

        void readAllInputs() {
            for (auto i : m_inputMap) {
                const InputTarget &target = i.second;
                const piranha::pNodeInput input = *target.input;
                if (input == nullptr && target.optional) {
                    // Preserve the value already stored in memoryTarget.
                    continue;
                }

                if (target.type == InputTarget::Type::Atomic
                    || target.type == InputTarget::Type::Object)
                {
                    input->fullCompute(target.memoryTarget);
                }
            }
        }

        void addInput(
            const std::string &name,
            void *target,
            InputTarget::Type type = InputTarget::Type::Atomic)
        {
            m_inputMap[name] = {
                new piranha::pNodeInput,
                target,
                type,
                false
            };
        }

        void addOptionalInput(
            const std::string &name,
            void *target,
            InputTarget::Type type = InputTarget::Type::Atomic)
        {
            m_inputMap[name] = {
                new piranha::pNodeInput,
                target,
                type,
                true
            };
        }

        virtual void registerInputs() {
            for (auto i : m_inputMap) {
                registerInput(i.second.input, i.first);
            }
        }

    private:
        std::map<std::string, InputTarget> m_inputMap;
    };

} /* namespace es_script */

#endif /* ATG_ENGINE_SIM_NODE_H */
