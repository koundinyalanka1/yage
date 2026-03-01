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
#define RETRO_DEVICE_ID_JOYPAD_MASK   256

/* Platform types */
typedef enum {
    YAGE_PLATFORM_UNKNOWN = 0,
    YAGE_PLATFORM_GB = 1,
    YAGE_PLATFORM_GBC = 2,
    YAGE_PLATFORM_GBA = 3,
    YAGE_PLATFORM_NES = 4,
    YAGE_PLATFORM_SNES = 5,
    YAGE_PLATFORM_SMS = 6,
    YAGE_PLATFORM_GG = 7,
    YAGE_PLATFORM_MD = 8
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
 * Core selection (multi-core support)
 *
 * Call before yage_core_init() to load a different libretro core.
 * path: e.g. "libfceumm_libretro_android.so" (NES) or
 *       "libsnes9x2010_libretro_android.so" (SNES).
 * If not called, defaults to mGBA (libmgba_libretro_android.so).
 * Returns 0 on success.
 */
YAGE_API int yage_core_set_core(const char* path);

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
 * SGB (Super Game Boy) border control
 * enabled: 1 = show SGB borders (256×224), 0 = standard GB (160×144)
 * Call BEFORE loading a ROM for the change to take effect.
 */
YAGE_API void yage_core_set_sgb_borders(YageCore* core, int enabled);

/*
 * Save states
 */
YAGE_API int yage_core_save_state(YageCore* core, int slot);
YAGE_API int yage_core_load_state(YageCore* core, int slot);

/*
 * Rewind (in-memory ring buffer of serialized states)
 */
YAGE_API int yage_core_rewind_init(YageCore* core, int capacity);
YAGE_API void yage_core_rewind_deinit(YageCore* core);
YAGE_API int yage_core_rewind_push(YageCore* core);
YAGE_API int yage_core_rewind_pop(YageCore* core);
YAGE_API int yage_core_rewind_count(YageCore* core);

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

/*
 * Link Cable (Network Multiplayer)
 *
 * Access SIO (serial I/O) registers via the libretro memory map.
 * Supported for GB/GBC (SB=0xFF01, SC=0xFF02) and GBA (SIOCNT/SIODATA).
 */

/* Check if link cable is supported for the current ROM.
 * Returns 1 if I/O memory map is available, 0 otherwise. */
YAGE_API int yage_core_link_is_supported(YageCore* core);

/* Read a byte from an emulated memory address (via memory map).
 * Returns the byte value (0-255) on success, -1 on failure. */
YAGE_API int yage_core_link_read_byte(YageCore* core, uint32_t addr);

/* Write a byte to an emulated memory address (via memory map).
 * Returns 0 on success, -1 on failure. */
YAGE_API int yage_core_link_write_byte(YageCore* core, uint32_t addr, uint8_t value);

/* Get GB/GBC SIO transfer status.
 * Returns: 0 = idle, 1 = transfer pending (master clock), -1 = error/unsupported. */
YAGE_API int yage_core_link_get_transfer_status(YageCore* core);

/* Exchange a byte during a pending SIO transfer:
 * - Writes incoming_byte to SB (received from remote)
 * - Clears the transfer-start flag in SC
 * - Triggers the serial interrupt (IF bit 3)
 * Returns the outgoing byte that was in SB before replacement, or -1 on error. */
YAGE_API int yage_core_link_exchange_data(YageCore* core, uint8_t incoming);

/*
 * Memory Read (for RetroAchievements runtime)
 *
 * Read bytes from the emulated address space using the libretro memory map.
 * address:  emulated address (e.g. 0x02000000 for GBA WRAM)
 * count:    number of bytes to read
 * buffer:   output buffer (must be at least count bytes)
 * Returns number of bytes read, or -1 on error.
 */
YAGE_API int yage_core_read_memory(YageCore* core, uint32_t address,
                                    int32_t count, uint8_t* buffer);

/* Get size of a libretro memory region (0=SaveRAM, 1=RTC, 2=SystemRAM, 3=VRAM). */
YAGE_API int yage_core_get_memory_size(YageCore* core, int32_t region_id);

/*
 * Native Frame Loop (POSIX only — Android, Linux, macOS)
 *
 * Runs the emulation frame loop on a dedicated native thread instead of
 * the Dart/UI thread.  This dramatically improves frame pacing and UI
 * responsiveness, especially at turbo speeds (8× = 480 emulation fps).
 *
 * The thread handles: frame timing (nanosleep), retro_run(), rewind
 * capture, rcheevos per-frame processing, and FPS calculation.
 *
 * A display callback is fired at ~60 Hz to notify Dart when a new
 * frame is ready for rendering.  At turbo speeds the emulation runs
 * faster but the display signal stays at 60 Hz.
 */

/* Callback signature: called on the native thread at ~60 Hz.
 * `frames_run` is the number of emulation frames executed since the
 * last display signal (1 at 1×, ~8 at 8× turbo, etc.). */
typedef void (*yage_frame_callback_t)(int32_t frames_run);

/* Start the native frame loop thread.
 * `callback` is invoked at ~60 Hz from the native thread.
 * Returns 0 on success, -1 if the frame loop is already running or
 * if the platform does not support native threading. */
YAGE_API int yage_frame_loop_start(YageCore* core, yage_frame_callback_t callback);

/* Stop the native frame loop thread (blocks until the thread exits). */
YAGE_API void yage_frame_loop_stop(YageCore* core);

/* Atomically set the emulation speed (100 = 1×, 200 = 2×, 800 = 8×). */
YAGE_API void yage_frame_loop_set_speed(YageCore* core, int32_t speed_percent);

/* Configure rewind capture from the native thread.
 * enabled: 0 = off, 1 = on.  interval: capture every N frames. */
YAGE_API void yage_frame_loop_set_rewind(YageCore* core, int32_t enabled, int32_t interval);

/* Enable/disable rcheevos per-frame processing on the native thread. */
YAGE_API void yage_frame_loop_set_rcheevos(YageCore* core, int32_t enabled);

/* Get FPS × 100 (e.g. 5973 = 59.73 fps).  Safe to call from any thread. */
YAGE_API int32_t yage_frame_loop_get_fps_x100(YageCore* core);

/* Get the display buffer — a snapshot of the last completed frame.
 * Updated at ~60 Hz.  Safe to read from the Dart thread between
 * display callbacks (the native thread will not overwrite until the
 * next display interval). */
YAGE_API uint32_t* yage_frame_loop_get_display_buffer(YageCore* core);

/* Get display dimensions of the last completed frame. */
YAGE_API int32_t yage_frame_loop_get_display_width(YageCore* core);
YAGE_API int32_t yage_frame_loop_get_display_height(YageCore* core);

/* Lock/unlock the display buffer for safe reading from the Dart thread.
 * Hold the lock while reading display buffer contents and dimensions to
 * prevent the frame loop from overwriting mid-read. */
YAGE_API void yage_frame_loop_lock_display(YageCore* core);
YAGE_API void yage_frame_loop_unlock_display(YageCore* core);

/* Check whether the native frame loop is currently running. */
YAGE_API int32_t yage_frame_loop_is_running(YageCore* core);

/*
 * Android Texture Rendering — zero-copy frame delivery
 *
 * On Android, frames can be delivered to a Flutter Texture widget via an
 * ANativeWindow backed by a SurfaceTexture.  This eliminates the
 * decodeImageFromPixels bottleneck (no Dart-side buffer copies, no
 * ui.Image allocations, no GC pressure at 60 fps).
 *
 * Workflow:
 *   1. Kotlin creates a SurfaceTexture via TextureRegistry, wraps it in
 *      a Surface, and passes the Surface to nativeSetSurface() via JNI.
 *   2. The native frame loop (or yage_texture_blit from Dart Timer path)
 *      writes pixels directly to the ANativeWindow at ~60 Hz.
 *   3. Flutter composites the Texture widget — zero Dart-side allocation.
 *
 * On non-Android platforms yage_texture_blit() is a no-op returning -1.
 */

/* Blit the current video buffer to the attached ANativeWindow surface.
 * Call from the Dart Timer frame loop path (the native frame loop
 * blits automatically).
 * Returns 0 on success, -1 if no surface is attached or blit fails. */
YAGE_API int yage_texture_blit(YageCore* core);

/* Check whether a native texture surface is attached.
 * Returns 1 if attached, 0 if not. */
YAGE_API int32_t yage_texture_is_attached(YageCore* core);

#ifdef __cplusplus
}
#endif

#endif /* YAGE_LIBRETRO_H */

