/* MicBridge build configuration for the vendored libsamplerate (replaces the CMake-generated config.h). */
#ifndef MICBRIDGE_SAMPLERATE_CONFIG_H
#define MICBRIDGE_SAMPLERATE_CONFIG_H

#include <stdbool.h>

#define PACKAGE "libsamplerate"
#define VERSION "0.2.2"

/* Only the two converters MicBridge uses. The best-quality table (9 MB of source) is not vendored. */
#define ENABLE_SINC_FAST_CONVERTER 1
#define ENABLE_SINC_MEDIUM_CONVERTER 1

/* Used only by the int/short conversion helpers, which MicBridge does not call. */
#define CPU_CLIPS_POSITIVE 0
#define CPU_CLIPS_NEGATIVE 0

#endif
