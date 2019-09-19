webroot = os.getenv("WEBROOT") or "web"
http_using_core = os.getenv("HTTP_USING_CORE") and os.getenv("HTTP_USING_CORE") == "true"
httpd_using_core = os.getenv("HTTPD_USING_CORE") and os.getenv("HTTPD_USING_CORE") == "true"
