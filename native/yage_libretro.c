/*
 * YAGE Libretro Wrapper Implementation
 * 
 * Wraps libretro mGBA core for use with Flutter FFI
 */

#include "yage_libretro.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifndef _WIN32
#include <stdatomic.h>
#endif

#ifdef _WIN32
#include <windows.h>
#define LOAD_LIBRARY(path) LoadLibraryA(path)
#define GET_PROC(lib, name) GetProcAddress(lib, name)
#define FREE_LIBRARY(lib) FreeLibrary(lib)
typedef HMODULE LibHandle;
#else
#include <dlfcn.h>
#define LOAD_LIBRARY(path) dlopen(path, RTLD_LAZY)
#define GET_PROC(lib, name) dlsym(lib, name)
#define FREE_LIBRARY(lib) dlclose(lib)
typedef void* LibHandle;
#endif

#ifdef __ANDROID__
#include <SLES/OpenSLES.h>
#include <SLES/OpenSLES_Android.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <jni.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "YAGE", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "YAGE", __VA_ARGS__)
#else
#define LOGI(...) do { printf("[YAGE] "); printf(__VA_ARGS__); printf("\n"); } while(0)
#define LOGE(...) do { printf("[YAGE ERROR] "); printf(__VA_ARGS__); printf("\n"); } while(0)
#endif

/* ── Native frame loop (POSIX only) ─────────────────────────────────── */
#ifndef _WIN32
#include <pthread.h>
#include <time.h>
#include <stdatomic.h>
#include <errno.h>

/* Forward declaration — implemented in yage_rcheevos.c */
extern void yage_rc_do_frame(void);

/* Display buffer — snapshot of the last completed video frame.
 * Updated at ~60 Hz by the native frame loop thread. */
static uint32_t* g_display_buf          = NULL;
static size_t    g_display_buf_capacity = 0;
static int       g_display_width        = 0;
static int       g_display_height       = 0;

/* Thread control (all atomic for cross-thread safety) */
static pthread_t           g_frame_thread;
static atomic_int          g_floop_running       = 0;
static atomic_int          g_floop_speed_pct     = 100;   /* 100 = 1× */
static atomic_int          g_floop_rewind_on     = 0;
static atomic_int          g_floop_rewind_interval = 5;
static atomic_int          g_floop_rcheevos_on   = 0;
static atomic_int          g_floop_fps_x100      = 0;     /* fps × 100 */
static yage_frame_callback_t g_frame_callback    = NULL;

/* ~60 Hz display interval in nanoseconds */
#define DISPLAY_INTERVAL_NS  16666667LL   /* 1e9 / 60 */

/* Base frame time for GBA (~59.7275 fps) in nanoseconds */
#define BASE_FRAME_NS        16742706LL   /* 1e9 / 59.7275 */

#endif /* !_WIN32 */

/* Suppress excessive logging after initial frames */
static int g_log_frame_count = 0;

/* Libretro memory types */
#define RETRO_MEMORY_SAVE_RAM 0
#define RETRO_MEMORY_RTC      1
#define RETRO_MEMORY_SYSTEM_RAM 2
#define RETRO_MEMORY_VIDEO_RAM 3

/* Libretro types */
typedef void (*retro_init_t)(void);
typedef void (*retro_deinit_t)(void);
typedef void (*retro_reset_t)(void);
typedef void (*retro_run_t)(void);
typedef bool (*retro_load_game_t)(const struct retro_game_info*);
typedef void (*retro_unload_game_t)(void);
typedef size_t (*retro_serialize_size_t)(void);
typedef bool (*retro_serialize_t)(void*, size_t);
typedef bool (*retro_unserialize_t)(const void*, size_t);
typedef void (*retro_get_system_info_t)(struct retro_system_info*);
typedef void (*retro_get_system_av_info_t)(struct retro_system_av_info*);
typedef void (*retro_set_environment_t)(void*);
typedef void (*retro_set_video_refresh_t)(void*);
typedef void (*retro_set_audio_sample_t)(void*);
typedef void (*retro_set_audio_sample_batch_t)(void*);
typedef void (*retro_set_input_poll_t)(void*);
typedef void (*retro_set_input_state_t)(void*);
typedef void* (*retro_get_memory_data_t)(unsigned id);
typedef size_t (*retro_get_memory_size_t)(unsigned id);

struct retro_game_info {
    const char* path;
    const void* data;
    size_t size;
    const char* meta;
};

struct retro_system_info {
    const char* library_name;
    const char* library_version;
    const char* valid_extensions;
    bool need_fullpath;
    bool block_extract;
};

struct retro_game_geometry {
    unsigned base_width;
    unsigned base_height;
    unsigned max_width;
    unsigned max_height;
    float aspect_ratio;
};

struct retro_system_timing {
    double fps;
    double sample_rate;
};

struct retro_system_av_info {
    struct retro_game_geometry geometry;
    struct retro_system_timing timing;
};

/* GBA screen dimensions */
#define GBA_WIDTH 240
#define GBA_HEIGHT 160
#define GB_WIDTH 160
#define GB_HEIGHT 144

/* SGB (Super Game Boy) uses 256x224 — the largest mGBA resolution */
#define SGB_WIDTH 256
#define SGB_HEIGHT 224

/* NES / SNES dimensions */
#define NES_WIDTH 256
#define NES_HEIGHT 240
#define SNES_WIDTH 256
#define SNES_HEIGHT 224

/* Selected libretro core path (set via yage_core_set_core before init) */
static char* g_core_lib_path = NULL;

#define AUDIO_BUFFER_SIZE 8192
/* Initial capacity must accommodate the largest possible resolution (SGB) */
#define VIDEO_BUFFER_SIZE (SGB_WIDTH * SGB_HEIGHT)

/* Global state for libretro callbacks */
static YageCore* g_current_core = NULL; /* Active core for env callback access */
static uint32_t* g_video_buffer = NULL;
static size_t g_video_buffer_capacity = 0; /* Allocated capacity in pixels */
static int16_t* g_audio_buffer = NULL;
static int g_audio_samples = 0;
static int g_width = GBA_WIDTH;
static int g_height = GBA_HEIGHT;
#ifndef _WIN32
static _Atomic uint32_t g_keys = 0;
#else
static uint32_t g_keys = 0;
#endif
static int g_pixel_format = RETRO_PIXEL_FORMAT_RGB565; /* Default format */

/* Audio volume control (0.0 = mute, 1.0 = full volume) */
static float g_volume = 1.0f;
static int g_audio_enabled = 1;

/* SGB (Super Game Boy) border support
 * When enabled, mGBA renders the full 256×224 SGB frame including borders.
 * Controlled via the libretro core option mgba_sgb_borders. */
static int g_sgb_borders_enabled = 1;  /* 1 = show SGB borders, 0 = GB only */
static int g_variables_dirty = 1;      /* 1 = core should re-read variables */

/* GB color palette remapping (only for original GB games) 
 * Colors stored in ABGR format (RGBA in little-endian memory for Flutter) */
static int g_palette_enabled = 0;  /* 0 = use original colors, 1 = remap */
static uint32_t g_palette_colors[4] = {
    0xFF0FBC9B, /* Lightest - ABGR of 0x9BBC0F */
    0xFF0FAC8B, /* Light    - ABGR of 0x8BAC0F */
    0xFF306230, /* Dark     - ABGR of 0x306230 */
    0xFF0F380F  /* Darkest  - ABGR of 0x0F380F */
};

/* Rewind ring buffer — stores serialized save states for instant rewind */
static void** g_rewind_snapshots = NULL;  /* Array of serialized state buffers */
static int g_rewind_head = 0;            /* Next write position */
static int g_rewind_count = 0;           /* Number of valid snapshots */
static int g_rewind_capacity = 0;        /* Allocated capacity */
static size_t g_rewind_state_size = 0;   /* Size of each serialized state */

#ifdef __ANDROID__
#include <stdatomic.h>

/* OpenSL ES audio state — low latency with adaptive rate
 * 2 buffers × 256 frames ≈ 15ms at 32kHz, 8ms at 65kHz */
#define AUDIO_BUFFERS 2
#define AUDIO_BUFFER_FRAMES 256

static SLObjectItf g_sl_engine = NULL;
static SLEngineItf g_sl_engine_itf = NULL;
static SLObjectItf g_sl_output_mix = NULL;
static SLObjectItf g_sl_player = NULL;
static SLPlayItf g_sl_play_itf = NULL;
static SLAndroidSimpleBufferQueueItf g_sl_buffer_queue = NULL;

static int16_t* g_sl_buffers[AUDIO_BUFFERS] = {NULL, NULL};
static int g_sl_buffer_index = 0;
static int g_sl_initialized = 0;

/* Lock-free ring buffer for audio — sized to hold ~250ms at highest rate */
#define RING_BUFFER_SIZE (32768)
#define RING_BUFFER_MASK (RING_BUFFER_SIZE - 1)
static int16_t g_ring_buffer[RING_BUFFER_SIZE];
static atomic_int g_ring_read = 0;
static atomic_int g_ring_write = 0;

/* Audio smoothing state */
static int16_t g_last_sample_l = 0;
static int16_t g_last_sample_r = 0;
static int g_underrun_count = 0;
static int g_audio_started = 0;
static double g_audio_sample_rate = 32768.0;

/* Adaptive rate detection — detects and re-adapts per game */
static int g_rate_detection_samples = 0;  /* Total audio samples during detection */
static int g_rate_detected = 0;
static double g_detected_rate = 0;
static double g_reported_rate = 32768.0;  /* Sample rate from AV info (set at ROM load) */

/* Video frame counter — incremented in video_refresh_callback, used for
 * audio rate detection.  The audio batch callback can be invoked multiple
 * times per video frame (especially for GB/GBC), so counting video frames
 * gives the correct samples-per-video-frame for rate classification. */
static int g_video_frames_total = 0;

/* Continuous rate monitoring — catches games that change rate mid-play */
static int g_monitor_frames = 0;          /* VIDEO frames seen during monitoring window */
static int g_monitor_samples = 0;         /* Audio samples during monitoring window */
static int g_frames_since_reinit = 0;     /* VIDEO frames since last OpenSL reinit */

/* ── Android Texture Rendering (ANativeWindow) ────────────────────────
 * Zero-copy frame delivery to Flutter's Texture widget.
 * The ANativeWindow is backed by a SurfaceTexture registered with
 * Flutter's TextureRegistry.  Pixels are blitted directly from
 * g_video_buffer — no Dart-side allocation, no decodeImageFromPixels.
 *
 * g_nw_mutex serializes blit_to_native_window and nativeReleaseSurface so
 * we never release the window while a frame blit is in progress (use-after-free). */
static ANativeWindow* g_native_window = NULL;
static int g_nw_configured_w = 0;  /* last-configured buffer geometry width */
static int g_nw_configured_h = 0;  /* last-configured buffer geometry height */
static pthread_mutex_t g_nw_mutex = PTHREAD_MUTEX_INITIALIZER;

/* Pre-buffer threshold — just enough for one OpenSL callback to avoid initial underrun */
#define PREBUFFER_SAMPLES (AUDIO_BUFFER_FRAMES)

/* Forward declarations */
static void shutdown_opensl_audio(void);
static int init_opensl_audio(double sample_rate);

/* Classify sample rate from average samples-per-frame.
 * mGBA runs at ~59.7275 fps, so expected samples/frame:
 *   131072 Hz → ~2194 samples/frame  (GB/GBC native: 4.194304 MHz ÷ 32)
 *    65536 Hz → ~1097 samples/frame  (Pokemon, most GBA)
 *    48000 Hz → ~804 samples/frame   (some titles)
 *    32768 Hz → ~549 samples/frame   (Dragon Ball, some GB/GBA)
 *
 * Thresholds use midpoints between expected values, lowered slightly
 * because startup frames often produce fewer samples.
 */
static double classify_sample_rate(double samples_per_frame) {
    if (samples_per_frame > 1600) return 131072.0;  /* GB/GBC native rate */
    if (samples_per_frame > 850)  return 65536.0;
    if (samples_per_frame > 650)  return 48000.0;
    return 32768.0;
}

/* Get number of samples available in ring buffer */
static inline int ring_buffer_available(void) {
    int write_pos = atomic_load_explicit(&g_ring_write, memory_order_acquire);
    int read_pos = atomic_load_explicit(&g_ring_read, memory_order_acquire);
    return (write_pos - read_pos + RING_BUFFER_SIZE) & RING_BUFFER_MASK;
}

/* Get free space in ring buffer */
static inline int ring_buffer_free(void) {
    return RING_BUFFER_SIZE - 1 - ring_buffer_available();
}

static void sl_buffer_callback(SLAndroidSimpleBufferQueueItf bq, void* context) {
    (void)context;
    
    int16_t* buffer = g_sl_buffers[g_sl_buffer_index];
    g_sl_buffer_index = (g_sl_buffer_index + 1) % AUDIO_BUFFERS;
    
    int samples_needed = AUDIO_BUFFER_FRAMES * 2; /* Stereo */
    int read_pos = atomic_load_explicit(&g_ring_read, memory_order_acquire);
    int write_pos = atomic_load_explicit(&g_ring_write, memory_order_acquire);
    int available = (write_pos - read_pos + RING_BUFFER_SIZE) & RING_BUFFER_MASK;
    
    /* Wait for pre-buffer before starting actual playback */
    if (!g_audio_started) {
        if (available < PREBUFFER_SAMPLES * 2) {
            /* Not enough data yet - output silence */
            memset(buffer, 0, samples_needed * sizeof(int16_t));
            (*bq)->Enqueue(bq, buffer, samples_needed * sizeof(int16_t));
            return;
        }
        g_audio_started = 1;
        LOGI("Audio pre-buffer filled (%d samples), starting playback", available);
    }
    
    /* Fill buffer from ring buffer */
    for (int i = 0; i < samples_needed; i += 2) {
        if (available >= 2) {
            /* Read stereo pair */
            g_last_sample_l = g_ring_buffer[read_pos];
            read_pos = (read_pos + 1) & RING_BUFFER_MASK;
            g_last_sample_r = g_ring_buffer[read_pos];
            read_pos = (read_pos + 1) & RING_BUFFER_MASK;
            available -= 2;
            
            buffer[i] = g_last_sample_l;
            buffer[i + 1] = g_last_sample_r;
            g_underrun_count = 0;
        } else {
            /* Underrun - fade to silence */
            g_underrun_count++;
            if (g_underrun_count < 64) {
                g_last_sample_l = (g_last_sample_l * 15) >> 4;
                g_last_sample_r = (g_last_sample_r * 15) >> 4;
            } else {
                g_last_sample_l = 0;
                g_last_sample_r = 0;
            }
            buffer[i] = g_last_sample_l;
            buffer[i + 1] = g_last_sample_r;
        }
    }
    
    /* Update read position atomically */
    atomic_store_explicit(&g_ring_read, read_pos, memory_order_release);
    
    (*bq)->Enqueue(bq, buffer, samples_needed * sizeof(int16_t));
}

static int init_opensl_audio(double sample_rate) {
    SLresult result;
    
    /* Shutdown any existing audio first */
    if (g_sl_initialized) {
        shutdown_opensl_audio();
    }
    
    /* Reset ring buffer state */
    atomic_store(&g_ring_read, 0);
    atomic_store(&g_ring_write, 0);
    g_last_sample_l = 0;
    g_last_sample_r = 0;
    g_underrun_count = 0;
    g_audio_started = 0;
    memset(g_ring_buffer, 0, sizeof(g_ring_buffer));
    
    g_audio_sample_rate = sample_rate;
    
    LOGI("Initializing OpenSL ES audio at %.0f Hz", sample_rate);
    
    /* Create engine */
    result = slCreateEngine(&g_sl_engine, 0, NULL, 0, NULL, NULL);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to create OpenSL engine");
        return -1;
    }
    
    result = (*g_sl_engine)->Realize(g_sl_engine, SL_BOOLEAN_FALSE);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to realize OpenSL engine");
        return -1;
    }
    
    result = (*g_sl_engine)->GetInterface(g_sl_engine, SL_IID_ENGINE, &g_sl_engine_itf);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to get engine interface");
        return -1;
    }
    
    /* Create output mix */
    result = (*g_sl_engine_itf)->CreateOutputMix(g_sl_engine_itf, &g_sl_output_mix, 0, NULL, NULL);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to create output mix");
        return -1;
    }
    
    result = (*g_sl_output_mix)->Realize(g_sl_output_mix, SL_BOOLEAN_FALSE);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to realize output mix");
        return -1;
    }
    
    /* Configure audio source */
    SLDataLocator_AndroidSimpleBufferQueue loc_bufq = {
        SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE,
        AUDIO_BUFFERS
    };
    
    /* Convert sample rate to millihertz for OpenSL ES */
    SLuint32 sample_rate_mhz = (SLuint32)(sample_rate * 1000);
    
    SLDataFormat_PCM format_pcm = {
        SL_DATAFORMAT_PCM,
        2,                           /* Stereo */
        sample_rate_mhz,             /* Detected sample rate in millihertz */
        SL_PCMSAMPLEFORMAT_FIXED_16,
        SL_PCMSAMPLEFORMAT_FIXED_16,
        SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT,
        SL_BYTEORDER_LITTLEENDIAN
    };
    
    SLDataSource audio_src = {&loc_bufq, &format_pcm};
    
    /* Configure audio sink */
    SLDataLocator_OutputMix loc_outmix = {SL_DATALOCATOR_OUTPUTMIX, g_sl_output_mix};
    SLDataSink audio_sink = {&loc_outmix, NULL};
    
    /* Create player */
    const SLInterfaceID ids[] = {SL_IID_BUFFERQUEUE};
    const SLboolean req[] = {SL_BOOLEAN_TRUE};
    
    result = (*g_sl_engine_itf)->CreateAudioPlayer(g_sl_engine_itf, &g_sl_player,
        &audio_src, &audio_sink, 1, ids, req);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to create audio player");
        return -1;
    }
    
    result = (*g_sl_player)->Realize(g_sl_player, SL_BOOLEAN_FALSE);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to realize audio player");
        return -1;
    }
    
    result = (*g_sl_player)->GetInterface(g_sl_player, SL_IID_PLAY, &g_sl_play_itf);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to get play interface");
        return -1;
    }
    
    result = (*g_sl_player)->GetInterface(g_sl_player, SL_IID_BUFFERQUEUE, &g_sl_buffer_queue);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to get buffer queue interface");
        return -1;
    }
    
    /* Allocate buffers */
    for (int i = 0; i < AUDIO_BUFFERS; i++) {
        g_sl_buffers[i] = (int16_t*)calloc(AUDIO_BUFFER_FRAMES * 2, sizeof(int16_t));
        if (!g_sl_buffers[i]) {
            LOGE("Failed to allocate audio buffer");
            return -1;
        }
    }
    
    /* Register callback */
    result = (*g_sl_buffer_queue)->RegisterCallback(g_sl_buffer_queue, sl_buffer_callback, NULL);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to register callback");
        return -1;
    }
    
    /* Start playback */
    result = (*g_sl_play_itf)->SetPlayState(g_sl_play_itf, SL_PLAYSTATE_PLAYING);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to start playback");
        return -1;
    }
    
    /* Queue initial buffers */
    for (int i = 0; i < AUDIO_BUFFERS; i++) {
        (*g_sl_buffer_queue)->Enqueue(g_sl_buffer_queue, g_sl_buffers[i], 
            AUDIO_BUFFER_FRAMES * 2 * sizeof(int16_t));
    }
    
    LOGI("OpenSL ES audio initialized: %.0fHz stereo, %d buffers x %d frames", 
         sample_rate, AUDIO_BUFFERS, AUDIO_BUFFER_FRAMES);
    g_sl_initialized = 1;
    return 0;
}

static void shutdown_opensl_audio(void) {
    g_sl_initialized = 0;
    
    if (g_sl_play_itf) {
        (*g_sl_play_itf)->SetPlayState(g_sl_play_itf, SL_PLAYSTATE_STOPPED);
    }
    
    if (g_sl_player) {
        (*g_sl_player)->Destroy(g_sl_player);
        g_sl_player = NULL;
    }
    if (g_sl_output_mix) {
        (*g_sl_output_mix)->Destroy(g_sl_output_mix);
        g_sl_output_mix = NULL;
    }
    if (g_sl_engine) {
        (*g_sl_engine)->Destroy(g_sl_engine);
        g_sl_engine = NULL;
    }
    for (int i = 0; i < AUDIO_BUFFERS; i++) {
        if (g_sl_buffers[i]) {
            free(g_sl_buffers[i]);
            g_sl_buffers[i] = NULL;
        }
    }
    
    /* Reset ring buffer state */
    atomic_store(&g_ring_read, 0);
    atomic_store(&g_ring_write, 0);
    g_last_sample_l = 0;
    g_last_sample_r = 0;
    g_underrun_count = 0;
    g_audio_started = 0;
    
    g_sl_play_itf = NULL;
    g_sl_buffer_queue = NULL;
    g_sl_engine_itf = NULL;
}
#endif /* __ANDROID__ */

struct YageCore {
    LibHandle lib;
    
    /* Libretro functions */
    retro_init_t retro_init;
    retro_deinit_t retro_deinit;
    retro_reset_t retro_reset;
    retro_run_t retro_run;
    retro_load_game_t retro_load_game;
    retro_unload_game_t retro_unload_game;
    retro_serialize_size_t retro_serialize_size;
    retro_serialize_t retro_serialize;
    retro_unserialize_t retro_unserialize;
    retro_get_system_info_t retro_get_system_info;
    retro_get_system_av_info_t retro_get_system_av_info;
    retro_set_environment_t retro_set_environment;
    retro_set_video_refresh_t retro_set_video_refresh;
    retro_set_audio_sample_t retro_set_audio_sample;
    retro_set_audio_sample_batch_t retro_set_audio_sample_batch;
    retro_set_input_poll_t retro_set_input_poll;
    retro_set_input_state_t retro_set_input_state;
    retro_get_memory_data_t retro_get_memory_data;
    retro_get_memory_size_t retro_get_memory_size;
    
    char* save_dir;
    char* rom_path;
    YagePlatform platform;
    int initialized;
    int game_loaded;
    
    /* State buffer */
    void* state_buffer;
    size_t state_size;
};

/* Color correction for GBA - makes colors more vibrant on modern displays */
static inline uint32_t apply_color_correction(uint8_t r, uint8_t g, uint8_t b) {
    /* GBA color correction - slight boost to saturation and contrast */
    /* This compensates for the original GBA's dark, non-backlit screen */
    int ri = r, gi = g, bi = b;
    
    /* Boost contrast slightly */
    ri = (ri - 128) * 110 / 100 + 128;
    gi = (gi - 128) * 110 / 100 + 128;
    bi = (bi - 128) * 110 / 100 + 128;
    
    /* Clamp values */
    if (ri < 0) ri = 0; if (ri > 255) ri = 255;
    if (gi < 0) gi = 0; if (gi > 255) gi = 255;
    if (bi < 0) bi = 0; if (bi > 255) bi = 255;
    
    /* Return as ABGR (which is RGBA in little-endian memory order for Flutter) */
    return 0xFF000000 | ((uint32_t)bi << 16) | ((uint32_t)gi << 8) | (uint32_t)ri;
}

/* Map an RGB pixel to one of 4 palette colors based on luminance.
 * GB games output 4 distinct shades - we classify by luminance thresholds. */
static inline uint32_t apply_gb_palette(uint8_t r, uint8_t g, uint8_t b) {
    /* Fast luminance approximation: (r*2 + g*5 + b) / 8 */
    int lum = (r * 2 + g * 5 + b) >> 3;
    
    /* Map to 4 levels with thresholds tuned for mGBA's GB output */
    if (lum >= 192) return g_palette_colors[0];      /* Lightest */
    else if (lum >= 128) return g_palette_colors[1];  /* Light */
    else if (lum >= 64) return g_palette_colors[2];   /* Dark */
    else return g_palette_colors[3];                   /* Darkest */
}

/* Process a pixel: apply palette remap for GB or color correction for GBC/GBA */
static inline uint32_t process_pixel(uint8_t r, uint8_t g, uint8_t b) {
    if (g_palette_enabled) {
        return apply_gb_palette(r, g, b);
    }
    return apply_color_correction(r, g, b);
}

/* Libretro callbacks */
static void video_refresh_callback(const void* data, unsigned width, unsigned height, size_t pitch) {
    if (!data || !g_video_buffer) return;
    
    g_width = width;
    g_height = height;
    g_video_frames_total++;
    
    /* Log only first few frames to avoid spam */
    if (g_log_frame_count < 5) {
        LOGI("Video: %ux%u, pitch=%zu, format=%d", width, height, pitch, g_pixel_format);
        g_log_frame_count++;
    }

    /* Guard: reallocate if the incoming frame exceeds our buffer capacity.
     * This handles SGB-enhanced games that switch from 160x144 to 256x224
     * or any other dynamic resolution change by the libretro core. */
    size_t needed = (size_t)width * height;
    if (needed > g_video_buffer_capacity) {
        uint32_t* new_buf = (uint32_t*)realloc(g_video_buffer, needed * sizeof(uint32_t));
        if (!new_buf) {
            LOGE("Failed to reallocate video buffer for %ux%u", width, height);
            return;
        }
        g_video_buffer = new_buf;
        g_video_buffer_capacity = needed;
        LOGI("Video buffer reallocated for %ux%u (%zu pixels)", width, height, needed);
    }
    
    if (g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
        /* XRGB8888: 32-bit per pixel, pitch is in bytes */
        const uint8_t* src = (const uint8_t*)data;
        
        for (unsigned y = 0; y < height; y++) {
            const uint32_t* row = (const uint32_t*)(src + y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint32_t pixel = row[x];
                uint8_t r = (pixel >> 16) & 0xFF;
                uint8_t g = (pixel >> 8) & 0xFF;
                uint8_t b = pixel & 0xFF;
                g_video_buffer[y * width + x] = process_pixel(r, g, b);
            }
        }
    } else if (g_pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
        /* RGB565: 16-bit per pixel, pitch is in bytes */
        const uint8_t* src = (const uint8_t*)data;
        
        for (unsigned y = 0; y < height; y++) {
            const uint16_t* row = (const uint16_t*)(src + y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint16_t pixel = row[x];
                /* RGB565: RRRRRGGGGGGBBBBB */
                uint8_t r = (pixel >> 11) & 0x1F;
                uint8_t g = (pixel >> 5) & 0x3F;
                uint8_t b = pixel & 0x1F;
                /* Expand to 8-bit with proper bit replication */
                r = (r << 3) | (r >> 2);
                g = (g << 2) | (g >> 4);
                b = (b << 3) | (b >> 2);
                g_video_buffer[y * width + x] = process_pixel(r, g, b);
            }
        }
    } else if (g_pixel_format == RETRO_PIXEL_FORMAT_0RGB1555) {
        /* 0RGB1555: 16-bit per pixel, pitch is in bytes */
        const uint8_t* src = (const uint8_t*)data;
        
        for (unsigned y = 0; y < height; y++) {
            const uint16_t* row = (const uint16_t*)(src + y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint16_t pixel = row[x];
                uint8_t r = (pixel >> 10) & 0x1F;
                uint8_t g = (pixel >> 5) & 0x1F;
                uint8_t b = pixel & 0x1F;
                r = (r << 3) | (r >> 2);
                g = (g << 3) | (g >> 2);
                b = (b << 3) | (b >> 2);
                g_video_buffer[y * width + x] = process_pixel(r, g, b);
            }
        }
    } else {
        /* Unknown format - try to detect based on pitch */
        LOGI("Unknown pixel format %d, trying auto-detect", g_pixel_format);
        
        /* If pitch suggests 32-bit pixels */
        if (pitch >= width * 4) {
            const uint8_t* src = (const uint8_t*)data;
            for (unsigned y = 0; y < height; y++) {
                const uint32_t* row = (const uint32_t*)(src + y * pitch);
                for (unsigned x = 0; x < width; x++) {
                    uint32_t pixel = row[x];
                    uint8_t r = (pixel >> 16) & 0xFF;
                    uint8_t g = (pixel >> 8) & 0xFF;
                    uint8_t b = pixel & 0xFF;
                    g_video_buffer[y * width + x] = process_pixel(r, g, b);
                }
            }
        } else {
            /* Assume 16-bit RGB565 */
            const uint8_t* src = (const uint8_t*)data;
            for (unsigned y = 0; y < height; y++) {
                const uint16_t* row = (const uint16_t*)(src + y * pitch);
                for (unsigned x = 0; x < width; x++) {
                    uint16_t pixel = row[x];
                    uint8_t r = (pixel >> 11) & 0x1F;
                    uint8_t g = (pixel >> 5) & 0x3F;
                    uint8_t b = pixel & 0x1F;
                    r = (r << 3) | (r >> 2);
                    g = (g << 2) | (g >> 4);
                    b = (b << 3) | (b >> 2);
                    g_video_buffer[y * width + x] = process_pixel(r, g, b);
                }
            }
        }
    }
}

static int g_audio_batch_count = 0;
static int g_overflow_count = 0;

static size_t audio_sample_batch_callback(const int16_t* data, size_t frames) {
    if (!data || !g_audio_buffer) return frames;
    
    size_t samples = frames * 2; /* Stereo */
    if (samples > AUDIO_BUFFER_SIZE * 2) {
        samples = AUDIO_BUFFER_SIZE * 2;
    }
    
    /* Apply volume scaling to the audio buffer */
    if (!g_audio_enabled || g_volume <= 0.0f) {
        /* Muted — fill with silence */
        memset(g_audio_buffer, 0, samples * sizeof(int16_t));
    } else if (g_volume >= 1.0f) {
        /* Full volume — straight copy */
        memcpy(g_audio_buffer, data, samples * sizeof(int16_t));
    } else {
        /* Scale each sample by volume (fixed-point for speed) */
        int vol_fp = (int)(g_volume * 256.0f); /* 8-bit fixed point */
        for (size_t i = 0; i < samples; i++) {
            g_audio_buffer[i] = (int16_t)((data[i] * vol_fp) >> 8);
        }
    }
    g_audio_samples = frames;

#ifdef __ANDROID__
    /* ================================================================
     * PHASE 1: Initial rate detection (first 15 VIDEO frames)
     * Use the reported sample rate from AV info as the primary source,
     * validated against measured samples-per-video-frame.
     *
     * NOTE: The audio batch callback can fire multiple times per video
     * frame (especially for GB/GBC at 131072 Hz).  We must count VIDEO
     * frames (from video_refresh_callback) — not batch invocations —
     * to get the correct samples-per-frame for classification.
     * ================================================================ */
    if (!g_rate_detected) {
        g_rate_detection_samples += frames;
        
        /* Wait for at least 15 VIDEO frames (not batch callbacks) */
        if (g_video_frames_total >= 15) {
            double avg_spf = (g_video_frames_total > 0)
                ? (double)g_rate_detection_samples / g_video_frames_total
                : 0;
            double measured_rate = classify_sample_rate(avg_spf);
            
            /* Use the reported rate from AV info if it's a known standard
             * rate.  Fall back to measured rate only if reported looks bogus
             * (e.g. 0 or extremely high/low). */
            double use_rate;
            if (g_reported_rate >= 8000.0 && g_reported_rate <= 192000.0) {
                use_rate = g_reported_rate;
                LOGI("Using reported sample rate: %.0f Hz (measured: %.1f samples/vframe → %.0f Hz)",
                     use_rate, avg_spf, measured_rate);
            } else {
                use_rate = measured_rate;
                LOGI("Reported rate %.0f Hz out of range, using measured: %.1f samples/vframe → %.0f Hz",
                     g_reported_rate, avg_spf, use_rate);
            }
            
            g_detected_rate = use_rate;
            init_opensl_audio(g_detected_rate);
            g_rate_detected = 1;
            g_frames_since_reinit = g_video_frames_total;
            g_monitor_frames = g_video_frames_total;
            g_monitor_samples = 0;
        }
        return frames;
    }
    
    /* ================================================================
     * PHASE 2: Continuous rate monitoring (VIDEO-frame based)
     * Every ~2 seconds (120 video frames), check if the game's audio
     * rate has changed.  We count VIDEO frames — not batch callbacks —
     * so GB/GBC games that fire multiple batches per frame are measured
     * correctly.
     * ================================================================ */
    g_monitor_samples += frames;
    {
        int vframes_in_window = g_video_frames_total - g_monitor_frames;
        int vframes_since_reinit = g_video_frames_total - g_frames_since_reinit;
        
        if (vframes_in_window >= 120) { /* Check every ~2 seconds */
            double avg_spf = (vframes_in_window > 0)
                ? (double)g_monitor_samples / vframes_in_window
                : 0;
            double new_rate = classify_sample_rate(avg_spf);
            
            /* Only reinit if rate genuinely changed and we haven't just reinited */
            if (new_rate != g_detected_rate && vframes_since_reinit > 180) {
                LOGI("Rate change detected: %.0f → %.0f Hz (%.1f samples/vframe)",
                     g_detected_rate, new_rate, avg_spf);
                g_detected_rate = new_rate;
                init_opensl_audio(new_rate);
                g_frames_since_reinit = g_video_frames_total;
            }
            
            /* Reset window: snapshot current video frame count */
            g_monitor_frames = g_video_frames_total;
            g_monitor_samples = 0;
        }
    }
    
    /* Debug logging every ~1 second (60 frames) */
    g_audio_batch_count++;
    if (g_audio_batch_count >= 60) {
        g_audio_batch_count = 0;
        if (g_overflow_count > 0) {
            LOGI("Audio: %zu frames/batch, overflows: %d, rate: %.0f",
                 frames, g_overflow_count, g_detected_rate);
            g_overflow_count = 0;
        }
    }

    /* ================================================================
     * PHASE 3: Push audio to ring buffer with adaptive latency cap
     * The max buffered amount is based on the DETECTED sample rate
     * so high-rate games (65kHz) get more room than low-rate (32kHz).
     * Target: ~50ms of buffered audio max.
     * ================================================================ */
    if (g_sl_initialized) {
        int write_pos = atomic_load_explicit(&g_ring_write, memory_order_acquire);
        int read_pos = atomic_load_explicit(&g_ring_read, memory_order_acquire);
        int available = (write_pos - read_pos + RING_BUFFER_SIZE) & RING_BUFFER_MASK;
        int free_space = RING_BUFFER_SIZE - 1 - available;
        
        /* Adaptive latency cap: ~50ms worth of stereo samples at current rate.
         * 131072 Hz → 13107 samples max | 65536 Hz → 6554 | 32768 Hz → 3277 */
        int max_buffered = (int)(g_detected_rate * 2.0 * 0.050); /* 50ms in stereo samples */
        if (max_buffered < AUDIO_BUFFER_FRAMES * 2 * 4) {
            max_buffered = AUDIO_BUFFER_FRAMES * 2 * 4; /* Floor: 4 callbacks */
        }
        
        if (available > max_buffered) {
            /* Too much buffered — skip ahead, keep ~25ms worth */
            int keep = max_buffered / 2;
            int excess = available - keep;
            read_pos = (read_pos + excess) & RING_BUFFER_MASK;
            atomic_store_explicit(&g_ring_read, read_pos, memory_order_release);
            available = keep;
            free_space = RING_BUFFER_SIZE - 1 - available;
        }
        
        /* If buffer is full, advance read pointer to make room */
        if ((int)samples > free_space) {
            int need = samples - free_space + 128;
            int new_read = (read_pos + need) & RING_BUFFER_MASK;
            atomic_store_explicit(&g_ring_read, new_read, memory_order_release);
            g_overflow_count++;
        }
        
        /* Write volume-scaled samples to ring buffer */
        for (size_t i = 0; i < samples; i++) {
            g_ring_buffer[write_pos] = g_audio_buffer[i];
            write_pos = (write_pos + 1) & RING_BUFFER_MASK;
        }
        
        /* Update write position atomically */
        atomic_store_explicit(&g_ring_write, write_pos, memory_order_release);
    }
#endif
    
    return frames;
}

static void audio_sample_callback(int16_t left, int16_t right) {
    /* Single sample callback - rarely used */
    (void)left;
    (void)right;
}

static void input_poll_callback(void) {
    /* Nothing to do - keys are set externally */
}

static int16_t input_state_callback(unsigned port, unsigned device, unsigned index, unsigned id) {
    (void)index;
    
    if (port != 0 || device != RETRO_DEVICE_JOYPAD) return 0;
    
#ifndef _WIN32
    uint32_t keys = atomic_load_explicit(&g_keys, memory_order_relaxed);
#else
    uint32_t keys = g_keys;
#endif
    /* Debug: log when core polls for input and we have keys (rate-limited) */
    static unsigned poll_log = 0;
    if (keys != 0 && (poll_log++ % 300) == 0) {
        LOGI("Input: input_state_callback id=%u keys=0x%X (core is polling)", id, (unsigned)keys);
    }
    /* Map libretro buttons to our key bits */
    switch (id) {
        case RETRO_DEVICE_ID_JOYPAD_A:      return (keys & (1 << 0)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_B:      return (keys & (1 << 1)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_SELECT: return (keys & (1 << 2)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_START:  return (keys & (1 << 3)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_RIGHT:  return (keys & (1 << 4)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_LEFT:   return (keys & (1 << 5)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_UP:     return (keys & (1 << 6)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_DOWN:   return (keys & (1 << 7)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_R:      return (keys & (1 << 8)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_L:      return (keys & (1 << 9)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_X:      return (keys & (1 << 10)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_Y:      return (keys & (1 << 11)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_MASK: {
            /* NES/SNES cores request full joypad state as bitmask; convert g_keys to libretro order */
            uint32_t mask = 0;
            if (keys & (1 << 0))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_A);      /* A */
            if (keys & (1 << 1))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_B);      /* B */
            if (keys & (1 << 2))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_SELECT); /* SELECT */
            if (keys & (1 << 3))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_START);  /* START */
            if (keys & (1 << 4))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT);  /* RIGHT */
            if (keys & (1 << 5))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_LEFT);   /* LEFT */
            if (keys & (1 << 6))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_UP);     /* UP */
            if (keys & (1 << 7))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_DOWN);   /* DOWN */
            if (keys & (1 << 8))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_R);      /* R */
            if (keys & (1 << 9))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_L);      /* L */
            if (keys & (1 << 10)) mask |= (1 << RETRO_DEVICE_ID_JOYPAD_X);      /* X */
            if (keys & (1 << 11)) mask |= (1 << RETRO_DEVICE_ID_JOYPAD_Y);      /* Y */
            return (int16_t)mask;
        }
        default: return 0;
    }
}

/*
 * ============================================================
 * Link Cable — Memory Map + SIO Register Access (structs/globals)
 * ============================================================
 *
 * We intercept RETRO_ENVIRONMENT_SET_MEMORY_MAPS (cmd 36, with or
 * without the EXPERIMENTAL flag) to obtain direct pointers to the
 * emulated address space.  For GB/GBC the I/O region at 0xFF00
 * gives us SB (0xFF01), SC (0xFF02), and IF (0xFF0F) which are
 * the registers needed for link-cable emulation.
 *
 * For GBA the I/O region at 0x04000000 contains SIOCNT (0x128)
 * and SIODATA8 (0x12A).
 */

/* ── Memory-map descriptor storage ── */
struct yage_mem_region {
    void*    ptr;      /* Host pointer to start of this region          */
    uint32_t start;    /* Emulated start address                        */
    uint32_t len;      /* Length in bytes                                */
};

#define MAX_MEM_REGIONS 32
static struct yage_mem_region g_mem_regions[MAX_MEM_REGIONS];
static int g_mem_region_count = 0;

/* Quick look-up cache for the I/O region (set once after SET_MEMORY_MAPS) */
static uint8_t* g_io_ptr = NULL;  /* Pointer to the I/O base             */
static uint32_t g_io_start = 0;   /* Emulated start address of the region */
static uint32_t g_io_len = 0;     /* Length of the I/O region              */

/* libretro memory map structures (matching the libretro API) */
struct retro_memory_descriptor_lc {
    uint64_t    flags;
    void*       ptr;
    size_t      offset;
    size_t      start;
    size_t      select;
    size_t      disconnect;
    size_t      len;
    const char* addrspace;
};

struct retro_memory_map_lc {
    const struct retro_memory_descriptor_lc* descriptors;
    unsigned num_descriptors;
};

/* Called from the environment callback to store the memory map. */
static void handle_set_memory_maps(const void* data) {
    if (!data) return;

    const struct retro_memory_map_lc* mmaps = (const struct retro_memory_map_lc*)data;
    g_mem_region_count = 0;
    g_io_ptr = NULL;
    g_io_start = 0;
    g_io_len = 0;

    for (unsigned i = 0; i < mmaps->num_descriptors && g_mem_region_count < MAX_MEM_REGIONS; i++) {
        const struct retro_memory_descriptor_lc* d = &mmaps->descriptors[i];
        if (!d->ptr || d->len == 0) continue;

        struct yage_mem_region* r = &g_mem_regions[g_mem_region_count++];
        r->ptr   = d->ptr;
        r->start = (uint32_t)d->start;
        r->len   = (uint32_t)d->len;

        /* Identify the I/O region for quick access.
         * GB/GBC:  I/O starts at 0xFF00
         * GBA:     I/O starts at 0x04000000 */
        if (d->start == 0xFF00 || d->start == 0x04000000) {
            g_io_ptr   = (uint8_t*)d->ptr;
            g_io_start = (uint32_t)d->start;
            g_io_len   = (uint32_t)d->len;
            LOGI("Link cable: I/O region found at 0x%08X, len=%u, ptr=%p",
                 g_io_start, g_io_len, g_io_ptr);
        }
    }
    LOGI("Link cable: stored %d memory regions", g_mem_region_count);
}

/* Libretro variable struct (for core option handling) */
struct retro_variable {
    const char *key;
    const char *value;
};

static bool environment_callback(unsigned cmd, void* data) {
    switch (cmd) {
        case 10: /* RETRO_ENVIRONMENT_SET_PIXEL_FORMAT */
            if (data) {
                int requested = *(int*)data;
                LOGI("Core requested pixel format: %d", requested);
                g_pixel_format = requested;
            }
            return true;
        case 3: /* RETRO_ENVIRONMENT_GET_CAN_DUPE */
            if (data) {
                *(bool*)data = true;
            }
            return true;
        case 6: /* RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL */
            return true;
        case 9: /* RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY */
            if (data) {
                *(const char**)data = (g_current_core && g_current_core->save_dir)
                    ? g_current_core->save_dir : ".";
            }
            return true;
        case 15: { /* RETRO_ENVIRONMENT_GET_VARIABLE */
            if (!data) return false;
            struct retro_variable* var = (struct retro_variable*)data;
            if (!var->key) return false;

            if (strcmp(var->key, "mgba_sgb_borders") == 0) {
                var->value = g_sgb_borders_enabled ? "ON" : "OFF";
                return true;
            }
            /* Let mGBA use its own defaults for all other variables */
            return false;
        }
        case 16: /* RETRO_ENVIRONMENT_SET_VARIABLES */
            /* Accept the core's variable definitions */
            return true;
        case 17: { /* RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE */
            if (data) {
                *(bool*)data = g_variables_dirty ? true : false;
                g_variables_dirty = 0;
            }
            return true;
        }
        case 27: /* RETRO_ENVIRONMENT_GET_LOG_INTERFACE */
            return false;
        case 31: /* RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY */
            if (data) {
                *(const char**)data = (g_current_core && g_current_core->save_dir)
                    ? g_current_core->save_dir : ".";
            }
            return true;
        case 36:      /* RETRO_ENVIRONMENT_SET_MEMORY_MAPS (no experimental flag) */
        case 0x10024: /* RETRO_ENVIRONMENT_SET_MEMORY_MAPS (with experimental flag) */
            handle_set_memory_maps(data);
            return true;
        case 40: /* RETRO_ENVIRONMENT_GET_INPUT_BITMASKS */
            return true;
        default: {
            /* NES/SNES cores need these — mGBA breaks if we return true for 11/35 */
            int is_nes_snes = (g_core_lib_path && (strstr(g_core_lib_path, "fceumm") || strstr(g_core_lib_path, "snes9x")));
            if (is_nes_snes && (cmd == 11 || cmd == 35 || cmd == 52 || cmd == 53 || cmd == 54 ||
                cmd == 55 || cmd == 59 || cmd == 65 || cmd == 66 || cmd == 69 || cmd == 70 ||
                cmd == 0x10033 || cmd == 0x1000A || cmd == 0x1000D || cmd == 0x10013)) {
                return true;
            }
            if (g_log_frame_count < 5) {
                LOGI("Unhandled env cmd: %u", cmd);
            }
            return false;
        }
    }
}

YageCore* yage_core_create(void) {
    YageCore* core = (YageCore*)calloc(1, sizeof(YageCore));
    if (!core) return NULL;
    
    /* Allocate video buffer — sized for SGB (256x224), the largest mGBA output */
    g_video_buffer = (uint32_t*)malloc(VIDEO_BUFFER_SIZE * sizeof(uint32_t));
    g_video_buffer_capacity = VIDEO_BUFFER_SIZE;
    if (!g_video_buffer) {
        g_video_buffer_capacity = 0;
        free(core);
        return NULL;
    }
    
    /* Allocate audio buffer */
    g_audio_buffer = (int16_t*)malloc(AUDIO_BUFFER_SIZE * 2 * sizeof(int16_t));
    if (!g_audio_buffer) {
        free(g_video_buffer);
        free(core);
        return NULL;
    }
    
    return core;
}

YAGE_API int yage_core_set_core(const char* path) {
    if (g_core_lib_path) {
        free(g_core_lib_path);
        g_core_lib_path = NULL;
    }
    if (path && path[0]) {
        g_core_lib_path = strdup(path);
        LOGI("Core selection: %s", g_core_lib_path);
    }
    return 0;
}

int yage_core_init(YageCore* core) {
    if (!core) return -1;
    
    /* Load the libretro core — use g_core_lib_path if set via yage_core_set_core */
    const char* lib_name;
#ifdef _WIN32
    lib_name = g_core_lib_path ? g_core_lib_path : "mgba_libretro.dll";
#elif defined(__ANDROID__)
    lib_name = g_core_lib_path ? g_core_lib_path : "libmgba_libretro_android.so";
#else
    lib_name = g_core_lib_path ? g_core_lib_path : "libmgba_libretro.so";
#endif
    
    core->lib = LOAD_LIBRARY(lib_name);
    
    if (!core->lib) {
        LOGE("Failed to load libretro core: %s", lib_name);
        return -1;
    }
    
    /* Load function pointers */
    #define LOAD_SYM(name) core->name = (name##_t)GET_PROC(core->lib, #name)
    
    LOAD_SYM(retro_init);
    LOAD_SYM(retro_deinit);
    LOAD_SYM(retro_reset);
    LOAD_SYM(retro_run);
    LOAD_SYM(retro_load_game);
    LOAD_SYM(retro_unload_game);
    LOAD_SYM(retro_serialize_size);
    LOAD_SYM(retro_serialize);
    LOAD_SYM(retro_unserialize);
    LOAD_SYM(retro_get_system_info);
    LOAD_SYM(retro_get_system_av_info);
    LOAD_SYM(retro_set_environment);
    LOAD_SYM(retro_set_video_refresh);
    LOAD_SYM(retro_set_audio_sample);
    LOAD_SYM(retro_set_audio_sample_batch);
    LOAD_SYM(retro_set_input_poll);
    LOAD_SYM(retro_set_input_state);
    LOAD_SYM(retro_get_memory_data);
    LOAD_SYM(retro_get_memory_size);
    
    #undef LOAD_SYM
    
    /* Verify required functions */
    if (!core->retro_init || !core->retro_run || !core->retro_load_game) {
        FREE_LIBRARY(core->lib);
        core->lib = NULL;
        return -1;
    }
    
    /* Store core pointer for use in static callbacks (env, etc.) */
    g_current_core = core;

    /* Set up callbacks */
    if (core->retro_set_environment)
        core->retro_set_environment(environment_callback);
    if (core->retro_set_video_refresh)
        core->retro_set_video_refresh(video_refresh_callback);
    if (core->retro_set_audio_sample)
        core->retro_set_audio_sample(audio_sample_callback);
    if (core->retro_set_audio_sample_batch)
        core->retro_set_audio_sample_batch(audio_sample_batch_callback);
    if (core->retro_set_input_poll)
        core->retro_set_input_poll(input_poll_callback);
    if (core->retro_set_input_state)
        core->retro_set_input_state(input_state_callback);
    
    /* Initialize the core */
    core->retro_init();
    core->initialized = 1;
    
    /* Note: Audio is initialized in yage_core_load_rom after we know the sample rate */
    
    return 0;
}

void yage_core_destroy(YageCore* core) {
    if (!core) return;

    /* Clear the global pointer so callbacks don't use a stale core */
    if (g_current_core == core) g_current_core = NULL;

    /* Reset input state so the next core starts with clean keys */
#ifndef _WIN32
    atomic_store_explicit(&g_keys, 0, memory_order_relaxed);
#else
    g_keys = 0;
#endif
    
    /* Free rewind buffer */
    yage_core_rewind_deinit(core);
    
#ifdef __ANDROID__
    shutdown_opensl_audio();
#endif
    
    if (core->game_loaded && core->retro_unload_game) {
        core->retro_unload_game();
    }
    
    if (core->initialized && core->retro_deinit) {
        core->retro_deinit();
    }
    
    if (core->lib) {
        FREE_LIBRARY(core->lib);
    }
    
    if (core->save_dir) free(core->save_dir);
    if (core->rom_path) free(core->rom_path);
    if (core->state_buffer) free(core->state_buffer);
    
    if (g_video_buffer) {
        free(g_video_buffer);
        g_video_buffer = NULL;
        g_video_buffer_capacity = 0;
    }
    if (g_audio_buffer) {
        free(g_audio_buffer);
        g_audio_buffer = NULL;
    }
    
    free(core);
}

int yage_core_load_rom(YageCore* core, const char* path) {
    if (!core || !core->initialized || !path) return -1;
    
    /* Detect platform from extension */
    const char* ext = strrchr(path, '.');
    if (ext) {
        if (strcasecmp(ext, ".gba") == 0) {
            core->platform = YAGE_PLATFORM_GBA;
            g_width = GBA_WIDTH;
            g_height = GBA_HEIGHT;
        } else if (strcasecmp(ext, ".gbc") == 0) {
            core->platform = YAGE_PLATFORM_GBC;
            g_width = GB_WIDTH;
            g_height = GB_HEIGHT;
        } else if (strcasecmp(ext, ".sgb") == 0) {
            /* SGB-enhanced ROM — use GB platform but set initial
             * dimensions to SGB (256×224) when borders are enabled */
            core->platform = YAGE_PLATFORM_GB;
            if (g_sgb_borders_enabled) {
                g_width = SGB_WIDTH;
                g_height = SGB_HEIGHT;
            } else {
                g_width = GB_WIDTH;
                g_height = GB_HEIGHT;
            }
        } else if (strcasecmp(ext, ".gb") == 0) {
            core->platform = YAGE_PLATFORM_GB;
            g_width = GB_WIDTH;
            g_height = GB_HEIGHT;
        } else if (strcasecmp(ext, ".nes") == 0) {
            core->platform = YAGE_PLATFORM_NES;
            g_width = NES_WIDTH;
            g_height = NES_HEIGHT;
        } else if (strcasecmp(ext, ".sfc") == 0 || strcasecmp(ext, ".smc") == 0) {
            core->platform = YAGE_PLATFORM_SNES;
            g_width = SNES_WIDTH;
            g_height = SNES_HEIGHT;
        }
    }
    
    /* Mark variables dirty so the core re-reads SGB border setting */
    g_variables_dirty = 1;
    
    /* Load the ROM — check need_fullpath; some cores need data in memory */
    struct retro_game_info info = {0};
    info.path = path;
    info.data = NULL;
    info.size = 0;
    info.meta = NULL;
    
    void* rom_data = NULL;
    if (core->retro_get_system_info) {
        struct retro_system_info sys_info = {0};
        core->retro_get_system_info(&sys_info);
        if (!sys_info.need_fullpath) {
            FILE* f = fopen(path, "rb");
            if (f) {
                fseek(f, 0, SEEK_END);
                long sz = ftell(f);
                fseek(f, 0, SEEK_SET);
                if (sz > 0 && sz < (long)(64 * 1024 * 1024)) { /* max 64MB */
                    rom_data = malloc((size_t)sz);
                    if (rom_data && fread(rom_data, 1, (size_t)sz, f) == (size_t)sz) {
                        info.data = rom_data;
                        info.size = (size_t)sz;
                        info.path = NULL;
                        LOGI("Loaded ROM into memory: %zu bytes", info.size);
                    } else {
                        if (rom_data) free(rom_data);
                        rom_data = NULL;
                    }
                }
                fclose(f);
            }
        }
    }
    
    if (!core->retro_load_game(&info)) {
        if (rom_data) free(rom_data);
        LOGE("retro_load_game failed for: %s", path ? path : "(null)");
        return -1;
    }
    if (rom_data) free(rom_data); /* Core copies data; we can free */
    
    /* Store path */
    if (core->rom_path) free(core->rom_path);
    core->rom_path = strdup(path);
    
    /* Get AV info */
    double reported_sample_rate = 32768.0; /* Default fallback */
    if (core->retro_get_system_av_info) {
        struct retro_system_av_info av_info;
        core->retro_get_system_av_info(&av_info);
        g_width = av_info.geometry.base_width;
        g_height = av_info.geometry.base_height;
        reported_sample_rate = av_info.timing.sample_rate;
        g_reported_rate = reported_sample_rate;  /* Store for audio init */
        LOGI("AV Info: %ux%u, fps=%.2f, reported_sample_rate=%.0f", 
             g_width, g_height, av_info.timing.fps, reported_sample_rate);

        /* Pre-allocate video buffer for the reported resolution.
         * SGB-enhanced GB games report 256x224 which is larger than the
         * default GBA 240x160 allocation.  Using max_width/max_height
         * when available ensures we cover any resolution the core may use. */
        unsigned max_w = av_info.geometry.max_width  ? av_info.geometry.max_width  : g_width;
        unsigned max_h = av_info.geometry.max_height ? av_info.geometry.max_height : g_height;
        size_t needed = (size_t)max_w * max_h;
        if (needed > g_video_buffer_capacity && g_video_buffer) {
            uint32_t* new_buf = (uint32_t*)realloc(g_video_buffer, needed * sizeof(uint32_t));
            if (new_buf) {
                g_video_buffer = new_buf;
                g_video_buffer_capacity = needed;
                LOGI("Video buffer pre-allocated for %ux%u (%zu pixels)", max_w, max_h, needed);
            }
        }
    }
    
#ifdef __ANDROID__
    /* Shut down previous audio completely */
    shutdown_opensl_audio();
    
    /* Reset ALL rate detection & monitoring state for the new game */
    g_rate_detection_samples = 0;
    g_rate_detected = 0;
    g_detected_rate = 0;
    g_video_frames_total = 0;
    g_monitor_frames = 0;
    g_monitor_samples = 0;
    g_frames_since_reinit = 0;
    g_audio_started = 0;
    g_audio_batch_count = 0;
    g_overflow_count = 0;
    g_log_frame_count = 0;
    
    /* NES/SNES (48kHz): init OpenSL immediately — these cores report stable
     * rates.  GB/GBC/GBA: wait 15 video frames to validate measured rate. */
    if (reported_sample_rate >= 44000.0 && reported_sample_rate <= 50000.0) {
        g_detected_rate = reported_sample_rate;
        init_opensl_audio(g_detected_rate);
        g_rate_detected = 1;
        g_frames_since_reinit = 0;
        g_monitor_frames = 0;
        g_monitor_samples = 0;
        LOGI("Audio init at reported rate: %.0f Hz (NES/SNES path)", reported_sample_rate);
    } else {
        LOGI("Audio will init after 15 video frames at reported rate: %.0f Hz",
             reported_sample_rate);
    }
#endif
    
    /* Allocate state buffer */
    if (core->retro_serialize_size) {
        core->state_size = core->retro_serialize_size();
        if (core->state_size > 0) {
            core->state_buffer = malloc(core->state_size);
        }
    }
    
    core->game_loaded = 1;
    return 0;
}

int yage_core_load_bios(YageCore* core, const char* path) {
    /* Libretro cores handle BIOS internally via environment callback */
    (void)core;
    (void)path;
    return 0;
}

void yage_core_set_save_dir(YageCore* core, const char* path) {
    if (!core || !path) return;
    if (core->save_dir) free(core->save_dir);
    core->save_dir = strdup(path);
}

void yage_core_reset(YageCore* core) {
    if (!core || !core->game_loaded || !core->retro_reset) return;
    core->retro_reset();
}

void yage_core_run_frame(YageCore* core) {
    if (!core || !core->game_loaded || !core->retro_run) return;
    g_audio_samples = 0;
    core->retro_run();
}

void yage_core_set_keys(YageCore* core, uint32_t keys) {
    (void)core;
#ifndef _WIN32
    atomic_store_explicit(&g_keys, keys, memory_order_relaxed);
#else
    g_keys = keys;
#endif
    /* Debug: log when keys are pressed (rate-limited to avoid spam) */
    static unsigned log_count = 0;
    if (keys != 0 && (log_count++ % 60) == 0) {
        LOGI("Input: yage_core_set_keys keys=0x%X", (unsigned)keys);
    }
}

uint32_t* yage_core_get_video_buffer(YageCore* core) {
    (void)core;
    return g_video_buffer;
}

int yage_core_get_width(YageCore* core) {
    (void)core;
    return g_width;
}

int yage_core_get_height(YageCore* core) {
    (void)core;
    return g_height;
}

int16_t* yage_core_get_audio_buffer(YageCore* core) {
    (void)core;
    return g_audio_buffer;
}

int yage_core_get_audio_samples(YageCore* core) {
    (void)core;
    return g_audio_samples;
}

int yage_core_save_state(YageCore* core, int slot) {
    if (!core || !core->game_loaded || !core->state_buffer) return -1;
    if (!core->retro_serialize) return -1;
    
    /* Serialize state */
    if (!core->retro_serialize(core->state_buffer, core->state_size)) {
        return -1;
    }
    
    /* Save to file */
    if (core->save_dir && core->rom_path) {
        char path[1024];
        const char* rom_name = strrchr(core->rom_path, '/');
        if (!rom_name) rom_name = strrchr(core->rom_path, '\\');
        if (!rom_name) rom_name = core->rom_path;
        else rom_name++;
        
        snprintf(path, sizeof(path), "%s/%s.ss%d", core->save_dir, rom_name, slot);
        
        FILE* f = fopen(path, "wb");
        if (f) {
            fwrite(core->state_buffer, 1, core->state_size, f);
            fclose(f);
            return 0;
        }
    }
    
    return -1;
}

int yage_core_load_state(YageCore* core, int slot) {
    if (!core || !core->game_loaded || !core->state_buffer) return -1;
    if (!core->retro_unserialize) return -1;
    
    /* Load from file */
    if (core->save_dir && core->rom_path) {
        char path[1024];
        const char* rom_name = strrchr(core->rom_path, '/');
        if (!rom_name) rom_name = strrchr(core->rom_path, '\\');
        if (!rom_name) rom_name = core->rom_path;
        else rom_name++;
        
        snprintf(path, sizeof(path), "%s/%s.ss%d", core->save_dir, rom_name, slot);
        
        FILE* f = fopen(path, "rb");
        if (f) {
            fread(core->state_buffer, 1, core->state_size, f);
            fclose(f);
            
            if (core->retro_unserialize(core->state_buffer, core->state_size)) {
                return 0;
            }
        }
    }
    
    return -1;
}

int yage_core_get_platform(YageCore* core) {
    if (!core) return YAGE_PLATFORM_UNKNOWN;
    return core->platform;
}

/*
 * SRAM (Battery Save) Functions
 */

int yage_core_get_sram_size(YageCore* core) {
    if (!core || !core->initialized || !core->retro_get_memory_size) return 0;
    return (int)core->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
}

uint8_t* yage_core_get_sram_data(YageCore* core) {
    if (!core || !core->initialized || !core->retro_get_memory_data) return NULL;
    return (uint8_t*)core->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
}

int yage_core_save_sram(YageCore* core, const char* path) {
    if (!core || !core->initialized || !path) return -1;
    if (!core->retro_get_memory_size || !core->retro_get_memory_data) return -1;
    
    size_t size = core->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (size == 0) {
        LOGI("No SRAM to save (size=0)");
        return 0; /* No SRAM to save - not an error */
    }
    
    void* data = core->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!data) {
        LOGE("Failed to get SRAM data pointer");
        return -1;
    }
    
    FILE* file = fopen(path, "wb");
    if (!file) {
        LOGE("Failed to open save file: %s", path);
        return -1;
    }
    
    size_t written = fwrite(data, 1, size, file);
    fclose(file);
    
    if (written == size) {
        LOGI("Saved SRAM to %s (%zu bytes)", path, size);
        return 0;
    } else {
        LOGE("Failed to write SRAM (wrote %zu of %zu bytes)", written, size);
        return -1;
    }
}

int yage_core_load_sram(YageCore* core, const char* path) {
    if (!core || !core->initialized || !path) return -1;
    if (!core->retro_get_memory_size || !core->retro_get_memory_data) return -1;
    
    size_t size = core->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (size == 0) {
        LOGI("No SRAM expected for this game (size=0)");
        return 0; /* No SRAM expected - not an error */
    }
    
    void* data = core->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!data) {
        LOGE("Failed to get SRAM data pointer");
        return -1;
    }
    
    FILE* file = fopen(path, "rb");
    if (!file) {
        LOGI("No save file found: %s (starting fresh)", path);
        return 0; /* File doesn't exist - not an error, just no save yet */
    }
    
    size_t read_size = fread(data, 1, size, file);
    fclose(file);
    
    if (read_size > 0) {
        LOGI("Loaded SRAM from %s (%zu bytes)", path, read_size);
        return 0;
    } else {
        LOGE("Failed to read SRAM data");
        return -1;
    }
}

/*
 * Audio Volume Control
 */

void yage_core_set_volume(YageCore* core, float volume) {
    (void)core;
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    g_volume = volume;
    LOGI("Volume set to %.2f", volume);
}

void yage_core_set_audio_enabled(YageCore* core, int enabled) {
    (void)core;
    g_audio_enabled = enabled ? 1 : 0;
    LOGI("Audio %s", enabled ? "enabled" : "disabled");
}

/*
 * Color Palette Control (for original Game Boy)
 * colors: array of 4 ARGB values [lightest, light, dark, darkest]
 * palette_index: -1 to disable (use original colors), 0+ to enable with given colors
 */

void yage_core_set_color_palette(YageCore* core, int palette_index,
                                  uint32_t color0, uint32_t color1,
                                  uint32_t color2, uint32_t color3) {
    (void)core;
    if (palette_index < 0) {
        g_palette_enabled = 0;
        LOGI("Color palette disabled (using original colors)");
    } else {
        g_palette_enabled = 1;
        /* Convert from ARGB to ABGR (RGBA in little-endian memory for Flutter) */
        #define ARGB_TO_ABGR(c) ( ((c) & 0xFF00FF00) | (((c) & 0x00FF0000) >> 16) | (((c) & 0x000000FF) << 16) )
        g_palette_colors[0] = ARGB_TO_ABGR(color0);
        g_palette_colors[1] = ARGB_TO_ABGR(color1);
        g_palette_colors[2] = ARGB_TO_ABGR(color2);
        g_palette_colors[3] = ARGB_TO_ABGR(color3);
        #undef ARGB_TO_ABGR
        LOGI("Color palette set: #%06X #%06X #%06X #%06X",
             color0 & 0xFFFFFF, color1 & 0xFFFFFF,
             color2 & 0xFFFFFF, color3 & 0xFFFFFF);
    }
}

/*
 * SGB Border Control
 *
 * Enable or disable Super Game Boy border rendering.
 * When enabled (1), SGB-enhanced GB games will render at 256×224 with
 * decorative borders around the 160×144 gameplay area.
 * When disabled (0), SGB games render at the standard 160×144 GB resolution.
 *
 * Must be called BEFORE loading a ROM (or the ROM must be reloaded) for
 * the change to take effect, since the core reads this option at load time.
 */

YAGE_API void yage_core_set_sgb_borders(YageCore* core, int enabled) {
    (void)core;
    g_sgb_borders_enabled = enabled ? 1 : 0;
    g_variables_dirty = 1;  /* Tell core to re-read variables */
    LOGI("SGB borders %s", enabled ? "enabled" : "disabled");
}

/*
 * Rewind Ring Buffer
 *
 * Pre-allocates `capacity` serialized-state slots. yage_core_rewind_push()
 * captures the current emulator state into the next slot (ring overwrites
 * the oldest when full). yage_core_rewind_pop() restores the most recent
 * snapshot and removes it from the buffer.
 */

int yage_core_rewind_init(YageCore* core, int capacity) {
    if (!core || !core->game_loaded || !core->retro_serialize_size) return -1;

    /* Clean up any existing buffer first */
    yage_core_rewind_deinit(core);

    g_rewind_state_size = core->retro_serialize_size();
    if (g_rewind_state_size == 0) return -1;

    if (capacity <= 0 || capacity > 1024) capacity = 36;

    g_rewind_snapshots = (void**)calloc(capacity, sizeof(void*));
    if (!g_rewind_snapshots) return -1;

    for (int i = 0; i < capacity; i++) {
        g_rewind_snapshots[i] = malloc(g_rewind_state_size);
        if (!g_rewind_snapshots[i]) {
            for (int j = 0; j < i; j++) free(g_rewind_snapshots[j]);
            free(g_rewind_snapshots);
            g_rewind_snapshots = NULL;
            return -1;
        }
    }

    g_rewind_capacity = capacity;
    g_rewind_head = 0;
    g_rewind_count = 0;

    LOGI("Rewind initialized: %d slots x %zu bytes = %.1f MB",
         capacity, g_rewind_state_size,
         (capacity * g_rewind_state_size) / (1024.0 * 1024.0));

    return 0;
}

void yage_core_rewind_deinit(YageCore* core) {
    (void)core;

    if (g_rewind_snapshots) {
        for (int i = 0; i < g_rewind_capacity; i++) {
            if (g_rewind_snapshots[i]) free(g_rewind_snapshots[i]);
        }
        free(g_rewind_snapshots);
        g_rewind_snapshots = NULL;
    }

    g_rewind_head = 0;
    g_rewind_count = 0;
    g_rewind_capacity = 0;
    g_rewind_state_size = 0;
}

int yage_core_rewind_push(YageCore* core) {
    if (!core || !core->retro_serialize || !g_rewind_snapshots) return -1;
    if (g_rewind_capacity == 0 || g_rewind_state_size == 0) return -1;

    if (!core->retro_serialize(g_rewind_snapshots[g_rewind_head], g_rewind_state_size)) {
        return -1;
    }

    g_rewind_head = (g_rewind_head + 1) % g_rewind_capacity;
    if (g_rewind_count < g_rewind_capacity) {
        g_rewind_count++;
    }

    return 0;
}

int yage_core_rewind_pop(YageCore* core) {
    if (!core || !core->retro_unserialize || !g_rewind_snapshots) return -1;
    if (g_rewind_count == 0) return -1;

    /* Move head back one position */
    g_rewind_head = (g_rewind_head - 1 + g_rewind_capacity) % g_rewind_capacity;
    g_rewind_count--;

    /* Restore the state */
    if (!core->retro_unserialize(g_rewind_snapshots[g_rewind_head], g_rewind_state_size)) {
        return -1;
    }

    return 0;
}

int yage_core_rewind_count(YageCore* core) {
    (void)core;
    return g_rewind_count;
}

/* Resolve an emulated address to a host pointer using the stored map. */
static uint8_t* resolve_address(uint32_t addr) {
    /* Fast path: check the cached I/O region first */
    if (g_io_ptr && addr >= g_io_start && addr < g_io_start + g_io_len) {
        return g_io_ptr + (addr - g_io_start);
    }
    /* Slow path: scan all stored regions */
    for (int i = 0; i < g_mem_region_count; i++) {
        struct yage_mem_region* r = &g_mem_regions[i];
        if (addr >= r->start && addr < r->start + r->len) {
            return (uint8_t*)r->ptr + (addr - r->start);
        }
    }
    return NULL;
}

/* ── GB/GBC SIO register addresses ── */
#define GB_REG_SB 0xFF01   /* Serial transfer data                      */
#define GB_REG_SC 0xFF02   /* Serial transfer control                   */
#define GB_REG_IF 0xFF0F   /* Interrupt flag                            */

/* SC bit masks */
#define SC_TRANSFER_START 0x80   /* Bit 7: transfer active / requested  */
#define SC_CLOCK_INTERNAL 0x01   /* Bit 0: 1 = internal clock (master)  */

/* IF bit for serial interrupt */
#define IF_SERIAL 0x08   /* Bit 3 */

/* ── Public API implementations ── */

int yage_core_link_is_supported(YageCore* core) {
    (void)core;
    return g_io_ptr != NULL ? 1 : 0;
}

int yage_core_link_read_byte(YageCore* core, uint32_t addr) {
    (void)core;
    uint8_t* p = resolve_address(addr);
    if (!p) return -1;
    return (int)*p;
}

int yage_core_link_write_byte(YageCore* core, uint32_t addr, uint8_t value) {
    (void)core;
    uint8_t* p = resolve_address(addr);
    if (!p) return -1;
    *p = value;
    return 0;
}

int yage_core_link_get_transfer_status(YageCore* core) {
    (void)core;
    if (!g_io_ptr) return -1;

    /* Only GB/GBC SIO is supported for now */
    if (g_io_start != 0xFF00) return -1;

    uint8_t* sc = resolve_address(GB_REG_SC);
    if (!sc) return -1;

    if (*sc & SC_TRANSFER_START) {
        /* Transfer requested — check if master (internal clock) */
        return (*sc & SC_CLOCK_INTERNAL) ? 1 : 0;
    }
    return 0; /* idle */
}

int yage_core_link_exchange_data(YageCore* core, uint8_t incoming) {
    (void)core;
    if (!g_io_ptr || g_io_start != 0xFF00) return -1;

    uint8_t* sb = resolve_address(GB_REG_SB);
    uint8_t* sc = resolve_address(GB_REG_SC);
    uint8_t* if_reg = resolve_address(GB_REG_IF);
    if (!sb || !sc || !if_reg) return -1;

    /* Capture outgoing byte before overwriting */
    int outgoing = (int)*sb;

    /* Write incoming data from the remote player */
    *sb = incoming;

    /* Clear the transfer-start flag (transfer complete) */
    *sc &= ~SC_TRANSFER_START;

    /* Trigger serial interrupt so the game knows the transfer finished */
    *if_reg |= IF_SERIAL;

    return outgoing;
}

/*
 * ============================================================
 * Memory Read API (for RetroAchievements runtime)
 *
 * Uses the memory map obtained via RETRO_ENVIRONMENT_SET_MEMORY_MAPS
 * to read arbitrary emulated addresses. Falls back to libretro
 * retro_get_memory_data for standard region reads.
 * ============================================================
 */

int yage_core_read_memory(YageCore* core, uint32_t address, int32_t count, uint8_t* buffer) {
    (void)core;
    if (!buffer || count <= 0) return -1;

    /*
     * Use the memory map obtained via RETRO_ENVIRONMENT_SET_MEMORY_MAPS.
     * mGBA exposes the full GBA address space through this map, including:
     *   0x02000000  EWRAM (256 KB)
     *   0x03000000  IWRAM (32 KB)
     *   0x04000000  I/O registers
     *   0x05000000  Palette RAM
     *   0x06000000  VRAM
     *   0x07000000  OAM
     *   0x08000000+ ROM
     *   0x0E000000  SRAM/Flash
     *
     * resolve_address() scans the stored regions to find the host pointer
     * for any emulated address. If not found, we return 0 for that byte.
     */
    for (int32_t i = 0; i < count; i++) {
        uint8_t* p = resolve_address(address + (uint32_t)i);
        buffer[i] = p ? *p : 0;
    }
    return count;
}

int yage_core_get_memory_size(YageCore* core, int32_t region_id) {
    if (!core || !core->retro_get_memory_size) return 0;
    return (int)core->retro_get_memory_size((unsigned)region_id);
}

/* Case-insensitive string compare for cross-platform */
#ifdef _WIN32
#define strcasecmp _stricmp
#endif

/* ════════════════════════════════════════════════════════════════════════
 *  Android Texture Rendering — ANativeWindow + JNI bridge
 *
 *  Writes RGBA pixels from g_video_buffer directly to a SurfaceTexture
 *  (via ANativeWindow).  Flutter's Texture widget composites the result
 *  with zero Dart-side buffer copies.
 * ════════════════════════════════════════════════════════════════════════ */

#ifdef __ANDROID__

/* Blit g_video_buffer → ANativeWindow.  Protected by g_nw_mutex so
 * nativeReleaseSurface never releases while we're blitting (use-after-free).
 * Returns 0 on success, -1 on failure. */
static int blit_to_native_window(void) {
    pthread_mutex_lock(&g_nw_mutex);
    ANativeWindow* win = g_native_window;
    if (!win || !g_video_buffer) {
        pthread_mutex_unlock(&g_nw_mutex);
        return -1;
    }

    int w = g_width;
    int h = g_height;
    if (w <= 0 || h <= 0) {
        pthread_mutex_unlock(&g_nw_mutex);
        return -1;
    }

    /* Reconfigure buffer geometry when the resolution changes
     * (e.g. GB 160×144 → SGB 256×224). */
    if (w != g_nw_configured_w || h != g_nw_configured_h) {
        ANativeWindow_setBuffersGeometry(win, w, h, WINDOW_FORMAT_RGBA_8888);
        g_nw_configured_w = w;
        g_nw_configured_h = h;
        LOGI("ANativeWindow geometry set to %dx%d", w, h);
    }

    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(win, &buf, NULL) != 0) {
        pthread_mutex_unlock(&g_nw_mutex);
        return -1;
    }

    uint32_t* dst = (uint32_t*)buf.bits;
    uint32_t* src = g_video_buffer;

    if (buf.stride == w) {
        /* Fast path: no stride mismatch — single memcpy */
        memcpy(dst, src, (size_t)w * h * sizeof(uint32_t));
    } else {
        /* Stride-aware row-by-row copy */
        for (int y = 0; y < h; y++) {
            memcpy(dst + y * buf.stride, src + y * w,
                   (size_t)w * sizeof(uint32_t));
        }
    }

    ANativeWindow_unlockAndPost(win);
    pthread_mutex_unlock(&g_nw_mutex);
    return 0;
}

/* ── JNI functions — called from Kotlin YageTextureBridge ──────────── */

JNIEXPORT void JNICALL
Java_com_yourmateapps_retropal_YageTextureBridge_nativeSetSurface(
        JNIEnv* env, jclass clazz, jobject surface) {
    (void)clazz;

    pthread_mutex_lock(&g_nw_mutex);
    /* Release any previously attached window */
    if (g_native_window) {
        ANativeWindow_release(g_native_window);
        g_native_window = NULL;
        g_nw_configured_w = 0;
        g_nw_configured_h = 0;
    }

    if (surface) {
        g_native_window = ANativeWindow_fromSurface(env, surface);
        if (g_native_window) {
            ANativeWindow_setBuffersGeometry(
                g_native_window, g_width, g_height, WINDOW_FORMAT_RGBA_8888);
            g_nw_configured_w = g_width;
            g_nw_configured_h = g_height;
            LOGI("ANativeWindow attached (%dx%d)", g_width, g_height);
        } else {
            LOGE("ANativeWindow_fromSurface returned NULL");
        }
    }
    pthread_mutex_unlock(&g_nw_mutex);
}

JNIEXPORT void JNICALL
Java_com_yourmateapps_retropal_YageTextureBridge_nativeReleaseSurface(
        JNIEnv* env, jclass clazz) {
    (void)env; (void)clazz;

    pthread_mutex_lock(&g_nw_mutex);
    if (g_native_window) {
        ANativeWindow* old = g_native_window;
        g_native_window = NULL;
        g_nw_configured_w = 0;
        g_nw_configured_h = 0;
        pthread_mutex_unlock(&g_nw_mutex);
        /* Release outside lock — safe: no blit can start (g_native_window is NULL) */
        ANativeWindow_release(old);
        LOGI("ANativeWindow released");
    } else {
        pthread_mutex_unlock(&g_nw_mutex);
    }
}

#endif /* __ANDROID__ */

/* ── Public API: yage_texture_blit ─────────────────────────────────── */

YAGE_API int yage_texture_blit(YageCore* core) {
    (void)core;
#ifdef __ANDROID__
    return blit_to_native_window();
#else
    return -1;  /* no texture surface on non-Android platforms */
#endif
}

YAGE_API int32_t yage_texture_is_attached(YageCore* core) {
    (void)core;
#ifdef __ANDROID__
    return g_native_window != NULL ? 1 : 0;
#else
    return 0;
#endif
}

/* ════════════════════════════════════════════════════════════════════════
 *  Native Frame Loop — pthread implementation (POSIX only)
 *
 *  The emulation runs on a dedicated thread with nanosleep-based timing.
 *  A display callback is fired at ~60 Hz regardless of emulation speed,
 *  freeing the Dart/UI thread from per-frame Timer callbacks.
 * ════════════════════════════════════════════════════════════════════════ */

#ifndef _WIN32

static void* frame_loop_thread(void* arg) {
    YageCore* core = (YageCore*)arg;

    struct timespec last_time;
    clock_gettime(CLOCK_MONOTONIC, &last_time);

    int64_t emu_accum_ns     = 0;
    int64_t display_accum_ns = 0;
    int     total_frames     = 0;       /* for FPS counter */
    int     rewind_counter   = 0;

    struct timespec fps_time = last_time;

    LOGI("Frame loop thread started");

    while (atomic_load_explicit(&g_floop_running, memory_order_acquire)) {
        /* ── Measure elapsed wall-clock time ── */
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t elapsed_ns = (now.tv_sec - last_time.tv_sec) * 1000000000LL
                           + (now.tv_nsec - last_time.tv_nsec);
        last_time = now;

        emu_accum_ns     += elapsed_ns;
        display_accum_ns += elapsed_ns;

        /* ── Target emulation frame time (speed-dependent) ── */
        int speed_pct = atomic_load_explicit(&g_floop_speed_pct,
                                              memory_order_relaxed);
        if (speed_pct < 25) speed_pct = 25;
        int64_t target_ns = BASE_FRAME_NS * 100LL / speed_pct;

        /* ── Run emulation frames to catch up ── */
        int frames_run = 0;
        while (atomic_load_explicit(&g_floop_running, memory_order_relaxed) &&
               emu_accum_ns >= target_ns &&
               frames_run < 8) {

            g_audio_samples = 0;
            core->retro_run();
            total_frames++;

            /* Rewind capture */
            if (atomic_load_explicit(&g_floop_rewind_on, memory_order_relaxed)) {
                rewind_counter++;
                int interval = atomic_load_explicit(&g_floop_rewind_interval,
                                                     memory_order_relaxed);
                if (interval > 0 && rewind_counter >= interval) {
                    rewind_counter = 0;
                    yage_core_rewind_push(core);
                }
            }

            /* RetroAchievements per-frame evaluation */
            if (atomic_load_explicit(&g_floop_rcheevos_on, memory_order_relaxed)) {
                yage_rc_do_frame();
            }

            emu_accum_ns -= target_ns;
            frames_run++;
        }

        /* Reset if way behind to avoid spiral of death */
        if (emu_accum_ns > target_ns * 10) {
            emu_accum_ns = 0;
        }

        /* ── Display update at ~60 Hz ── */
        if (frames_run > 0 && display_accum_ns >= DISPLAY_INTERVAL_NS) {
            display_accum_ns -= DISPLAY_INTERVAL_NS;
            /* Prevent accumulator from growing unboundedly */
            if (display_accum_ns > DISPLAY_INTERVAL_NS * 3) {
                display_accum_ns = 0;
            }

            int w = g_width;
            int h = g_height;

#ifdef __ANDROID__
            /* Prefer zero-copy blit to ANativeWindow (Flutter Texture) */
            if (g_native_window) {
                blit_to_native_window();
            } else
#endif
            {
                /* Fallback: snapshot video buffer → display buffer for
                 * Dart-side decodeImageFromPixels path */
                size_t pixels = (size_t)w * h;
                if (g_display_buf && pixels <= g_display_buf_capacity && g_video_buffer) {
                    memcpy(g_display_buf, g_video_buffer,
                           pixels * sizeof(uint32_t));
                    g_display_width  = w;
                    g_display_height = h;
                }
            }

            /* Notify Dart (runs on the Dart event loop via NativeCallable).
             * With texture rendering this is only used for FPS tracking
             * and link cable polling — no pixel data is passed. */
            if (g_frame_callback) {
                g_frame_callback(frames_run);
            }
        }

        /* ── FPS calculation (every 500 ms) ── */
        int64_t fps_elapsed = (now.tv_sec - fps_time.tv_sec) * 1000000000LL
                            + (now.tv_nsec - fps_time.tv_nsec);
        if (fps_elapsed >= 500000000LL) {
            double fps = (double)total_frames * 1.0e9 / (double)fps_elapsed;
            atomic_store_explicit(&g_floop_fps_x100, (int)(fps * 100.0),
                                  memory_order_relaxed);
            total_frames = 0;
            fps_time = now;
        }

        /* ── Sleep until the next event (emulation tick or display) ── */
        int64_t next_emu_ns     = target_ns - emu_accum_ns;
        int64_t next_display_ns = DISPLAY_INTERVAL_NS - display_accum_ns;
        int64_t sleep_ns = next_emu_ns < next_display_ns
                         ? next_emu_ns : next_display_ns;

        if (sleep_ns > 500000) {  /* > 0.5 ms */
            struct timespec ts;
            ts.tv_sec  = sleep_ns / 1000000000LL;
            ts.tv_nsec = sleep_ns % 1000000000LL;
            nanosleep(&ts, NULL);
        }
    }

    LOGI("Frame loop thread exiting");
    return NULL;
}

/* ── Public API ───────────────────────────────────────────────────────── */

int yage_frame_loop_start(YageCore* core, yage_frame_callback_t callback) {
    if (!core || !core->game_loaded || !core->retro_run) return -1;
    if (atomic_load(&g_floop_running)) return -1;  /* already running */

    /* Allocate / reallocate display buffer to match video buffer */
    size_t needed = g_video_buffer_capacity;
    if (!g_display_buf || g_display_buf_capacity < needed) {
        free(g_display_buf);
        g_display_buf = (uint32_t*)malloc(needed * sizeof(uint32_t));
        if (!g_display_buf) {
            LOGE("Failed to allocate display buffer");
            return -1;
        }
        g_display_buf_capacity = needed;
    }
    memset(g_display_buf, 0, needed * sizeof(uint32_t));
    g_display_width  = g_width;
    g_display_height = g_height;

    g_frame_callback = callback;
    atomic_store_explicit(&g_floop_fps_x100, 0, memory_order_relaxed);
    atomic_store_explicit(&g_floop_running, 1, memory_order_release);

    int rc = pthread_create(&g_frame_thread, NULL, frame_loop_thread, core);
    if (rc != 0) {
        atomic_store(&g_floop_running, 0);
        g_frame_callback = NULL;
        LOGE("pthread_create failed: %d", rc);
        return -1;
    }

    LOGI("Native frame loop started (speed=%d%%)",
         atomic_load(&g_floop_speed_pct));
    return 0;
}

void yage_frame_loop_stop(YageCore* core) {
    (void)core;
    if (!atomic_load(&g_floop_running)) return;

    atomic_store_explicit(&g_floop_running, 0, memory_order_release);
    pthread_join(g_frame_thread, NULL);
    g_frame_callback = NULL;
    LOGI("Native frame loop stopped");
}

void yage_frame_loop_set_speed(YageCore* core, int32_t speed_percent) {
    (void)core;
    if (speed_percent < 25)  speed_percent = 25;
    if (speed_percent > 800) speed_percent = 800;
    atomic_store_explicit(&g_floop_speed_pct, speed_percent,
                          memory_order_relaxed);
}

void yage_frame_loop_set_rewind(YageCore* core,
                                 int32_t enabled, int32_t interval) {
    (void)core;
    atomic_store_explicit(&g_floop_rewind_on, enabled ? 1 : 0,
                          memory_order_relaxed);
    if (interval > 0) {
        atomic_store_explicit(&g_floop_rewind_interval, interval,
                              memory_order_relaxed);
    }
}

void yage_frame_loop_set_rcheevos(YageCore* core, int32_t enabled) {
    (void)core;
    atomic_store_explicit(&g_floop_rcheevos_on, enabled ? 1 : 0,
                          memory_order_relaxed);
}

int32_t yage_frame_loop_get_fps_x100(YageCore* core) {
    (void)core;
    return atomic_load_explicit(&g_floop_fps_x100, memory_order_relaxed);
}

uint32_t* yage_frame_loop_get_display_buffer(YageCore* core) {
    (void)core;
    return g_display_buf;
}

int32_t yage_frame_loop_get_display_width(YageCore* core) {
    (void)core;
    return g_display_width;
}

int32_t yage_frame_loop_get_display_height(YageCore* core) {
    (void)core;
    return g_display_height;
}

int32_t yage_frame_loop_is_running(YageCore* core) {
    (void)core;
    return atomic_load_explicit(&g_floop_running, memory_order_acquire);
}

#else /* _WIN32 — stubs so the symbols exist for the linker */

int  yage_frame_loop_start(YageCore* c, yage_frame_callback_t cb) {
    (void)c; (void)cb; return -1;
}
void  yage_frame_loop_stop(YageCore* c) { (void)c; }
void  yage_frame_loop_set_speed(YageCore* c, int32_t s) { (void)c; (void)s; }
void  yage_frame_loop_set_rewind(YageCore* c, int32_t e, int32_t i) {
    (void)c; (void)e; (void)i;
}
void  yage_frame_loop_set_rcheevos(YageCore* c, int32_t e) { (void)c; (void)e; }
int32_t   yage_frame_loop_get_fps_x100(YageCore* c) { (void)c; return 0; }
uint32_t* yage_frame_loop_get_display_buffer(YageCore* c) { (void)c; return NULL; }
int32_t   yage_frame_loop_get_display_width(YageCore* c) { (void)c; return 0; }
int32_t   yage_frame_loop_get_display_height(YageCore* c) { (void)c; return 0; }
int32_t   yage_frame_loop_is_running(YageCore* c) { (void)c; return 0; }

#endif /* _WIN32 */
