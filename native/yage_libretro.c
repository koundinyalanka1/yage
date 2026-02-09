/*
 * YAGE Libretro Wrapper Implementation
 * 
 * Wraps libretro mGBA core for use with Flutter FFI
 */

#include "yage_libretro.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

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
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "YAGE", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "YAGE", __VA_ARGS__)
#else
#define LOGI(...) do { printf("[YAGE] "); printf(__VA_ARGS__); printf("\n"); } while(0)
#define LOGE(...) do { printf("[YAGE ERROR] "); printf(__VA_ARGS__); printf("\n"); } while(0)
#endif

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

#define AUDIO_BUFFER_SIZE 8192
#define VIDEO_BUFFER_SIZE (GBA_WIDTH * GBA_HEIGHT)

/* Global state for libretro callbacks */
static uint32_t* g_video_buffer = NULL;
static int16_t* g_audio_buffer = NULL;
static int g_audio_samples = 0;
static int g_width = GBA_WIDTH;
static int g_height = GBA_HEIGHT;
static uint32_t g_keys = 0;
static int g_pixel_format = RETRO_PIXEL_FORMAT_RGB565; /* Default format */

/* Audio volume control (0.0 = mute, 1.0 = full volume) */
static float g_volume = 1.0f;
static int g_audio_enabled = 1;

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
static int g_rate_detection_frames = 0;
static int g_rate_detection_samples = 0;
static int g_rate_detected = 0;
static double g_detected_rate = 0;

/* Continuous rate monitoring — catches games that change rate mid-play */
static int g_monitor_frames = 0;
static int g_monitor_samples = 0;
static int g_frames_since_reinit = 0;

/* Pre-buffer threshold — just enough for one OpenSL callback to avoid initial underrun */
#define PREBUFFER_SAMPLES (AUDIO_BUFFER_FRAMES)

/* Forward declarations */
static void shutdown_opensl_audio(void);
static int init_opensl_audio(double sample_rate);

/* Classify sample rate from average samples-per-frame.
 * GBA runs at ~59.7275 fps, so:
 *   65536 Hz → ~1097 samples/frame  (Pokemon, most GBA)
 *   48000 Hz → ~804 samples/frame   (some titles)
 *   32768 Hz → ~549 samples/frame   (Dragon Ball, some GB/GBA)
 *
 * Thresholds use midpoints between expected values, lowered slightly
 * because startup frames often produce fewer samples.
 */
static double classify_sample_rate(double samples_per_frame) {
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
    
    /* Log only first few frames to avoid spam */
    if (g_log_frame_count < 5) {
        LOGI("Video: %ux%u, pitch=%zu, format=%d", width, height, pitch, g_pixel_format);
        g_log_frame_count++;
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
     * PHASE 1: Initial rate detection (first 15 frames)
     * Start OpenSL ES only once we know the game's sample rate.
     * Audio is silent during detection (~250ms) but prevents garbled
     * output from a wrong rate.
     * ================================================================ */
    if (!g_rate_detected) {
        g_rate_detection_frames++;
        g_rate_detection_samples += frames;
        
        if (g_rate_detection_frames >= 15) {
            double avg_spf = (double)g_rate_detection_samples / g_rate_detection_frames;
            g_detected_rate = classify_sample_rate(avg_spf);
            
            LOGI("Initial rate detection: %.1f samples/frame → %.0f Hz",
                 avg_spf, g_detected_rate);
            
            init_opensl_audio(g_detected_rate);
            g_rate_detected = 1;
            g_frames_since_reinit = 0;
            g_monitor_frames = 0;
            g_monitor_samples = 0;
        }
        return frames;
    }
    
    /* ================================================================
     * PHASE 2: Continuous rate monitoring
     * Every ~2 seconds, check if the game's audio rate has changed
     * (e.g. different rate during menu vs gameplay). If it differs
     * from the current OpenSL rate, reinitialize.
     * ================================================================ */
    g_monitor_frames++;
    g_monitor_samples += frames;
    g_frames_since_reinit++;
    
    if (g_monitor_frames >= 120) { /* Check every ~2 seconds */
        double avg_spf = (double)g_monitor_samples / g_monitor_frames;
        double new_rate = classify_sample_rate(avg_spf);
        
        /* Only reinit if rate genuinely changed and we haven't just reinited */
        if (new_rate != g_detected_rate && g_frames_since_reinit > 180) {
            LOGI("Rate change detected: %.0f → %.0f Hz (%.1f samples/frame)",
                 g_detected_rate, new_rate, avg_spf);
            g_detected_rate = new_rate;
            init_opensl_audio(new_rate);
            g_frames_since_reinit = 0;
        }
        
        g_monitor_frames = 0;
        g_monitor_samples = 0;
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
         * 65536 Hz → 6554 samples max | 32768 Hz → 3277 samples max */
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
    
    /* Map libretro buttons to our key bits */
    switch (id) {
        case RETRO_DEVICE_ID_JOYPAD_A:      return (g_keys & (1 << 0)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_B:      return (g_keys & (1 << 1)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_SELECT: return (g_keys & (1 << 2)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_START:  return (g_keys & (1 << 3)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_RIGHT:  return (g_keys & (1 << 4)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_LEFT:   return (g_keys & (1 << 5)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_UP:     return (g_keys & (1 << 6)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_DOWN:   return (g_keys & (1 << 7)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_R:      return (g_keys & (1 << 8)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_L:      return (g_keys & (1 << 9)) ? 1 : 0;
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
                *(const char**)data = ".";
            }
            return true;
        case 15: /* RETRO_ENVIRONMENT_GET_VARIABLE */
            return false;
        case 16: /* RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE */
            return false;
        case 17: /* RETRO_ENVIRONMENT_SET_VARIABLES */
            return true;
        case 27: /* RETRO_ENVIRONMENT_GET_LOG_INTERFACE */
            return false;
        case 31: /* RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY */
            if (data) {
                *(const char**)data = ".";
            }
            return true;
        case 36:      /* RETRO_ENVIRONMENT_SET_MEMORY_MAPS (no experimental flag) */
        case 0x10024: /* RETRO_ENVIRONMENT_SET_MEMORY_MAPS (with experimental flag) */
            handle_set_memory_maps(data);
            return true;
        case 40: /* RETRO_ENVIRONMENT_GET_INPUT_BITMASKS */
            return true;
        default:
            if (g_log_frame_count < 5) {
                LOGI("Unhandled env cmd: %u", cmd);
            }
            return false;
    }
}

YageCore* yage_core_create(void) {
    YageCore* core = (YageCore*)calloc(1, sizeof(YageCore));
    if (!core) return NULL;
    
    /* Allocate video buffer */
    g_video_buffer = (uint32_t*)malloc(VIDEO_BUFFER_SIZE * sizeof(uint32_t));
    if (!g_video_buffer) {
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

int yage_core_init(YageCore* core) {
    if (!core) return -1;
    
    /* Try to load the libretro core */
#ifdef _WIN32
    core->lib = LOAD_LIBRARY("mgba_libretro.dll");
#elif defined(__ANDROID__)
    /* Try the standard Android libretro naming */
    core->lib = LOAD_LIBRARY("libmgba_libretro_android.so");
#else
    core->lib = LOAD_LIBRARY("libmgba_libretro.so");
#endif
    
    if (!core->lib) {
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
        } else if (strcasecmp(ext, ".gb") == 0) {
            core->platform = YAGE_PLATFORM_GB;
            g_width = GB_WIDTH;
            g_height = GB_HEIGHT;
        }
    }
    
    /* Load the ROM */
    struct retro_game_info info = {0};
    info.path = path;
    info.data = NULL;
    info.size = 0;
    info.meta = NULL;
    
    if (!core->retro_load_game(&info)) {
        return -1;
    }
    
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
        LOGI("AV Info: %ux%u, fps=%.2f, reported_sample_rate=%.0f", 
             g_width, g_height, av_info.timing.fps, reported_sample_rate);
    }
    
#ifdef __ANDROID__
    /* Shut down previous audio completely */
    shutdown_opensl_audio();
    
    /* Reset ALL rate detection & monitoring state for the new game */
    g_rate_detection_frames = 0;
    g_rate_detection_samples = 0;
    g_rate_detected = 0;
    g_detected_rate = 0;
    g_monitor_frames = 0;
    g_monitor_samples = 0;
    g_frames_since_reinit = 0;
    g_audio_started = 0;
    g_audio_batch_count = 0;
    g_overflow_count = 0;
    g_log_frame_count = 0;
    
    /* Don't start OpenSL ES yet — let rate detection in audio_sample_batch_callback
     * determine the correct rate first, then init. This prevents the garbled-audio
     * problem from starting at the wrong rate. */
    LOGI("Audio will auto-detect sample rate from first 15 frames (reported: %.0f Hz)",
         reported_sample_rate);
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
    g_keys = keys;
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

    if (capacity <= 0 || capacity > 256) capacity = 36;

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

