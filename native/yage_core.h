/*
 * YAGE Core - mGBA Wrapper Library
 * 
 * This header defines the C interface for the YAGE emulator core,
 * which wraps the mGBA library for use with Flutter FFI.
 */

#ifndef YAGE_CORE_H
#define YAGE_CORE_H

#include <stdint.h>

#ifdef _WIN32
    #ifdef YAGE_EXPORTS
        #define YAGE_API __declspec(dllexport)
    #else
        #define YAGE_API __declspec(dllimport)
    #endif
#else
    #define YAGE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to the emulator core */
typedef struct YageCore YageCore;

/* Platform types */
typedef enum {
    YAGE_PLATFORM_UNKNOWN = 0,
    YAGE_PLATFORM_GB = 1,
    YAGE_PLATFORM_GBC = 2,
    YAGE_PLATFORM_GBA = 3
} YagePlatform;

/* Key codes matching GBA hardware */
typedef enum {
    YAGE_KEY_A = 1 << 0,
    YAGE_KEY_B = 1 << 1,
    YAGE_KEY_SELECT = 1 << 2,
    YAGE_KEY_START = 1 << 3,
    YAGE_KEY_RIGHT = 1 << 4,
    YAGE_KEY_LEFT = 1 << 5,
    YAGE_KEY_UP = 1 << 6,
    YAGE_KEY_DOWN = 1 << 7,
    YAGE_KEY_R = 1 << 8,
    YAGE_KEY_L = 1 << 9
} YageKey;

/*
 * Core lifecycle functions
 */

/* Create a new emulator core instance */
YAGE_API YageCore* yage_core_create(void);

/* Initialize the emulator core */
YAGE_API int yage_core_init(YageCore* core);

/* Destroy and free the emulator core */
YAGE_API void yage_core_destroy(YageCore* core);

/*
 * ROM and BIOS loading
 */

/* Load a ROM file */
YAGE_API int yage_core_load_rom(YageCore* core, const char* path);

/* Load a BIOS file */
YAGE_API int yage_core_load_bios(YageCore* core, const char* path);

/* Set the save directory */
YAGE_API void yage_core_set_save_dir(YageCore* core, const char* path);

/*
 * Emulation control
 */

/* Reset the emulator */
YAGE_API void yage_core_reset(YageCore* core);

/* Run one frame of emulation */
YAGE_API void yage_core_run_frame(YageCore* core);

/* Set key states (bitmask of YageKey values) */
YAGE_API void yage_core_set_keys(YageCore* core, uint32_t keys);

/*
 * Video output
 */

/* Get the video buffer (XRGB8888 format) */
YAGE_API uint32_t* yage_core_get_video_buffer(YageCore* core);

/* Get the screen width */
YAGE_API int yage_core_get_width(YageCore* core);

/* Get the screen height */
YAGE_API int yage_core_get_height(YageCore* core);

/*
 * Audio output
 */

/* Get the audio buffer (stereo 16-bit samples) */
YAGE_API int16_t* yage_core_get_audio_buffer(YageCore* core);

/* Get the number of audio samples available */
YAGE_API int yage_core_get_audio_samples(YageCore* core);

/*
 * Save states
 */

/* Save state to slot (0-9) */
YAGE_API int yage_core_save_state(YageCore* core, int slot);

/* Load state from slot (0-9) */
YAGE_API int yage_core_load_state(YageCore* core, int slot);

/*
 * Platform info
 */

/* Get the detected platform */
YAGE_API int yage_core_get_platform(YageCore* core);

#ifdef __cplusplus
}
#endif

#endif /* YAGE_CORE_H */

