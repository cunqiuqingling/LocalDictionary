#pragma once

// Compatibility include for the feasibility smoke. The security-critical
// implementation is production-owned by MDictCore/ManagedMDictSource.*.
#include "ManagedMDictSource.h"

namespace localdict::prototype {

using ::localdict::MDictDirectoryCapability;
using ::localdict::MDictSourceCancellationCheck;
using ::localdict::MDictSourceCapability;
using ::localdict::MDictSourceHashCancelled;
using ::localdict::MDictSourceHashObservation;
using ::localdict::MDictSourceIdentity;

}  // namespace localdict::prototype
