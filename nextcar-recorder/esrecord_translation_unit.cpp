// The frozen engine-sim units/constants headers define externally linked
// constexpr values in headers. Compiling multiple recorder translation units
// would therefore violate the ODR under MSVC. Keep the recorder implementation
// in one translation unit until those shared headers are modernized separately.
#include "esrecord_engine.cpp"
#include "esrecord_record.cpp"
