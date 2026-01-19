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
    
    char* save_dir;
    char* rom_path;
    YagePlatform platform;
    int initialized;
    int game_loaded;
    
    /* State buffer */
    void* state_buffer;
    size_t state_size;
};

/* Libretro callbacks */
static void video_refresh_callback(const void* data, unsigned width, unsigned height, size_t pitch) {
    if (!data || !g_video_buffer) return;
    
    g_width = width;
    g_height = height;
    
    /* Copy video data - assuming XRGB8888 format */
    const uint32_t* src = (const uint32_t*)data;
    size_t src_pitch = pitch / sizeof(uint32_t);
    
    for (unsigned y = 0; y < height; y++) {
        memcpy(&g_video_buffer[y * width], &src[y * src_pitch], width * sizeof(uint32_t));
    }
}

static size_t audio_sample_batch_callback(const int16_t* data, size_t frames) {
    if (!data || !g_audio_buffer) return frames;
    
    size_t samples = frames * 2; /* Stereo */
    if (samples > AUDIO_BUFFER_SIZE * 2) {
        samples = AUDIO_BUFFER_SIZE * 2;
    }
    
    memcpy(g_audio_buffer, data, samples * sizeof(int16_t));
    g_audio_samples = frames;
    
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

static bool environment_callback(unsigned cmd, void* data) {
    switch (cmd) {
        case 10: /* RETRO_ENVIRONMENT_SET_PIXEL_FORMAT */
            /* Accept any pixel format */
            return true;
        default:
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
    
    return 0;
}

void yage_core_destroy(YageCore* core) {
    if (!core) return;
    
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
    if (core->retro_get_system_av_info) {
        struct retro_system_av_info av_info;
        core->retro_get_system_av_info(&av_info);
        g_width = av_info.geometry.base_width;
        g_height = av_info.geometry.base_height;
    }
    
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

/* Case-insensitive string compare for cross-platform */
#ifdef _WIN32
#define strcasecmp _stricmp
#endif

