/*
 * YAGE Libretro Wrapper
 * 
 * This wraps the libretro API used by mGBA-libretro core
 */

#ifndef YAGE_LIBRETRO_H
#define YAGE_LIBRETRO_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

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

/* Libretro pixel formats */
#define RETRO_PIXEL_FORMAT_0RGB1555 0
#define RETRO_PIXEL_FORMAT_XRGB8888 1
#define RETRO_PIXEL_FORMAT_RGB565   2

/* Libretro device types */
#define RETRO_DEVICE_JOYPAD 1

/* Libretro joypad buttons */
#define RETRO_DEVICE_ID_JOYPAD_B      0
#define RETRO_DEVICE_ID_JOYPAD_Y      1
#define RETRO_DEVICE_ID_JOYPAD_SELECT 2
#define RETRO_DEVICE_ID_JOYPAD_START  3
#define RETRO_DEVICE_ID_JOYPAD_UP     4
#define RETRO_DEVICE_ID_JOYPAD_DOWN   5
#define RETRO_DEVICE_ID_JOYPAD_LEFT   6
#define RETRO_DEVICE_ID_JOYPAD_RIGHT  7
#define RETRO_DEVICE_ID_JOYPAD_A      8
#define RETRO_DEVICE_ID_JOYPAD_X      9
#define RETRO_DEVICE_ID_JOYPAD_L      10
#define RETRO_DEVICE_ID_JOYPAD_R      11

/* Platform types */
typedef enum {
    YAGE_PLATFORM_UNKNOWN = 0,
    YAGE_PLATFORM_GB = 1,
    YAGE_PLATFORM_GBC = 2,
    YAGE_PLATFORM_GBA = 3
} YagePlatform;

/* Opaque handle */
typedef struct YageCore YageCore;

/*
 * Core lifecycle
 */
YAGE_API YageCore* yage_core_create(void);
YAGE_API int yage_core_init(YageCore* core);
YAGE_API void yage_core_destroy(YageCore* core);

/*
 * ROM loading
 */
YAGE_API int yage_core_load_rom(YageCore* core, const char* path);
YAGE_API int yage_core_load_bios(YageCore* core, const char* path);
YAGE_API void yage_core_set_save_dir(YageCore* core, const char* path);

/*
 * Emulation
 */
YAGE_API void yage_core_reset(YageCore* core);
YAGE_API void yage_core_run_frame(YageCore* core);
YAGE_API void yage_core_set_keys(YageCore* core, uint32_t keys);

/*
 * Video
 */
YAGE_API uint32_t* yage_core_get_video_buffer(YageCore* core);
YAGE_API int yage_core_get_width(YageCore* core);
YAGE_API int yage_core_get_height(YageCore* core);

/*
 * Audio
 */
YAGE_API int16_t* yage_core_get_audio_buffer(YageCore* core);
YAGE_API int yage_core_get_audio_samples(YageCore* core);
YAGE_API void yage_core_set_volume(YageCore* core, float volume);
YAGE_API void yage_core_set_audio_enabled(YageCore* core, int enabled);

/*
 * Color palette (for original GB)
 * palette_index: -1 = disabled (original colors), 0+ = enabled
 * color0..color3: ARGB colors [lightest, light, dark, darkest]
 */
YAGE_API void yage_core_set_color_palette(YageCore* core, int palette_index,
                                           uint32_t color0, uint32_t color1,
                                           uint32_t color2, uint32_t color3);

/*
 * Save states
 */
YAGE_API int yage_core_save_state(YageCore* core, int slot);
YAGE_API int yage_core_load_state(YageCore* core, int slot);

/*
 * Battery/SRAM saves (.sav files)
 */
YAGE_API int yage_core_get_sram_size(YageCore* core);
YAGE_API uint8_t* yage_core_get_sram_data(YageCore* core);
YAGE_API int yage_core_save_sram(YageCore* core, const char* path);
YAGE_API int yage_core_load_sram(YageCore* core, const char* path);

/*
 * Info
 */
YAGE_API int yage_core_get_platform(YageCore* core);

#ifdef __cplusplus
}
#endif

#endif /* YAGE_LIBRETRO_H */

