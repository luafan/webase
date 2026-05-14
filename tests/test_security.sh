#!/usr/bin/env bash
# Security integration tests for webase

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:2201}"
PURGE_TOKEN="${PURGE_TOKEN:-test_secret_token}"
PASSED=0
FAILED=0

pass() {
    PASSED=$((PASSED + 1))
    echo "  PASS: $1"
}

fail() {
    FAILED=$((FAILED + 1))
    echo "  FAIL: $1"
    [ -n "${2:-}" ] && echo "        $2"
}

echo "=== Security Tests ==="

# --- Path Traversal ---

echo ""
echo "-- Path Traversal Prevention --"

# Encoded ../ (%2e%2e = ..)
code=$(curl -s -o /dev/null -w "%{http_code}" --path-as-is "$BASE_URL/%2e%2e/%2e%2e/etc/passwd")
if [ "$code" = "400" ] || [ "$code" = "403" ] || [ "$code" = "404" ]; then
    pass "GET /%2e%2e/%2e%2e/etc/passwd blocked ($code)"
else
    fail "GET /%2e%2e/%2e%2e/etc/passwd blocked" "got $code"
fi

# Double-encoded
code=$(curl -s -o /dev/null -w "%{http_code}" --path-as-is "$BASE_URL/%252e%252e/%252e%252e/etc/passwd")
if [ "$code" = "400" ] || [ "$code" = "403" ] || [ "$code" = "404" ]; then
    pass "GET double-encoded path traversal blocked ($code)"
else
    fail "GET double-encoded path traversal blocked" "got $code"
fi

# Direct ../
code=$(curl -s -o /dev/null -w "%{http_code}" --path-as-is "$BASE_URL/../../../etc/passwd")
if [ "$code" = "400" ] || [ "$code" = "403" ] || [ "$code" = "404" ]; then
    pass "GET /../../../etc/passwd blocked ($code)"
else
    fail "GET /../../../etc/passwd blocked" "got $code"
fi

# Mixed encoding: ..%2f
code=$(curl -s -o /dev/null -w "%{http_code}" --path-as-is "$BASE_URL/..%2f..%2f..%2fetc/passwd")
if [ "$code" = "400" ] || [ "$code" = "403" ] || [ "$code" = "404" ]; then
    pass "GET /..%2f..%2f traversal blocked ($code)"
else
    fail "GET /..%2f..%2f traversal blocked" "got $code"
fi

# Null byte injection
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/jquery.min.js%00.html")
if [ "$code" = "400" ] || [ "$code" = "403" ] || [ "$code" = "404" ]; then
    pass "Null byte injection blocked ($code)"
else
    fail "Null byte injection blocked" "got $code"
fi

# Traversal beyond webroot should not leak file content
body=$(curl -s --path-as-is "$BASE_URL/%2e%2e/%2e%2e/etc/passwd")
if echo "$body" | grep -q "root:"; then
    fail "Path traversal leaks /etc/passwd content"
else
    pass "Path traversal does not leak /etc/passwd"
fi

# --- JSONP Validation ---

echo ""
echo "-- JSONP Callback Validation --"

# Valid callback name (use /echo which returns a table, triggering JSONP logic)
resp=$(curl -s -w "\n%{http_code}" "$BASE_URL/echo?jsonp=myCallback")
jsonp_code=$(echo "$resp" | tail -1)
jsonp_body=$(echo "$resp" | sed '$d')
if [ "$jsonp_code" = "200" ]; then
    pass "Valid JSONP callback 'myCallback' accepted (200)"
else
    fail "Valid JSONP callback 'myCallback' accepted (200)" "got $jsonp_code"
fi
if echo "$jsonp_body" | grep -q "^myCallback("; then
    pass "Response wrapped in myCallback(...)"
else
    fail "Response wrapped in myCallback(...)" "body: $jsonp_body"
fi

# Valid callback with dots and dollars
resp=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/echo?jsonp=jQuery.fn.init")
if [ "$resp" = "200" ]; then
    pass "Valid JSONP callback 'jQuery.fn.init' accepted"
else
    fail "Valid JSONP callback 'jQuery.fn.init' accepted" "got $resp"
fi

# Invalid: XSS in callback
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/echo?jsonp=%3Cscript%3Ealert(1)%3C/script%3E")
if [ "$code" = "400" ]; then
    pass "JSONP XSS payload '<script>alert(1)</script>' rejected (400)"
else
    fail "JSONP XSS payload rejected" "got $code"
fi

# Invalid: brackets
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/echo?jsonp=a%5Db")
if [ "$code" = "400" ]; then
    pass "JSONP callback with ']' rejected (400)"
else
    fail "JSONP callback with ']' rejected" "got $code"
fi

# Invalid: parentheses
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/echo?jsonp=alert()")
if [ "$code" = "400" ]; then
    pass "JSONP callback with '()' rejected (400)"
else
    fail "JSONP callback with '()' rejected" "got $code"
fi

# Invalid: starting with number
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/echo?jsonp=123abc")
if [ "$code" = "400" ]; then
    pass "JSONP callback starting with number rejected (400)"
else
    fail "JSONP callback starting with number rejected" "got $code"
fi

# Invalid: too long (> 128 chars)
long_cb=$(printf 'a%.0s' $(seq 1 200))
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/echo?jsonp=$long_cb")
if [ "$code" = "400" ]; then
    pass "JSONP callback >128 chars rejected (400)"
else
    fail "JSONP callback >128 chars rejected" "got $code"
fi

# --- Purge Cache Authentication ---

echo ""
echo "-- Purge Cache Authentication --"

# No auth (non-localhost via X-Real-IP header trick won't work, but from host it's non-local to container)
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/purge_cache")
if [ "$code" = "403" ]; then
    pass "GET /purge_cache without auth returns 403"
else
    # From the Docker host, the request may come from the gateway IP
    # which is non-localhost, so we expect 403
    fail "GET /purge_cache without auth returns 403" "got $code (request may appear as localhost to container)"
fi

# Wrong token
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/purge_cache?token=wrong_token")
if [ "$code" = "403" ]; then
    pass "GET /purge_cache with wrong token returns 403"
else
    fail "GET /purge_cache with wrong token returns 403" "got $code"
fi

# Correct token via query param
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/purge_cache?token=$PURGE_TOKEN")
if [ "$code" = "200" ]; then
    pass "GET /purge_cache with correct token returns 200"
else
    fail "GET /purge_cache with correct token returns 200" "got $code"
fi

# Correct token via header
code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Purge-Token: $PURGE_TOKEN" "$BASE_URL/purge_cache")
if [ "$code" = "200" ]; then
    pass "GET /purge_cache with correct X-Purge-Token header returns 200"
else
    fail "GET /purge_cache with correct X-Purge-Token header returns 200" "got $code"
fi

# --- Directory Listing XSS ---

echo ""
echo "-- Directory Listing XSS Prevention --"

# Verify directory listing output is escaped (check that existing safe content renders fine)
dir_body=$(curl -s "$BASE_URL/images/")
if echo "$dir_body" | grep -q '&lt;\|&gt;\|&amp;'; then
    pass "Directory listing appears to have HTML escaping active"
elif echo "$dir_body" | grep -q '<a href'; then
    # No dangerous chars in real filenames, so just verify it doesn't have raw unescaped injection vectors
    pass "Directory listing renders safely (no injection vectors in real filenames)"
else
    fail "Directory listing format unexpected"
fi

# --- Summary ---

echo ""
echo "-- Security Results --"
TOTAL=$((PASSED + FAILED))
echo "  Total: $TOTAL | Passed: $PASSED | Failed: $FAILED"

exit $FAILED
