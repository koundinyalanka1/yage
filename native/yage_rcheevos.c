/*
 * YAGE rcheevos Integration — Implementation
 *
 * Bridges the official rcheevos rc_client library to Dart via FFI.
 * Uses a polling-based HTTP bridge and event queue.
 */

#include "yage_rcheevos.h"
#include "yage_libretro.h"  /* For YageCore and memory read */
#include "rcheevos/include/rc_client.h"
#include "rcheevos/include/rc_consoles.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef __ANDROID__
#include <android/log.h>
#define RC_LOGI(...) __android_log_print(ANDROID_LOG_INFO, "YAGE_RC", __VA_ARGS__)
#define RC_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "YAGE_RC", __VA_ARGS__)
#else
#define RC_LOGI(...) do { printf("[YAGE_RC] "); printf(__VA_ARGS__); printf("\n"); } while(0)
#define RC_LOGE(...) do { printf("[YAGE_RC ERROR] "); printf(__VA_ARGS__); printf("\n"); } while(0)
#endif

/* ═══════════════════════════════════════════════════════════════════════
 *  Global State
 * ═══════════════════════════════════════════════════════════════════════ */

static rc_client_t* g_rc_client = NULL;
static YageCore* g_yage_core = NULL;

/* Cached console memory regions for address translation.
 * rcheevos uses virtual addresses (e.g. 0x000000 for GBA IWRAM) while
 * the emulator uses hardware addresses (e.g. 0x03000000 for GBA IWRAM).
 * Set when a game is loaded, cleared when unloaded. */
static const rc_memory_regions_t* g_memory_regions = NULL;

/* ═══════════════════════════════════════════════════════════════════════
 *  HTTP Request Queue
 *
 *  rc_client calls our server_call function with a request.
 *  We store it here for Dart to pick up and fulfill.
 * ═══════════════════════════════════════════════════════════════════════ */

#define MAX_PENDING_REQUESTS 32

typedef struct {
    int active;                            /* 1 if this slot is in use */
    uint32_t id;                           /* Unique request ID */
    char* url;                             /* URL to request (heap copy) */
    char* post_data;                       /* POST body or NULL (heap copy) */
    char* content_type;                    /* Content-Type or NULL (heap copy) */
    rc_client_server_callback_t callback;  /* rc_client's response handler */
    void* callback_data;                   /* Opaque data for callback */
} pending_request_t;

static pending_request_t g_requests[MAX_PENDING_REQUESTS];
static uint32_t g_next_request_id = 1;

/* ═══════════════════════════════════════════════════════════════════════
 *  Event Queue
 *
 *  rc_client fires events via callback.  We enqueue them here
 *  for Dart to poll.
 * ═══════════════════════════════════════════════════════════════════════ */

#define MAX_PENDING_EVENTS 64

static yage_rc_event_t g_events[MAX_PENDING_EVENTS];
static int g_event_read = 0;
static int g_event_write = 0;

static int event_queue_count(void) {
    return (g_event_write - g_event_read + MAX_PENDING_EVENTS) % MAX_PENDING_EVENTS;
}

static void enqueue_event(const yage_rc_event_t* ev) {
    int next = (g_event_write + 1) % MAX_PENDING_EVENTS;
    if (next == g_event_read) {
        /* Queue full — drop oldest */
        g_event_read = (g_event_read + 1) % MAX_PENDING_EVENTS;
        RC_LOGE("Event queue full — dropping oldest event");
    }
    g_events[g_event_write] = *ev;
    g_event_write = next;
}

static void enqueue_simple_event(uint32_t type) {
    yage_rc_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    enqueue_event(&ev);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  rc_client Callbacks
 * ═══════════════════════════════════════════════════════════════════════ */

/**
 * Translate a RetroAchievements virtual address to the emulator's hardware
 * address using the cached console memory regions.
 *
 * rcheevos uses a linearized address space where memory regions are laid out
 * sequentially.  For example, GBA maps:
 *   rcheevos 0x000000-0x007FFF  →  hardware 0x03000000 (IWRAM 32KB)
 *   rcheevos 0x008000-0x047FFF  →  hardware 0x02000000 (EWRAM 256KB)
 *   rcheevos 0x048000-0x057FFF  →  hardware 0x0E000000 (SRAM 64KB)
 *
 * For GB/GBC the virtual and real addresses happen to be identical, so
 * this translation is effectively a no-op for those consoles.
 *
 * Returns the hardware address, or the original address unchanged if no
 * mapping is found (graceful fallback).
 */
static uint32_t translate_address(uint32_t rc_address) {
    if (!g_memory_regions || g_memory_regions->num_regions == 0)
        return rc_address; /* no mapping available — pass through */

    for (uint32_t i = 0; i < g_memory_regions->num_regions; i++) {
        const rc_memory_region_t* region = &g_memory_regions->region[i];
        if (rc_address >= region->start_address &&
            rc_address <= region->end_address) {
            return region->real_address + (rc_address - region->start_address);
        }
    }

    /* Address not in any known region — pass through unchanged */
    return rc_address;
}

/**
 * Memory reader callback for rc_client.
 *
 * Translates rcheevos virtual addresses to the emulator's hardware
 * address space, then reads via yage_core_read_memory.
 *
 * The memory regions are lazily resolved on the first call where the
 * game is loaded.  This ensures they're available during the address
 * validation pass that rc_client runs BEFORE our load_game_callback.
 */
static uint32_t RC_CCONV memory_reader(uint32_t address, uint8_t* buffer,
                                        uint32_t num_bytes, rc_client_t* client) {
    if (!g_yage_core || !buffer || num_bytes == 0) return 0;

    /* Lazily resolve console memory regions for address translation.
     * rc_client sets client->game before calling validate_addresses,
     * so rc_client_get_game_info() is available here. */
    if (!g_memory_regions && client) {
        const rc_client_game_t* game = rc_client_get_game_info(client);
        if (game && game->console_id != 0) {
            g_memory_regions = rc_console_memory_regions(game->console_id);
            if (g_memory_regions) {
                RC_LOGI("Memory regions resolved: %u regions for console %u",
                        g_memory_regions->num_regions, game->console_id);
            }
        }
    }

    /* Fast path: if the entire read [address, address+num_bytes-1] fits in
     * a single rcheevos region, translate once and do a bulk read. */
    if (g_memory_regions && g_memory_regions->num_regions > 0) {
        uint32_t last = address + num_bytes - 1;
        for (uint32_t i = 0; i < g_memory_regions->num_regions; i++) {
            const rc_memory_region_t* r = &g_memory_regions->region[i];
            if (address >= r->start_address && last <= r->end_address) {
                uint32_t hw_addr = r->real_address + (address - r->start_address);
                int result = yage_core_read_memory(g_yage_core, hw_addr,
                                                    (int32_t)num_bytes, buffer);
                return (result > 0) ? (uint32_t)result : 0;
            }
        }
    }

    /* Slow path: translate each byte individually (handles cross-region
     * reads or when no region table is available yet). */
    for (uint32_t i = 0; i < num_bytes; i++) {
        uint32_t hw_addr = translate_address(address + i);
        uint8_t byte_val = 0;
        int result = yage_core_read_memory(g_yage_core, hw_addr, 1, &byte_val);
        if (result <= 0) return i; /* return number of bytes successfully read */
        buffer[i] = byte_val;
    }
    return num_bytes;
}

/**
 * Server call callback for rc_client.
 *
 * Called when rc_client needs to make an HTTP request.
 * We store the request for Dart to pick up and fulfill.
 */
static void RC_CCONV server_call(const rc_api_request_t* request,
                                  rc_client_server_callback_t callback,
                                  void* callback_data,
                                  rc_client_t* client) {
    (void)client;

    /* Find a free slot */
    int slot = -1;
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (!g_requests[i].active) {
            slot = i;
            break;
        }
    }

    if (slot < 0) {
        RC_LOGE("HTTP request queue full — dropping request!");
        /* Send an error response back to rc_client */
        rc_api_server_response_t response;
        memset(&response, 0, sizeof(response));
        response.http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
        callback(&response, callback_data);
        return;
    }

    pending_request_t* req = &g_requests[slot];
    req->active = 1;
    req->id = g_next_request_id++;
    req->url = request->url ? strdup(request->url) : NULL;
    req->post_data = request->post_data ? strdup(request->post_data) : NULL;
    req->content_type = request->content_type ? strdup(request->content_type) : NULL;
    req->callback = callback;
    req->callback_data = callback_data;

    RC_LOGI("HTTP request queued: id=%u, url=%s", req->id,
            req->url ? req->url : "(null)");
}

/**
 * Event handler callback for rc_client.
 *
 * Called when achievements are triggered, leaderboards change, etc.
 */
static void RC_CCONV event_handler(const rc_client_event_t* event,
                                    rc_client_t* client) {
    (void)client;
    if (!event) return;

    yage_rc_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = event->type;

    /* Copy achievement data if present */
    if (event->achievement) {
        ev.achievement_id = event->achievement->id;
        ev.achievement_points = event->achievement->points;
        ev.achievement_rarity = event->achievement->rarity;
        ev.achievement_rarity_hardcore = event->achievement->rarity_hardcore;
        ev.achievement_type = event->achievement->type;

        if (event->achievement->title) {
            strncpy(ev.achievement_title, event->achievement->title,
                    sizeof(ev.achievement_title) - 1);
        }
        if (event->achievement->description) {
            strncpy(ev.achievement_description, event->achievement->description,
                    sizeof(ev.achievement_description) - 1);
        }
        if (event->achievement->badge_url) {
            strncpy(ev.achievement_badge_url, event->achievement->badge_url,
                    sizeof(ev.achievement_badge_url) - 1);
        }
    }

    /* Copy server error data if present */
    if (event->server_error) {
        ev.error_code = event->server_error->result;
        if (event->server_error->error_message) {
            strncpy(ev.error_message, event->server_error->error_message,
                    sizeof(ev.error_message) - 1);
        }
    }

    switch (event->type) {
        case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
            RC_LOGI("Achievement triggered: \"%s\" (%u pts)",
                    ev.achievement_title, ev.achievement_points);
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_GAME_COMPLETED:
            RC_LOGI("Game completed!");
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_SERVER_ERROR:
            RC_LOGE("Server error: %s", ev.error_message);
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_DISCONNECTED:
            RC_LOGI("Disconnected from server");
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_RECONNECTED:
            RC_LOGI("Reconnected to server");
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_SUBSET_COMPLETED:
            RC_LOGI("Subset completed!");
            enqueue_event(&ev);
            break;

        /* ── Events we intentionally do NOT forward to Dart ──
         * Challenge / progress indicators carry achievement data for
         * UNEARNED achievements.  Forwarding them caused spurious
         * "achievement unlocked" toasts on GB/GBC games. */
        case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_SHOW:
        case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_HIDE:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE:
        case RC_CLIENT_EVENT_LEADERBOARD_STARTED:
        case RC_CLIENT_EVENT_LEADERBOARD_FAILED:
        case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED:
        case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_SHOW:
        case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_HIDE:
        case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_UPDATE:
        case RC_CLIENT_EVENT_LEADERBOARD_SCOREBOARD:
        case RC_CLIENT_EVENT_RESET:
            RC_LOGI("Event (not forwarded): type=%u", event->type);
            break;

        default:
            RC_LOGI("Unknown event: type=%u", event->type);
            break;
    }
}

/**
 * Log message callback for rc_client.
 */
static void RC_CCONV log_message(const char* message, const rc_client_t* client) {
    (void)client;
    RC_LOGI("rc_client: %s", message ? message : "(null)");
}

/**
 * Login completion callback.
 */
static void RC_CCONV login_callback(int result, const char* error_message,
                                     rc_client_t* client, void* userdata) {
    (void)client;
    (void)userdata;

    if (result == RC_OK) {
        const rc_client_user_t* user = rc_client_get_user_info(g_rc_client);
        RC_LOGI("Login successful: %s", user ? user->display_name : "unknown");
        enqueue_simple_event(YAGE_RC_EVENT_LOGIN_SUCCESS);
    } else {
        RC_LOGE("Login failed: %s (code %d)",
                error_message ? error_message : "unknown", result);
        yage_rc_event_t ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = YAGE_RC_EVENT_LOGIN_FAILED;
        ev.error_code = result;
        if (error_message) {
            strncpy(ev.error_message, error_message, sizeof(ev.error_message) - 1);
        }
        enqueue_event(&ev);
    }
}

/**
 * Game load completion callback.
 */
static void RC_CCONV load_game_callback(int result, const char* error_message,
                                          rc_client_t* client, void* userdata) {
    (void)client;
    (void)userdata;

    if (result == RC_OK) {
        const rc_client_game_t* game = rc_client_get_game_info(g_rc_client);
        RC_LOGI("Game loaded: \"%s\" (ID=%u, console=%u)",
                game ? game->title : "unknown",
                game ? game->id : 0,
                game ? game->console_id : 0);

        /* Ensure memory regions are cached (normally already done lazily
         * in memory_reader during address validation, but set here as
         * a safety net in case the lazy init didn't trigger). */
        if (!g_memory_regions && game) {
            g_memory_regions = rc_console_memory_regions(game->console_id);
        }

        enqueue_simple_event(YAGE_RC_EVENT_GAME_LOAD_SUCCESS);
    } else {
        RC_LOGE("Game load failed: %s (code %d)",
                error_message ? error_message : "unknown", result);
        yage_rc_event_t ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = YAGE_RC_EVENT_GAME_LOAD_FAILED;
        ev.error_code = result;
        if (error_message) {
            strncpy(ev.error_message, error_message, sizeof(ev.error_message) - 1);
        }
        enqueue_event(&ev);
    }
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Lifecycle
 * ═══════════════════════════════════════════════════════════════════════ */

int yage_rc_init(void* yage_core) {
    if (g_rc_client) {
        RC_LOGI("rc_client already initialized — destroying first");
        yage_rc_destroy();
    }

    g_yage_core = (YageCore*)yage_core;

    /* Clear queues */
    memset(g_requests, 0, sizeof(g_requests));
    g_next_request_id = 1;
    g_event_read = 0;
    g_event_write = 0;

    /* Create rc_client with our memory reader and server call handler */
    g_rc_client = rc_client_create(memory_reader, server_call);
    if (!g_rc_client) {
        RC_LOGE("Failed to create rc_client");
        return -1;
    }

    /* Set up event handler */
    rc_client_set_event_handler(g_rc_client, event_handler);

    /* Enable logging */
    rc_client_enable_logging(g_rc_client, RC_CLIENT_LOG_LEVEL_INFO, log_message);

    RC_LOGI("rc_client initialized (core=%p)", yage_core);
    return 0;
}

void yage_rc_destroy(void) {
    if (g_rc_client) {
        rc_client_destroy(g_rc_client);
        g_rc_client = NULL;
    }
    g_yage_core = NULL;
    g_memory_regions = NULL;

    /* Free any pending request strings */
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active) {
            free(g_requests[i].url);
            free(g_requests[i].post_data);
            free(g_requests[i].content_type);
        }
    }
    memset(g_requests, 0, sizeof(g_requests));

    RC_LOGI("rc_client destroyed");
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Configuration
 * ═══════════════════════════════════════════════════════════════════════ */

void yage_rc_set_hardcore(int enabled) {
    if (!g_rc_client) return;
    rc_client_set_hardcore_enabled(g_rc_client, enabled);
    RC_LOGI("Hardcore mode: %s", enabled ? "ON" : "OFF");
}

void yage_rc_set_encore(int enabled) {
    if (!g_rc_client) return;
    rc_client_set_encore_mode_enabled(g_rc_client, enabled);
    RC_LOGI("Encore mode: %s", enabled ? "ON" : "OFF");
}

int yage_rc_get_user_agent_clause(char* buffer, int buffer_size) {
    if (!g_rc_client || !buffer || buffer_size <= 0) return 0;
    return (int)rc_client_get_user_agent_clause(g_rc_client, buffer, (size_t)buffer_size);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — User / Session
 * ═══════════════════════════════════════════════════════════════════════ */

void yage_rc_begin_login(const char* username, const char* token) {
    if (!g_rc_client || !username || !token) return;
    RC_LOGI("Beginning login for user: %s", username);
    rc_client_begin_login_with_token(g_rc_client, username, token,
                                      login_callback, NULL);
}

int yage_rc_is_logged_in(void) {
    if (!g_rc_client) return 0;
    return rc_client_get_user_info(g_rc_client) != NULL ? 1 : 0;
}

const char* yage_rc_get_user_display_name(void) {
    if (!g_rc_client) return NULL;
    const rc_client_user_t* user = rc_client_get_user_info(g_rc_client);
    return user ? user->display_name : NULL;
}

void yage_rc_logout(void) {
    if (!g_rc_client) return;
    rc_client_logout(g_rc_client);
    RC_LOGI("User logged out");
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Game
 * ═══════════════════════════════════════════════════════════════════════ */

void yage_rc_begin_load_game(const char* hash) {
    if (!g_rc_client || !hash) return;
    RC_LOGI("Beginning game load for hash: %s", hash);
    rc_client_begin_load_game(g_rc_client, hash, load_game_callback, NULL);
}

int yage_rc_is_game_loaded(void) {
    if (!g_rc_client) return 0;
    return rc_client_is_game_loaded(g_rc_client);
}

const char* yage_rc_get_game_title(void) {
    if (!g_rc_client) return NULL;
    const rc_client_game_t* game = rc_client_get_game_info(g_rc_client);
    return game ? game->title : NULL;
}

uint32_t yage_rc_get_game_id(void) {
    if (!g_rc_client) return 0;
    const rc_client_game_t* game = rc_client_get_game_info(g_rc_client);
    return game ? game->id : 0;
}

const char* yage_rc_get_game_badge_url(void) {
    if (!g_rc_client) return NULL;
    const rc_client_game_t* game = rc_client_get_game_info(g_rc_client);
    return game ? game->badge_url : NULL;
}

void yage_rc_unload_game(void) {
    if (!g_rc_client) return;
    rc_client_unload_game(g_rc_client);
    g_memory_regions = NULL;
    RC_LOGI("Game unloaded");
}

void yage_rc_reset(void) {
    if (!g_rc_client) return;
    rc_client_reset(g_rc_client);
    RC_LOGI("Runtime reset");
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Frame Processing
 * ═══════════════════════════════════════════════════════════════════════ */

void yage_rc_do_frame(void) {
    if (!g_rc_client) return;
    rc_client_do_frame(g_rc_client);
}

void yage_rc_idle(void) {
    if (!g_rc_client) return;
    rc_client_idle(g_rc_client);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Achievement Info
 * ═══════════════════════════════════════════════════════════════════════ */

uint32_t yage_rc_get_achievement_count(void) {
    if (!g_rc_client) return 0;
    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(g_rc_client, &summary);
    return summary.num_core_achievements;
}

uint32_t yage_rc_get_unlocked_count(void) {
    if (!g_rc_client) return 0;
    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(g_rc_client, &summary);
    return summary.num_unlocked_achievements;
}

uint32_t yage_rc_get_total_points(void) {
    if (!g_rc_client) return 0;
    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(g_rc_client, &summary);
    return summary.points_core;
}

uint32_t yage_rc_get_unlocked_points(void) {
    if (!g_rc_client) return 0;
    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(g_rc_client, &summary);
    return summary.points_unlocked;
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — HTTP Bridge
 * ═══════════════════════════════════════════════════════════════════════ */

uint32_t yage_rc_get_pending_request(void) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active) {
            return g_requests[i].id;
        }
    }
    return 0;
}

const char* yage_rc_get_request_url(uint32_t request_id) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active && g_requests[i].id == request_id) {
            return g_requests[i].url;
        }
    }
    return NULL;
}

const char* yage_rc_get_request_post_data(uint32_t request_id) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active && g_requests[i].id == request_id) {
            return g_requests[i].post_data;
        }
    }
    return NULL;
}

const char* yage_rc_get_request_content_type(uint32_t request_id) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active && g_requests[i].id == request_id) {
            return g_requests[i].content_type;
        }
    }
    return NULL;
}

void yage_rc_submit_response(uint32_t request_id,
                              const char* body,
                              uint32_t body_length,
                              int http_status) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active && g_requests[i].id == request_id) {
            pending_request_t* req = &g_requests[i];

            RC_LOGI("HTTP response: id=%u, status=%d, len=%u",
                    request_id, http_status, body_length);

            /* Build the server response */
            rc_api_server_response_t response;
            memset(&response, 0, sizeof(response));
            response.body = body;
            response.body_length = (size_t)body_length;
            response.http_status_code = http_status;

            /* Call rc_client's callback with the response */
            rc_client_server_callback_t cb = req->callback;
            void* cb_data = req->callback_data;

            /* Free the request slot BEFORE calling the callback,
             * because the callback may trigger new requests */
            free(req->url);
            free(req->post_data);
            free(req->content_type);
            memset(req, 0, sizeof(pending_request_t));

            /* Deliver the response */
            cb(&response, cb_data);
            return;
        }
    }

    RC_LOGE("HTTP response for unknown request id=%u", request_id);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Event Bridge
 * ═══════════════════════════════════════════════════════════════════════ */

int yage_rc_has_pending_event(void) {
    return g_event_read != g_event_write ? 1 : 0;
}

int yage_rc_get_pending_event(yage_rc_event_t* out_event) {
    if (!out_event || g_event_read == g_event_write) return 0;
    *out_event = g_events[g_event_read];
    return 1;
}

void yage_rc_consume_event(void) {
    if (g_event_read != g_event_write) {
        g_event_read = (g_event_read + 1) % MAX_PENDING_EVENTS;
    }
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — State
 * ═══════════════════════════════════════════════════════════════════════ */

int yage_rc_get_load_game_state(void) {
    if (!g_rc_client) return 0;
    return rc_client_get_load_game_state(g_rc_client);
}

int yage_rc_is_processing_required(void) {
    if (!g_rc_client) return 0;
    return rc_client_is_processing_required(g_rc_client);
}

int yage_rc_get_hardcore_enabled(void) {
    if (!g_rc_client) return 0;
    return rc_client_get_hardcore_enabled(g_rc_client);
}
