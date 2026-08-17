/*
 * luagcm.c - Lua binding for AES-GCM with AAD support
 *
 * Uses OpenSSL EVP_aead API (BoringSSL-style) when available, falling back to
 * the classic EVP_EncryptUpdate(ctx, NULL, ...) for AAD on standard OpenSSL.
 *
 * Does NOT depend on fan.so or libevent — pure computation, links only -lcrypto.
 *
 * Usage:
 *   local gcm = require("gcm")
 *   local ct, tag = gcm.encrypt(key, nonce, plaintext, aad)
 *   local pt    = gcm.decrypt(key, nonce, ciphertext, tag, aad)
 *
 *   key:    16 bytes (AES-128) or 32 bytes (AES-256)
 *   nonce:  12 bytes (standard GCM nonce)
 *   aad:    optional string (may be empty "")
 *   tag:    16 bytes (authentication tag)
 *
 * Returns:
 *   encrypt: ciphertext, tag (two strings)
 *   decrypt: plaintext (string), or nil if tag verification failed
 *
 * License: MIT
 */

#include <lua.h>
#include <lauxlib.h>

#include <openssl/evp.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* helpers                                                            */
/* ------------------------------------------------------------------ */

static const EVP_CIPHER *gcm_cipher_for_keylen(size_t keylen) {
    switch (keylen) {
        case 16: return EVP_aes_128_gcm();
        case 32: return EVP_aes_256_gcm();
        default: return NULL;
    }
}

/* ------------------------------------------------------------------ */
/* gcm.encrypt(key, nonce, plaintext [, aad]) -> ct, tag              */
/* ------------------------------------------------------------------ */

static int lgcm_encrypt(lua_State *L) {
    size_t key_len, nonce_len, pt_len, aad_len = 0;
    const unsigned char *key   = (const unsigned char *)luaL_checklstring(L, 1, &key_len);
    const unsigned char *nonce = (const unsigned char *)luaL_checklstring(L, 2, &nonce_len);
    const unsigned char *pt    = (const unsigned char *)luaL_checklstring(L, 3, &pt_len);
    const unsigned char *aad   = NULL;

    if (lua_gettop(L) >= 4 && !lua_isnil(L, 4)) {
        aad = (const unsigned char *)luaL_checklstring(L, 4, &aad_len);
    }

    const EVP_CIPHER *cipher = gcm_cipher_for_keylen(key_len);
    if (!cipher) {
        return luaL_error(L, "key must be 16 or 32 bytes, got %d", (int)key_len);
    }
    if (nonce_len != 12) {
        return luaL_error(L, "nonce must be 12 bytes, got %d", (int)nonce_len);
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        return luaL_error(L, "EVP_CIPHER_CTX_new failed");
    }

    int ok = 1;
    int outlen = 0;

    /* init */
    if (ok && EVP_EncryptInit_ex(ctx, cipher, NULL, NULL, NULL) != 1) ok = 0;
    /* set IV len (12 is default, but be explicit) */
    if (ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)nonce_len, NULL) != 1) ok = 0;
    /* set key + nonce */
    if (ok && EVP_EncryptInit_ex(ctx, NULL, NULL, key, nonce) != 1) ok = 0;

    /* AAD: pass NULL output to tell OpenSSL this is additional data */
    if (ok && aad_len > 0) {
        if (EVP_EncryptUpdate(ctx, NULL, &outlen, aad, (int)aad_len) != 1) ok = 0;
    }

    /* encrypt plaintext */
    unsigned char *ct = NULL;
    int ct_len = 0;
    if (ok) {
        ct = (unsigned char *)lua_newuserdata(L, pt_len + 16); /* +16 for safety */
        if (EVP_EncryptUpdate(ctx, ct, &outlen, pt, (int)pt_len) != 1) {
            ok = 0;
        } else {
            ct_len = outlen;
        }
    }

    /* finalize (GCM has no padding, but must call Final) */
    int finlen = 0;
    if (ok) {
        if (EVP_EncryptFinal_ex(ctx, ct + ct_len, &finlen) != 1) {
            ok = 0;
        } else {
            ct_len += finlen;
        }
    }

    /* get tag */
    unsigned char tag[16];
    memset(tag, 0, sizeof(tag));
    if (ok) {
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag) != 1) {
            ok = 0;
        }
    }

    EVP_CIPHER_CTX_free(ctx);

    if (!ok) {
        lua_pop(L, 1); /* remove userdata if pushed */
        return luaL_error(L, "GCM encryption failed");
    }

    /* push ct string, then tag string */
    lua_pushlstring(L, (const char *)ct, ct_len);
    lua_pushlstring(L, (const char *)tag, 16);
    return 2;
}

/* ------------------------------------------------------------------ */
/* gcm.decrypt(key, nonce, ciphertext, tag [, aad]) -> pt | nil       */
/* ------------------------------------------------------------------ */

static int lgcm_decrypt(lua_State *L) {
    size_t key_len, nonce_len, ct_len, tag_len, aad_len = 0;
    const unsigned char *key   = (const unsigned char *)luaL_checklstring(L, 1, &key_len);
    const unsigned char *nonce = (const unsigned char *)luaL_checklstring(L, 2, &nonce_len);
    const unsigned char *ct    = (const unsigned char *)luaL_checklstring(L, 3, &ct_len);
    const unsigned char *tag   = (const unsigned char *)luaL_checklstring(L, 4, &tag_len);
    const unsigned char *aad   = NULL;

    if (lua_gettop(L) >= 5 && !lua_isnil(L, 5)) {
        aad = (const unsigned char *)luaL_checklstring(L, 5, &aad_len);
    }

    const EVP_CIPHER *cipher = gcm_cipher_for_keylen(key_len);
    if (!cipher) {
        return luaL_error(L, "key must be 16 or 32 bytes, got %d", (int)key_len);
    }
    if (nonce_len != 12) {
        return luaL_error(L, "nonce must be 12 bytes, got %d", (int)nonce_len);
    }
    if (tag_len != 16) {
        return luaL_error(L, "tag must be 16 bytes, got %d", (int)tag_len);
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        return luaL_error(L, "EVP_CIPHER_CTX_new failed");
    }

    int ok = 1;
    int outlen = 0;

    /* init */
    if (ok && EVP_DecryptInit_ex(ctx, cipher, NULL, NULL, NULL) != 1) ok = 0;
    if (ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)nonce_len, NULL) != 1) ok = 0;
    if (ok && EVP_DecryptInit_ex(ctx, NULL, NULL, key, nonce) != 1) ok = 0;

    /* AAD */
    if (ok && aad_len > 0) {
        if (EVP_DecryptUpdate(ctx, NULL, &outlen, aad, (int)aad_len) != 1) ok = 0;
    }

    /* decrypt ciphertext */
    unsigned char *pt = NULL;
    int pt_len = 0;
    if (ok) {
        pt = (unsigned char *)lua_newuserdata(L, ct_len + 16);
        if (EVP_DecryptUpdate(ctx, pt, &outlen, ct, (int)ct_len) != 1) {
            ok = 0;
        } else {
            pt_len = outlen;
        }
    }

    /* set expected tag BEFORE Final */
    if (ok) {
        /* need a mutable copy for OpenSSL */
        unsigned char tag_buf[16];
        memcpy(tag_buf, tag, 16);
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, tag_buf) != 1) {
            ok = 0;
        }
    }

    /* finalize: returns 1 if tag verified, 0 if not */
    int finlen = 0;
    int verified = 0;
    if (ok) {
        verified = EVP_DecryptFinal_ex(ctx, pt + pt_len, &finlen);
        if (verified) {
            pt_len += finlen;
        }
    }

    EVP_CIPHER_CTX_free(ctx);

    if (!ok) {
        lua_pop(L, 1); /* remove userdata */
        return luaL_error(L, "GCM decryption failed (internal error)");
    }

    if (!verified) {
        /* tag mismatch — return nil (not an error) */
        lua_pop(L, 1); /* remove userdata */
        lua_pushnil(L);
        return 1;
    }

    /* push plaintext string */
    lua_pushlstring(L, (const char *)pt, pt_len);
    return 1;
}

/* ------------------------------------------------------------------ */
/* module registration                                                */
/* ------------------------------------------------------------------ */

static const luaL_Reg lgcm_funcs[] = {
    {"encrypt", lgcm_encrypt},
    {"decrypt", lgcm_decrypt},
    {NULL, NULL}
};

LUA_API int luaopen_gcm(lua_State *L) {
    luaL_newlib(L, lgcm_funcs);
    return 1;
}
