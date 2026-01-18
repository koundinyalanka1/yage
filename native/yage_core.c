/*
 * YAGE Core - mGBA Wrapper Implementation
 * 
 * This file implements the YAGE emulator core using the mGBA library.
 * It provides a simplified C interface for Flutter FFI integration.
 */

#include "yage_core.h"
#include <mgba/core/core.h>
#include <mgba/core/blip_buf.h>
#include <mgba/gba/core.h>
#include <mgba/gb/core.h>
#include <mgba-util/vfs.h>
#include <mgba-util/memory.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* GBA screen dimensions */
#define GBA_WIDTH 240
#define GBA_HEIGHT 160

/* GB/GBC screen dimensions */
#define GB_WIDTH 160
#define GB_HEIGHT 144

/* Audio configuration */
#define AUDIO_SAMPLE_RATE 48000
#define AUDIO_BUFFER_SIZE 4096

struct YageCore {
    struct mCore* core;
    uint32_t* video_buffer;
    int16_t* audio_buffer;
    int audio_samples;
    int width;
    int height;
    YagePlatform platform;
    char* save_dir;
    char* rom_path;
    uint32_t keys;
    int initialized;
};

static void yage_log_handler(struct mLogger* logger, int category, enum mLogLevel level, const char* format, va_list args) {
    /* Suppress logging or implement custom logging here */
    (void)logger;
    (void)category;
    (void)level;
    (void)format;
    (void)args;
}

static struct mLogger s_logger = {
    .log = yage_log_handler
};

YageCore* yage_core_create(void) {
    YageCore* yage = (YageCore*)calloc(1, sizeof(YageCore));
    if (!yage) return NULL;
    
    /* Allocate video buffer for largest supported resolution (GBA) */
    yage->video_buffer = (uint32_t*)malloc(GBA_WIDTH * GBA_HEIGHT * sizeof(uint32_t));
    if (!yage->video_buffer) {
        free(yage);
        return NULL;
    }
    
    /* Allocate audio buffer */
    yage->audio_buffer = (int16_t*)malloc(AUDIO_BUFFER_SIZE * 2 * sizeof(int16_t));
    if (!yage->audio_buffer) {
        free(yage->video_buffer);
        free(yage);
        return NULL;
    }
    
    yage->width = GBA_WIDTH;
    yage->height = GBA_HEIGHT;
    yage->platform = YAGE_PLATFORM_UNKNOWN;
    yage->initialized = 0;
    
    return yage;
}

int yage_core_init(YageCore* core) {
    if (!core) return -1;
    
    mLogSetDefaultLogger(&s_logger);
    core->initialized = 1;
    
    return 0;
}

void yage_core_destroy(YageCore* core) {
    if (!core) return;
    
    if (core->core) {
        core->core->deinit(core->core);
        core->core = NULL;
    }
    
    if (core->video_buffer) {
        free(core->video_buffer);
        core->video_buffer = NULL;
    }
    
    if (core->audio_buffer) {
        free(core->audio_buffer);
        core->audio_buffer = NULL;
    }
    
    if (core->save_dir) {
        free(core->save_dir);
        core->save_dir = NULL;
    }
    
    if (core->rom_path) {
        free(core->rom_path);
        core->rom_path = NULL;
    }
    
    free(core);
}

int yage_core_load_rom(YageCore* core, const char* path) {
    if (!core || !path || !core->initialized) return -1;
    
    /* Clean up existing core if any */
    if (core->core) {
        core->core->deinit(core->core);
        core->core = NULL;
    }
    
    /* Open the ROM file */
    struct VFile* vf = VFileOpen(path, O_RDONLY);
    if (!vf) return -1;
    
    /* Detect the platform and create appropriate core */
    core->core = mCoreFindVF(vf);
    if (!core->core) {
        vf->close(vf);
        return -1;
    }
    
    /* Initialize the core */
    if (!core->core->init(core->core)) {
        core->core = NULL;
        vf->close(vf);
        return -1;
    }
    
    /* Set up video buffer */
    core->core->setVideoBuffer(core->core, core->video_buffer, GBA_WIDTH);
    
    /* Get screen dimensions */
    unsigned width, height;
    core->core->desiredVideoDimensions(core->core, &width, &height);
    core->width = width;
    core->height = height;
    
    /* Detect platform */
    switch (core->core->platform(core->core)) {
        case mPLATFORM_GBA:
            core->platform = YAGE_PLATFORM_GBA;
            break;
        case mPLATFORM_GB:
            /* Check if it's GBC */
            if (core->core->isROM(vf) && height == GB_HEIGHT) {
                /* Further detection could be done here */
                core->platform = YAGE_PLATFORM_GB;
            }
            break;
        default:
            core->platform = YAGE_PLATFORM_UNKNOWN;
            break;
    }
    
    /* Set up audio */
    core->core->setAudioBufferSize(core->core, AUDIO_BUFFER_SIZE);
    
    struct blip_t* left = NULL;
    struct blip_t* right = NULL;
    core->core->getAudioChannel(core->core, 0, &left);
    core->core->getAudioChannel(core->core, 1, &right);
    if (left) blip_set_rates(left, core->core->frequency(core->core), AUDIO_SAMPLE_RATE);
    if (right) blip_set_rates(right, core->core->frequency(core->core), AUDIO_SAMPLE_RATE);
    
    /* Load the ROM */
    if (!core->core->loadROM(core->core, vf)) {
        core->core->deinit(core->core);
        core->core = NULL;
        return -1;
    }
    
    /* Store ROM path */
    if (core->rom_path) free(core->rom_path);
    core->rom_path = strdup(path);
    
    /* Set save directory if configured */
    if (core->save_dir) {
        core->core->setPeriodicConfigPath(core->core, core->save_dir);
    }
    
    /* Reset and start */
    core->core->reset(core->core);
    
    return 0;
}

int yage_core_load_bios(YageCore* core, const char* path) {
    if (!core || !core->core || !path) return -1;
    
    struct VFile* vf = VFileOpen(path, O_RDONLY);
    if (!vf) return -1;
    
    if (!core->core->loadBIOS(core->core, vf, 0)) {
        vf->close(vf);
        return -1;
    }
    
    return 0;
}

void yage_core_set_save_dir(YageCore* core, const char* path) {
    if (!core || !path) return;
    
    if (core->save_dir) free(core->save_dir);
    core->save_dir = strdup(path);
    
    if (core->core) {
        core->core->setPeriodicConfigPath(core->core, core->save_dir);
    }
}

void yage_core_reset(YageCore* core) {
    if (!core || !core->core) return;
    core->core->reset(core->core);
}

void yage_core_run_frame(YageCore* core) {
    if (!core || !core->core) return;
    
    /* Set keys */
    core->core->setKeys(core->core, core->keys);
    
    /* Run one frame */
    core->core->runFrame(core->core);
    
    /* Get audio samples */
    struct blip_t* left = NULL;
    struct blip_t* right = NULL;
    core->core->getAudioChannel(core->core, 0, &left);
    core->core->getAudioChannel(core->core, 1, &right);
    
    if (left && right) {
        int available = blip_samples_avail(left);
        if (available > AUDIO_BUFFER_SIZE) {
            available = AUDIO_BUFFER_SIZE;
        }
        
        if (available > 0) {
            blip_read_samples(left, core->audio_buffer, available, 1);
            blip_read_samples(right, core->audio_buffer + 1, available, 1);
            core->audio_samples = available;
        } else {
            core->audio_samples = 0;
        }
    }
}

void yage_core_set_keys(YageCore* core, uint32_t keys) {
    if (!core) return;
    core->keys = keys;
}

uint32_t* yage_core_get_video_buffer(YageCore* core) {
    if (!core) return NULL;
    return core->video_buffer;
}

int yage_core_get_width(YageCore* core) {
    if (!core) return 0;
    return core->width;
}

int yage_core_get_height(YageCore* core) {
    if (!core) return 0;
    return core->height;
}

int16_t* yage_core_get_audio_buffer(YageCore* core) {
    if (!core) return NULL;
    return core->audio_buffer;
}

int yage_core_get_audio_samples(YageCore* core) {
    if (!core) return 0;
    return core->audio_samples;
}

int yage_core_save_state(YageCore* core, int slot) {
    if (!core || !core->core || slot < 0 || slot > 9) return -1;
    
    /* Create state path */
    char state_path[1024];
    if (core->save_dir && core->rom_path) {
        const char* rom_name = strrchr(core->rom_path, '/');
        if (!rom_name) rom_name = strrchr(core->rom_path, '\\');
        if (!rom_name) rom_name = core->rom_path;
        else rom_name++;
        
        snprintf(state_path, sizeof(state_path), "%s/%s.ss%d", 
                 core->save_dir, rom_name, slot);
    } else {
        return -1;
    }
    
    struct VFile* vf = VFileOpen(state_path, O_WRONLY | O_CREAT | O_TRUNC);
    if (!vf) return -1;
    
    if (!core->core->saveState(core->core, vf)) {
        vf->close(vf);
        return -1;
    }
    
    vf->close(vf);
    return 0;
}

int yage_core_load_state(YageCore* core, int slot) {
    if (!core || !core->core || slot < 0 || slot > 9) return -1;
    
    /* Create state path */
    char state_path[1024];
    if (core->save_dir && core->rom_path) {
        const char* rom_name = strrchr(core->rom_path, '/');
        if (!rom_name) rom_name = strrchr(core->rom_path, '\\');
        if (!rom_name) rom_name = core->rom_path;
        else rom_name++;
        
        snprintf(state_path, sizeof(state_path), "%s/%s.ss%d", 
                 core->save_dir, rom_name, slot);
    } else {
        return -1;
    }
    
    struct VFile* vf = VFileOpen(state_path, O_RDONLY);
    if (!vf) return -1;
    
    if (!core->core->loadState(core->core, vf)) {
        vf->close(vf);
        return -1;
    }
    
    vf->close(vf);
    return 0;
}

int yage_core_get_platform(YageCore* core) {
    if (!core) return YAGE_PLATFORM_UNKNOWN;
    return core->platform;
}

