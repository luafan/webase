/*
 * luacurlimp.c - Lua binding for curl-impersonate (libcurl-impersonate)
 *
 * Coroutine-friendly: uses curl_multi + libevent (event_mgr_base from luafan)
 * so a request yields the calling Lua thread and resumes when done,
 * exactly like fan.http in luafan's http.c.  Multiple concurrent requests
 * are multiplexed on one CURLM without blocking the event loop.
 *
 * Usage (inside fan.loop / webase):
 *   local ci = require("curlimp")
 *   local ok, resp = ci.request{ url="https://...", target="chrome146", timeout=30 }
 *   -- resp.status / resp.headers / resp.body / resp.error
 *
 * Requires: fan (luafan) loaded first, so event_mgr_base() / FAN_RESUME
 *           / utlua_mainthread are available.
 * License: MIT
 */

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <curl/curl.h>
#include <event.h>
#include <event2/event.h>
#include <string.h>
#include <stdlib.h>

/* Provided by luafan fan.so */
extern struct event_base *event_mgr_base(void);
extern lua_State *utlua_mainthread(lua_State *L);
extern int (*FAN_RESUME)(lua_State *co, lua_State *from, int count);

/* extra API of libcurl-impersonate */
extern CURLcode curl_easy_impersonate(CURL *data, const char *target, int default_headers);

/* ------------------------------------------------------------------ */
/* per-request state                                                  */
/* ------------------------------------------------------------------ */
typedef struct _CI_Conn CI_Conn;
struct _CI_Conn {
    CURL *easy;
    char error[CURL_ERROR_SIZE];
    struct curl_slist *headers;

    char   *body; size_t body_len, body_cap;
    char   *hdrs; size_t hdrs_len, hdrs_cap;

    lua_State *co;          /* coroutine to resume */
    lua_State *mainthread;
    int coref;              /* registry ref of coroutine (unref on resume) */

    int completed;

    CI_Conn *next, *prev;   /* inflight list */
};

/* in-flight list so we can cleanup on lua close */
static CI_Conn *inflight_head = NULL;

static void inflight_add(CI_Conn *c) {
    c->prev = NULL; c->next = inflight_head;
    if (inflight_head) inflight_head->prev = c;
    inflight_head = c;
}
static void inflight_remove(CI_Conn *c) {
    if (c->prev) c->prev->next = c->next; else inflight_head = c->next;
    if (c->next) c->next->prev = c->prev;
    c->prev = c->next = NULL;
}

/* ------------------------------------------------------------------ */
/* buffer + curl write/header callbacks                               */
/* ------------------------------------------------------------------ */
/* returns 0 on realloc failure so write_cb/header_cb can signal curl error */
static int buf_app(char **buf, size_t *len, size_t *cap, const char *p, size_t n) {
    if (*len + n + 1 > *cap) {
        size_t nc = *cap ? *cap * 2 : 8192;
        while (nc < *len + n + 1) nc *= 2;
        char *nb = (char *)realloc(*buf, nc);
        if (!nb) return 0;
        *buf = nb; *cap = nc;
    }
    memcpy(*buf + *len, p, n);
    *len += n;
    (*buf)[*len] = '\0';
    return 1;
}

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *ud) {
    CI_Conn *c = (CI_Conn *)ud;
    size_t n = size * nmemb;
    /* returning less than n tells libcurl to abort with CURLE_WRITE_ERROR */
    return buf_app(&c->body, &c->body_len, &c->body_cap, ptr, n) ? n : 0;
}

static size_t header_cb(char *buffer, size_t size, size_t nitems, void *ud) {
    CI_Conn *c = (CI_Conn *)ud;
    size_t total = size * nitems;
    if (memchr(buffer, ':', total)) {
        if (!buf_app(&c->hdrs, &c->hdrs_len, &c->hdrs_cap, buffer, total))
            return 0;
    }
    return total;
}

/* ------------------------------------------------------------------ */
/* libevent + curl_multi plumbing (mirrors luafan http.c)             */
/* ------------------------------------------------------------------ */
typedef struct { curl_socket_t fd; struct event *ev; int evset; } CI_Sock;

static CURLM *ci_multi;
static struct event *ci_timeout_event;    /* from CURLMOPT_TIMERFUNCTION */
static struct event *ci_check_event;      /* deferred info check */
static int ci_running;

static void ci_check_cb(int fd, short kind, void *ud);
static void ci_complete(CI_Conn *c);
static void ci_resume_cb(int fd, short kind, void *ud);

/* timer from curl_multi: arm libevent timeout.
 * timeout_ms < 0 means "delete the timer" (libcurl contract). */
static int multi_timer_cb(CURLM *m, long timeout_ms, void *ud) {
    (void)m; (void)ud;
    if (!ci_timeout_event)
        return 0;
    if (timeout_ms < 0) {
        evtimer_del(ci_timeout_event);
        return 0;
    }
    struct timeval tv;
    tv.tv_sec  = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    evtimer_add(ci_timeout_event, &tv);
    return 0;
}

/* socket event from libevent -> drive multi */
static void ci_sock_cb(int fd, short kind, void *ud) {
    (void)ud;
    int action = (kind & EV_READ ? CURL_CSELECT_IN : 0) |
                 (kind & EV_WRITE ? CURL_CSELECT_OUT : 0);
    curl_multi_socket_action(ci_multi, fd, action, &ci_running);
    struct timeval tv = {0, 100};
    evtimer_add(ci_check_event, &tv);
    if (ci_running <= 0 && evtimer_pending(ci_timeout_event, NULL))
        evtimer_del(ci_timeout_event);
}

/* curl_multi timeout fired */
static void ci_timeout_cb(int fd, short kind, void *ud) {
    (void)fd; (void)kind; (void)ud;
    curl_multi_socket_action(ci_multi, CURL_SOCKET_TIMEOUT, 0, &ci_running);
    struct timeval tv = {0, 1000};
    evtimer_add(ci_check_event, &tv);
}

/* socket register/deregister from curl_multi */
static void ci_remsock(CI_Sock *f) {
    if (f) { if (f->evset) event_free(f->ev); free(f); }
}
static void ci_setsock(CI_Sock *f, curl_socket_t s, CURL *e, int act, void *data) {
    int kind = (act & CURL_POLL_IN ? EV_READ : 0) |
               (act & CURL_POLL_OUT ? EV_WRITE : 0) | EV_PERSIST;
    f->fd = s; f->evset = 1;
    if (f->ev) event_free(f->ev);
    f->ev = event_new(event_mgr_base(), s, kind, ci_sock_cb, data);
    event_add(f->ev, NULL);
}
static void ci_addsock(curl_socket_t s, CURL *easy, int action, void *data) {
    CI_Sock *f = (CI_Sock *)calloc(1, sizeof(CI_Sock));
    ci_setsock(f, s, easy, action, data);
    curl_multi_assign(ci_multi, s, f);
}
static int sock_cb(CURL *e, curl_socket_t s, int what, void *cbp, void *sockp) {
    CI_Sock *f = (CI_Sock *)sockp;
    if (what == CURL_POLL_REMOVE) {
        ci_remsock(f);
    } else if (!f) {
        ci_addsock(s, e, what, cbp);
    } else {
        ci_setsock(f, s, e, what, cbp);
    }
    return 0;
}

/* deferred check: process completed transfers and resume coroutines */
static void ci_check_cb(int fd, short kind, void *ud) {
    (void)fd; (void)kind; (void)ud;
    CURLMsg *msg; int msgs_left;
    while ((msg = curl_multi_info_read(ci_multi, &msgs_left))) {
        if (msg->msg != CURLMSG_DONE) continue;
        CURL *easy = msg->easy_handle;
        CI_Conn *c = NULL;
        curl_easy_getinfo(easy, CURLINFO_PRIVATE, &c);
        curl_multi_remove_handle(ci_multi, easy);
        if (c) {
            ci_complete(c);
            if (c->headers) curl_slist_free_all(c->headers);
            free(c);
        }
        curl_easy_cleanup(easy);
    }
}

/* resume the waiting coroutine (via 0-delay event, like http.c) */
typedef struct { struct event *ev; lua_State *co; int coref; lua_State *mt; } CI_Resume;
static void ci_resume_cb(int fd, short kind, void *ud) {
    (void)fd; (void)kind;
    CI_Resume *info = (CI_Resume *)ud;
    event_free(info->ev);

    /* co 栈上已 push (ok, resp) 两个值 */
    FAN_RESUME(info->co, NULL, 2);
    luaL_unref(info->mt, LUA_REGISTRYINDEX, info->coref);

    free(info);
}

/* fill result table + schedule resume */
static void ci_complete(CI_Conn *c) {
    if (c->completed) return;
    c->completed = 1;
    inflight_remove(c);

    lua_State *L = c->co;

    /* Match fan.http style: single table result; also support ok,resp via 2 values.
     * Push: true, {status, headers, body}  OR  false, errmsg
     */
    if (*c->error != 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, c->error);
    } else {
        long code = -1;
        double total = 0;
        curl_easy_getinfo(c->easy, CURLINFO_RESPONSE_CODE, &code);
        curl_easy_getinfo(c->easy, CURLINFO_TOTAL_TIME, &total);

        lua_pushboolean(L, 1);
        lua_createtable(L, 0, 5);
        lua_pushinteger(L, (lua_Integer)code);
        lua_setfield(L, -2, "status");
        lua_pushnumber(L, total);
        lua_setfield(L, -2, "total_time");

        lua_pushlstring(L, c->hdrs ? c->hdrs : "", c->hdrs_len);
        lua_setfield(L, -2, "headers");

        lua_pushlstring(L, c->body ? c->body : "", c->body_len);
        lua_setfield(L, -2, "body");
    }

    /* body/hdrs buffers no longer needed after pushlstring copies */
    free(c->body); c->body = NULL; c->body_len = 0;
    free(c->hdrs); c->hdrs = NULL; c->hdrs_len = 0;

    /* resume via 0-delay timer so we're out of the curl callback */
    CI_Resume *info = (CI_Resume *)malloc(sizeof(CI_Resume));
    if (!info) {
        /* cannot resume safely; unref co */
        luaL_unref(c->mainthread, LUA_REGISTRYINDEX, c->coref);
        return;
    }
    info->co = c->co;
    info->mt = c->mainthread;
    info->coref = c->coref;
    info->ev = evtimer_new(event_mgr_base(), ci_resume_cb, info);
    struct timeval tv = {0, 1};
    event_add(info->ev, &tv);
}

/* ------------------------------------------------------------------ */
/* Lua API: request{table} -> ok, resp (yields)                       */
/* ------------------------------------------------------------------ */
static int l_request(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    const char *url = NULL, *method = "GET", *target = "chrome146";
    const char *body = NULL; size_t body_len = 0;
    long timeout = 30L;
    int default_headers = 1, ssl_verify = 1;
    long low_speed_limit = 0L, low_speed_time = 0L;
    const char *proxy = NULL;
    long proxyport = 0;
    const char *proxyuser = NULL, *proxypassword = NULL;
    int proxytunnel = 0;

    lua_getfield(L, 1, "url");    if (lua_isstring(L,-1)) url = lua_tostring(L,-1); lua_pop(L,1);
    if (!url) return luaL_error(L, "url is required");
    lua_getfield(L, 1, "method"); if (lua_isstring(L,-1)) method = lua_tostring(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "target"); if (lua_isstring(L,-1)) target = lua_tostring(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "body");   if (lua_isstring(L,-1)) body = lua_tolstring(L,-1,&body_len); lua_pop(L,1);
    lua_getfield(L, 1, "timeout");if (lua_isnumber(L,-1)) timeout = (long)lua_tonumber(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "default_headers"); if (lua_isboolean(L,-1)) default_headers = lua_toboolean(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "ssl_verify");      if (lua_isboolean(L,-1)) ssl_verify = lua_toboolean(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "low_speed_limit"); if (lua_isnumber(L,-1)) low_speed_limit = (long)lua_tonumber(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "low_speed_time");  if (lua_isnumber(L,-1)) low_speed_time = (long)lua_tonumber(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "proxy");         if (lua_isstring(L,-1)) proxy = lua_tostring(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "proxyport");     if (lua_isnumber(L,-1)) proxyport = (long)lua_tonumber(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "proxyuser");     if (lua_isstring(L,-1)) proxyuser = lua_tostring(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "proxypassword"); if (lua_isstring(L,-1)) proxypassword = lua_tostring(L,-1); lua_pop(L,1);
    lua_getfield(L, 1, "proxytunnel");   if (lua_isboolean(L,-1)) proxytunnel = lua_toboolean(L,-1); lua_pop(L,1);

    /* ---- init CURLM once ---- */
    if (!ci_multi) {
        ci_multi = curl_multi_init();
        if (!ci_multi) return luaL_error(L, "curl_multi_init failed");
        curl_multi_setopt(ci_multi, CURLMOPT_SOCKETFUNCTION, sock_cb);
        curl_multi_setopt(ci_multi, CURLMOPT_SOCKETDATA, NULL);
        curl_multi_setopt(ci_multi, CURLMOPT_TIMERFUNCTION, multi_timer_cb);
        curl_multi_setopt(ci_multi, CURLMOPT_TIMERDATA, NULL);

        ci_timeout_event = evtimer_new(event_mgr_base(), ci_timeout_cb, NULL);
        ci_check_event   = evtimer_new(event_mgr_base(), ci_check_cb, NULL);
    }

    CI_Conn *c = (CI_Conn *)calloc(1, sizeof(CI_Conn));
    if (!c) return luaL_error(L, "out of memory");
    c->easy = curl_easy_init();
    if (!c->easy) { free(c); return luaL_error(L, "curl_easy_init failed"); }

    CURLcode rc = curl_easy_impersonate(c->easy, target, default_headers);
    if (rc != CURLE_OK) {
        curl_easy_cleanup(c->easy); free(c);
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "impersonate(%s): %s", target, curl_easy_strerror(rc));
        return 2;
    }

    curl_easy_setopt(c->easy, CURLOPT_URL, url);
    curl_easy_setopt(c->easy, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c->easy, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(c->easy, CURLOPT_TIMEOUT, timeout);
    curl_easy_setopt(c->easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c->easy, CURLOPT_SSL_VERIFYPEER, ssl_verify ? 1L : 0L);
    curl_easy_setopt(c->easy, CURLOPT_SSL_VERIFYHOST, ssl_verify ? 2L : 0L);
    /* Proxy: proxy alone accepts full URL (http://user:pass@host:port);
     * proxyport/proxyuser/proxypassword are optional overrides for host-only form.
     * proxytunnel=true forces CONNECT tunneling (required for HTTPS through HTTP proxy). */
    if (proxy) {
        curl_easy_setopt(c->easy, CURLOPT_PROXY, proxy);
        if (proxyport > 0)
            curl_easy_setopt(c->easy, CURLOPT_PROXYPORT, proxyport);
        if (proxyuser)
            curl_easy_setopt(c->easy, CURLOPT_PROXYUSERNAME, proxyuser);
        if (proxypassword)
            curl_easy_setopt(c->easy, CURLOPT_PROXYPASSWORD, proxypassword);
        if (proxytunnel)
            curl_easy_setopt(c->easy, CURLOPT_HTTPPROXYTUNNEL, 1L);
    }
    /* Abort transfer when throughput drops below low_speed_limit bytes/sec for
     * low_speed_time seconds. libcurl requires BOTH to be > 0 to activate. */
    if (low_speed_limit > 0 && low_speed_time > 0) {
        curl_easy_setopt(c->easy, CURLOPT_LOW_SPEED_LIMIT, low_speed_limit);
        curl_easy_setopt(c->easy, CURLOPT_LOW_SPEED_TIME, low_speed_time);
    }
    curl_easy_setopt(c->easy, CURLOPT_ERRORBUFFER, c->error);
    curl_easy_setopt(c->easy, CURLOPT_PRIVATE, c);
    curl_easy_setopt(c->easy, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(c->easy, CURLOPT_WRITEDATA, c);
    curl_easy_setopt(c->easy, CURLOPT_HEADERFUNCTION, header_cb);
    curl_easy_setopt(c->easy, CURLOPT_HEADERDATA, c);

    if (body) {
        /* CURLOPT_POST=1 primes the upload state machine (read from POSTFIELDS
         * buffer). Without it, CUSTOMREQUEST=PATCH/PUT under curl_easy_impersonate
         * leaves libcurl expecting a read callback and fails with
         * "client read function EOF fail, only 0/N of needed bytes read".
         * CUSTOMREQUEST then rewrites just the request-line verb.
         * COPYPOSTFIELDS must come AFTER POSTFIELDSIZE per libcurl docs when
         * the body is binary or contains NULs; harmless when ordered this way
         * for plain text too. */
        curl_easy_setopt(c->easy, CURLOPT_POST, 1L);
        curl_easy_setopt(c->easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_len);
        curl_easy_setopt(c->easy, CURLOPT_COPYPOSTFIELDS, body);
        if (strcmp(method, "GET") != 0 && strcmp(method, "POST") != 0)
            curl_easy_setopt(c->easy, CURLOPT_CUSTOMREQUEST, method);
    } else if (strcmp(method, "GET") != 0) {
        curl_easy_setopt(c->easy, CURLOPT_CUSTOMREQUEST, method);
    }

    /* extra headers */
    lua_getfield(L, 1, "headers");
    if (lua_istable(L, -1)) {
        size_t n = lua_rawlen(L, -1);
        for (size_t i = 1; i <= n; i++) {
            lua_rawgeti(L, -1, (lua_Integer)i);
            if (lua_isstring(L, -1))
                c->headers = curl_slist_append(c->headers, lua_tostring(L, -1));
            lua_pop(L, 1);
        }
        if (c->headers) curl_easy_setopt(c->easy, CURLOPT_HTTPHEADER, c->headers);
    }
    lua_pop(L, 1);

    /* ---- remember the coroutine ---- */
    c->mainthread = utlua_mainthread(L);
    c->co = L;
    lua_pushthread(L);
    c->coref = luaL_ref(L, LUA_REGISTRYINDEX);

    CURLMcode mrc = curl_multi_add_handle(ci_multi, c->easy);
    if (mrc != CURLM_OK) {
        luaL_unref(c->mainthread, LUA_REGISTRYINDEX, c->coref);
        if (c->headers) curl_slist_free_all(c->headers);
        curl_easy_cleanup(c->easy); free(c);
        return luaL_error(L, "curl_multi_add_handle: %s", curl_multi_strerror(mrc));
    }

    inflight_add(c);

    /* yield; coroutine is resumed with (ok, resp) pushed by ci_complete */
    return lua_yield(L, 0);
}

/* ------------------------------------------------------------------ */
/* Teardown (mirrors cleanup_http_curl in luafan http.c).
 *
 * Called from event_mgr while BOTH the event_base and the Lua state are
 * still alive. Must run before event_base_free: otherwise ci_timeout_event
 * stays pinned to a freed base and the next curl_multi_add_handle →
 * multi_timer_cb → event_add UAF crashes in pthread_mutex_lock.
 */
void cleanup_curlimp(void) {
    while (inflight_head) {
        CI_Conn *c = inflight_head;
        inflight_remove(c);

        if (!c->completed) {
            c->completed = 1;
            /* Abort without resume — drop the yielded coroutine ref. */
            if (c->mainthread && c->coref != LUA_NOREF) {
                luaL_unref(c->mainthread, LUA_REGISTRYINDEX, c->coref);
                c->coref = LUA_NOREF;
            }
        }

        if (c->headers) {
            curl_slist_free_all(c->headers);
            c->headers = NULL;
        }
        free(c->body);
        c->body = NULL;
        c->body_len = 0;
        free(c->hdrs);
        c->hdrs = NULL;
        c->hdrs_len = 0;

        if (c->easy) {
            if (ci_multi)
                curl_multi_remove_handle(ci_multi, c->easy);
            curl_easy_cleanup(c->easy);
            c->easy = NULL;
        }
        free(c);
    }

    if (ci_multi) {
        /* Socket/timer callbacks may run; base must still be valid. */
        curl_multi_cleanup(ci_multi);
        ci_multi = NULL;
    }
    if (ci_timeout_event) {
        event_free(ci_timeout_event);
        ci_timeout_event = NULL;
    }
    if (ci_check_event) {
        event_free(ci_check_event);
        ci_check_event = NULL;
    }
    ci_running = 0;
}

/* ------------------------------------------------------------------ */
static const struct luaL_Reg funcs[] = {
    {"request", l_request},
    {NULL, NULL}
};

int luaopen_curlimp(lua_State *L)
{
    luaL_newlib(L, funcs);
    return 1;
}
