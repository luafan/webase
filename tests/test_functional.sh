#!/usr/bin/env bash
# Functional integration tests for webase

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:2201}"
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

echo "=== Functional Tests ==="

# --- Static file serving ---

echo ""
echo "-- Static File Serving --"

# Test: serve JS file with correct MIME type
resp=$(curl -s -o /dev/null -w "%{http_code}|%{content_type}" "$BASE_URL/jquery.min.js")
code=$(echo "$resp" | cut -d'|' -f1)
ctype=$(echo "$resp" | cut -d'|' -f2)
if [ "$code" = "200" ]; then
    pass "GET /jquery.min.js returns 200"
else
    fail "GET /jquery.min.js returns 200" "got $code"
fi
if echo "$ctype" | grep -qi "javascript"; then
    pass "Content-Type contains javascript"
else
    fail "Content-Type contains javascript" "got $ctype"
fi

# Test: Cache-Control header
cache_ctrl=$(curl -s -D - -o /dev/null "$BASE_URL/jquery.min.js" | grep -i "Cache-Control" | tr -d '\r')
if echo "$cache_ctrl" | grep -q "max-age=86400"; then
    pass "Cache-Control: max-age=86400 present"
else
    fail "Cache-Control: max-age=86400 present" "got: $cache_ctrl"
fi

# Test: ETag present
etag=$(curl -s -D - -o /dev/null "$BASE_URL/jquery.min.js" | grep -i "^ETag:" | tr -d '\r' | awk '{print $2}')
if [ -n "$etag" ]; then
    pass "ETag header present"
else
    fail "ETag header present" "no ETag in response"
fi

# Test: If-None-Match returns 304
if [ -n "$etag" ]; then
    code304=$(curl -s -o /dev/null -w "%{http_code}" -H "If-None-Match: $etag" "$BASE_URL/jquery.min.js")
    if [ "$code304" = "304" ]; then
        pass "If-None-Match with valid ETag returns 304"
    else
        fail "If-None-Match with valid ETag returns 304" "got $code304"
    fi
fi

# Test: gzip encoding
gzip_header=$(curl -s -D - -o /dev/null -H "Accept-Encoding: gzip" "$BASE_URL/jquery.min.js" | grep -i "Content-Encoding" | tr -d '\r')
if echo "$gzip_header" | grep -qi "gzip"; then
    pass "Accept-Encoding: gzip returns Content-Encoding: gzip"
else
    fail "Accept-Encoding: gzip returns Content-Encoding: gzip" "got: $gzip_header"
fi

# Test: HEAD method
head_resp=$(curl -s -I -o /dev/null -w "%{http_code}|%{size_download}" "$BASE_URL/jquery.min.js")
head_code=$(echo "$head_resp" | cut -d'|' -f1)
head_size=$(echo "$head_resp" | cut -d'|' -f2)
if [ "$head_code" = "200" ]; then
    pass "HEAD /jquery.min.js returns 200"
else
    fail "HEAD /jquery.min.js returns 200" "got $head_code"
fi
if [ "$head_size" = "0" ]; then
    pass "HEAD returns empty body"
else
    fail "HEAD returns empty body" "body size: $head_size"
fi

# Test: Content-Length header on HEAD
cl_header=$(curl -s -I "$BASE_URL/jquery.min.js" | grep -i "Content-Length" | tr -d '\r')
if [ -n "$cl_header" ]; then
    pass "HEAD response has Content-Length header"
else
    fail "HEAD response has Content-Length header"
fi

# --- Directory listing ---

echo ""
echo "-- Directory Listing --"

dir_resp=$(curl -s -w "\n%{http_code}" "$BASE_URL/images/")
dir_code=$(echo "$dir_resp" | tail -1)
dir_body=$(echo "$dir_resp" | sed '$d')
if [ "$dir_code" = "200" ]; then
    pass "GET /images/ returns 200"
else
    fail "GET /images/ returns 200" "got $dir_code"
fi
if echo "$dir_body" | grep -q '<a href'; then
    pass "Directory listing contains <a href links"
else
    fail "Directory listing contains <a href links"
fi

# --- 404 handling ---

echo ""
echo "-- Error Handling --"

code404=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/nonexistent_file_xyz_123.txt")
if [ "$code404" = "404" ]; then
    pass "GET nonexistent file returns 404"
else
    fail "GET nonexistent file returns 404" "got $code404"
fi

# --- Service endpoint ---

echo ""
echo "-- Service Endpoint --"

svc_resp=$(curl -s -w "\n%{http_code}" "$BASE_URL/service")
svc_code=$(echo "$svc_resp" | tail -1)
if [ "$svc_code" = "200" ]; then
    pass "GET /service returns 200"
else
    fail "GET /service returns 200" "got $svc_code"
fi

svc_ctype=$(curl -s -D - -o /dev/null "$BASE_URL/service" | grep -i "Content-Type" | tr -d '\r')
if echo "$svc_ctype" | grep -qi "text/plain"; then
    pass "GET /service Content-Type is text/plain"
else
    fail "GET /service Content-Type is text/plain" "got: $svc_ctype"
fi

# --- CSS file serving ---

echo ""
echo "-- Other File Types --"

css_ctype=$(curl -s -D - -o /dev/null "$BASE_URL/jquery.mobile-1.4.5.min.css" | grep -i "Content-Type" | tr -d '\r')
if echo "$css_ctype" | grep -qi "css"; then
    pass "CSS file served with correct MIME type"
else
    fail "CSS file served with correct MIME type" "got: $css_ctype"
fi

# --- Summary ---

echo ""
echo "-- Functional Results --"
TOTAL=$((PASSED + FAILED))
echo "  Total: $TOTAL | Passed: $PASSED | Failed: $FAILED"

exit $FAILED
