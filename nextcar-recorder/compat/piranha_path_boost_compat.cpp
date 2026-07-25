// Compatibility replacement for piranha commit
// 432f0b122bb1663b686c553c7e7269300afac3bc, src/path.cpp.
//
// The pinned source calls boost::filesystem::path::is_complete(), which is no
// longer available in current Boost. The containing method is named
// Path::isAbsolute(), so is_absolute() is the direct semantic replacement.
// All other behavior is kept identical to the pinned source.

#include "path.h"
#include "memory_tracker.h"

#include <boost/filesystem.hpp>

piranha::Path::Path(const std::string &path) {
    m_path = nullptr;
    setPath(path);
}

piranha::Path::Path(const char *path) {
    m_path = nullptr;
    setPath(std::string(path));
}

piranha::Path::Path(const Path &path) {
    m_path = TRACK(new boost::filesystem::path);
    *m_path = path.getBoostPath();
}

piranha::Path::Path() {
    m_path = nullptr;
}

piranha::Path::Path(const boost::filesystem::path &path) {
    m_path = TRACK(new boost::filesystem::path);
    *m_path = path;
}

piranha::Path::~Path() {
    if (m_path != nullptr) delete FTRACK(m_path);
}

std::string piranha::Path::toString() const {
    return m_path->string();
}

void piranha::Path::setPath(const std::string &path) {
    if (m_path != nullptr) delete FTRACK(m_path);

    m_path = TRACK(new boost::filesystem::path(path));
}

bool piranha::Path::operator==(const Path &path) const {
    return boost::filesystem::equivalent(this->getBoostPath(), path.getBoostPath());
}

piranha::Path piranha::Path::append(const Path &path) const {
    return Path(getBoostPath() / path.getBoostPath());
}

void piranha::Path::getParentPath(Path *path) const {
    path->m_path = TRACK(new boost::filesystem::path);
    *path->m_path = m_path->parent_path();
}

const piranha::Path &piranha::Path::operator=(const Path &b) {
    if (m_path != nullptr) delete FTRACK(m_path);

    m_path = TRACK(new boost::filesystem::path);
    *m_path = b.getBoostPath();

    return *this;
}

std::string piranha::Path::getExtension() const {
    return m_path->extension().string();
}

std::string piranha::Path::getStem() const {
    return m_path->stem().string();
}

bool piranha::Path::isAbsolute() const {
    return m_path->is_absolute();
}

bool piranha::Path::exists() const {
    return boost::filesystem::exists(*m_path);
}
