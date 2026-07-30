#pragma once

#include "../MDictCore/FDBoundSQLiteReadOnlyVFS.h"

// Compatibility-only names for the original feasibility smoke.  Production and
// prototype callers compile the same implementation in MDictCore.
namespace localdict::prototype {
using fdsqlite::EnsureFDBoundReadOnlyVFSRegistered;
using fdsqlite::FDBoundDirectoryCapability;
using fdsqlite::FDBoundFileIdentity;
using fdsqlite::FDBoundReadOnlyFileCapability;
using fdsqlite::FDBoundReadOnlyVFSName;
using fdsqlite::FDBoundReadOnlyVFSStatistics;
using fdsqlite::FDBoundRegisteredToken;
using fdsqlite::FDBoundVFSStatistics;
using fdsqlite::InvalidateFDBoundRegisteredDescriptorForTesting;
using fdsqlite::ShutdownFDBoundReadOnlyVFS;
}  // namespace localdict::prototype
