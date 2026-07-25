#include "node_container.h"

#include "ir_context_tree.h"
#include "key_value_lookup.h"
#include "assembly.h"
#include "memory_tracker.h"
#include "node_program.h"
#include "node_output.h"

#include <filesystem>
#include <fstream>
#include <sstream>
#include <typeinfo>

namespace {

void appendContainerTrace(const std::string &message) {
    std::error_code error;
    std::filesystem::create_directories("es", error);
    std::ofstream trace(
        std::filesystem::path("es") / "node_program_trace.log",
        std::ios::out | std::ios::app);
    if (trace.is_open()) {
        trace << message << '\n';
        trace.flush();
    }
}

void appendChildDescription(
    const piranha::NodeContainer *container,
    const int childIndex,
    const int childCount,
    const piranha::Node *node)
{
    std::ostringstream message;
    message
        << "container child before evaluate: container="
        << static_cast<const void *>(container)
        << ", container_name=" << container->getName()
        << ", child=" << childIndex << '/' << childCount
        << ", address=" << static_cast<const void *>(node)
        << ", rtti=" << typeid(*node).name()
        << ", id=" << node->getId()
        << ", name=" << node->getName()
        << ", builtin=" << node->getBuiltinName()
        << ", inputs=" << node->getInputCount()
        << ", outputs=" << node->getOutputCount();
    appendContainerTrace(message.str());

    for (int inputIndex = 0; inputIndex < node->getInputCount(); ++inputIndex) {
        const piranha::Node::NodeInputPort *port = node->getInput(inputIndex);
        const bool hasStorage = port != nullptr && port->input != nullptr;
        const bool hasOutput = hasStorage && *port->input != nullptr;

        std::ostringstream inputMessage;
        inputMessage
            << "container child input: child=" << childIndex
            << ", input=" << inputIndex
            << ", name=" << (port == nullptr ? "<null-port>" : port->name)
            << ", storage=" << hasStorage
            << ", connected_output=" << hasOutput
            << ", dependency="
            << (port == nullptr
                ? nullptr
                : static_cast<const void *>(port->dependency))
            << ", node_input="
            << (port == nullptr
                ? nullptr
                : static_cast<const void *>(port->nodeInput));
        appendContainerTrace(inputMessage.str());
    }
}

} // namespace

piranha::NodeContainer::NodeContainer() {
    m_container = nullptr;
}

piranha::NodeContainer::~NodeContainer() {
    /* void */
}

void piranha::NodeContainer::addNode(Node *node) {
    if (getTopLevel()->findNode(node)) return;

    m_nodes.push_back(node);
    node->setContainer(this);
}

bool piranha::NodeContainer::findNode(Node *node) const {
    const int nodeCount = getNodeCount();
    for (int i = 0; i < nodeCount; ++i) {
        if (m_nodes[i] == node) return true;
    }

    const int childCount = getChildCount();
    for (int i = 0; i < childCount; ++i) {
        if (m_children[i]->findNode(node)) return true;
    }

    return false;
}

bool piranha::NodeContainer::findContainer(Node *node) const {
    if (node == this) return true;

    int childCount = getChildCount();
    for (int i = 0; i < childCount; ++i) {
        if (m_children[i]->findContainer(node)) return true;
    }

    return false;
}

void piranha::NodeContainer::addChild(NodeContainer *container) {
    m_children.push_back(container);
}

piranha::NodeContainer *piranha::NodeContainer::getTopLevel() {
    if (m_container != nullptr) return m_container->getTopLevel();
    else return this;
}

void piranha::NodeContainer::addContainerInput(
    const std::string &name,
    bool modifiesInput,
    bool enableInput)
{
    pNodeInput *connectionPoint = TRACK(new pNodeInput);
    m_connections.push_back(connectionPoint);

    registerInput(connectionPoint, name, modifiesInput, enableInput);
}

void piranha::NodeContainer::addContainerOutput(
    pNodeInput output,
    Node *node,
    const std::string &name,
    bool primary)
{
    pNodeInput *connectionPoint = TRACK(new pNodeInput);
    m_connections.push_back(connectionPoint);

    *connectionPoint = output;

    registerOutputReference(connectionPoint, name, node);

    if (primary) {
        setPrimaryOutput(name);
    }
}

void piranha::NodeContainer::writeAssembly(
    std::fstream &file,
    Assembly *assembly,
    int indent) const
{
    std::string prefixIndent = "";
    for (int i = 0; i < indent; ++i) prefixIndent += "  ";

    const std::string name = getName();
    file << prefixIndent;
    if (name.empty()) file << "{" << std::endl;
    else file << name << " {" << std::endl;

    const int nodeCount = getNodeCount();
    for (int i = 0; i < nodeCount; i++) {
        Node *node = getNode(i);
        node->writeAssembly(file, assembly, indent + 1);
    }

    file << prefixIndent << "}" << std::endl;
}

void piranha::NodeContainer::prune() {
    const int childCount = getChildCount();
    for (int i = 0; i < childCount; ++i) {
        m_children[i]->prune();
    }

    const int nodeCount = getNodeCount();
    int newNodeCount = 0;
    for (int i = 0; i < nodeCount; ++i) {
        const bool optimizedOut =
            m_nodes[i]->isOptimizedOut() || m_nodes[i]->isDead();
        if (optimizedOut) {
            m_nodes[i]->destroy();

            if (m_nodes[i]->getMemorySpace() == Node::MemorySpace::PiranhaInternal) {
                delete FTRACK(m_nodes[i]);
            }
            else if (m_nodes[i]->getMemorySpace() == Node::MemorySpace::ClientExternal) {
                m_program->getNodeAllocator()->free(m_nodes[i]);
            }
        }
        else {
            m_nodes[newNodeCount++] = m_nodes[i];
        }
    }

    m_nodes.resize(newNodeCount);
}

void piranha::NodeContainer::_initialize() {
    const int nodeCount = getNodeCount();
    for (int i = 0; i < nodeCount; ++i) {
        m_nodes[i]->initialize();
    }
}

void piranha::NodeContainer::_evaluate() {
    const int nodeCount = getNodeCount();
    {
        std::ostringstream message;
        message
            << "container evaluate begin: address="
            << static_cast<const void *>(this)
            << ", name=" << getName()
            << ", children=" << nodeCount;
        appendContainerTrace(message.str());
    }

    for (int i = 0; i < nodeCount; ++i) {
        Node *node = m_nodes[i];
        appendChildDescription(this, i, nodeCount, node);
        const bool result = node->evaluate();
        appendContainerTrace(
            "container child after evaluate: child=" + std::to_string(i) +
            ", result=" + std::to_string(result));
        if (!result) {
            m_runtimeError = true;
            return;
        }
    }

    appendContainerTrace("container evaluate complete");
}

void piranha::NodeContainer::_destroy() {
    Node::_destroy();

    for (pNodeInput *p : m_connections) {
        delete FTRACK(p);
    }
}

piranha::Node *piranha::NodeContainer::_optimize(NodeAllocator *nodeAllocator) {
    int nodeCount = getNodeCount();
    for (int i = 0; i < nodeCount; ++i) {
        Node *optimizedNode = m_nodes[i]->optimize(nodeAllocator);
        if (optimizedNode != m_nodes[i] && optimizedNode != nullptr) {
            m_nodes.insert(m_nodes.begin() + i, optimizedNode);
            m_program->addNode(optimizedNode);

            ++nodeCount;
            ++i;
        }
    }

    bool isActionless = true;
    for (int i = 0; i < nodeCount; ++i) {
        const bool optimizedOut =
            m_nodes[i]->isOptimizedOut() || m_nodes[i]->isDead();
        if (!optimizedOut) {
            if (!m_nodes[i]->hasFlag(Node::META_ACTIONLESS)) {
                isActionless = false;
                break;
            }
        }
    }

    if (isActionless) {
        addFlag(Node::META_ACTIONLESS);
    }

    return this;
}
