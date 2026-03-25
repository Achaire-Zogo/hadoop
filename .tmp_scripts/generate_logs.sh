#!/bin/bash
PAGES=("/index.html" "/about.html" "/contact.html" "/products" "/services"
       "/blog" "/blog/post-1" "/blog/post-2" "/api/data" "/api/users"
       "/api/orders" "/admin" "/admin/settings" "/login" "/logout"
       "/dashboard" "/profile" "/search" "/register" "/404-page"
       "/old-link" "/deprecated" "/api/crash" "/api/timeout" "/health")

METHODS=("GET" "GET" "GET" "GET" "POST" "PUT" "DELETE")

CODES=(200 200 200 200 200 200 200 301 404 403 500 502)

SIZES=(128 256 512 1024 2048 4096 8192 16384)

for i in $(seq 1 10000); do
    IP="192.168.$((RANDOM % 256)).$((RANDOM % 256))"
    HOUR=$((RANDOM % 24))
    MIN=$((RANDOM % 60))
    SEC=$((RANDOM % 60))
    DAY=$((RANDOM % 28 + 1))
    PAGE=${PAGES[$((RANDOM % ${#PAGES[@]}))]}
    METHOD=${METHODS[$((RANDOM % ${#METHODS[@]}))]}
    CODE=${CODES[$((RANDOM % ${#CODES[@]}))]}
    SIZE=${SIZES[$((RANDOM % ${#SIZES[@]}))]}
    printf "%s - - [%02d/Mar/2026:%02d:%02d:%02d] \"%s %s HTTP/1.1\" %d %d\n" \
        "$IP" "$DAY" "$HOUR" "$MIN" "$SEC" "$METHOD" "$PAGE" "$CODE" "$SIZE"
done
