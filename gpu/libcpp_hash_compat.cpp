//
// Copyright (C) 2026 The Android Open Source Project
//
// SPDX-License-Identifier: Apache-2.0
//

// std::__1::__hash_memory() is the libc++ helper the installed ROM's
// libgralloccore.so (and libui.so) were linked against; Android 16's libc++
// predates it. Adreno's EGL platform subdriver loads those vendor libraries
// during eglInitialize(), so without this symbol EGL reports
// EGL_NOT_INITIALIZED and the UI falls back to the software renderer.
//
// Any deterministic string hash is sufficient here: it only decides the bucket
// distribution of unordered containers, never equality.

namespace std {
namespace __1 {

unsigned long __hash_memory(const void* data, unsigned long size) {
  const unsigned char* bytes = static_cast<const unsigned char*>(data);
  unsigned long long hash = 1469598103934665603ULL;
  for (unsigned long i = 0; i < size; ++i) {
    hash ^= bytes[i];
    hash *= 1099511628211ULL;
  }
  return static_cast<unsigned long>(hash);
}

}  // namespace __1
}  // namespace std
