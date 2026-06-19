#!/bin/bash
# Shared Graph API GET helper sourced by local-exec provisioners.
# Caller must have $token set in scope before calling graph_get().
# 429 → exponential backoff, up to 5 retries.
# Other 4xx/5xx → prints status + body to stderr and returns 1 (fails the apply).

graph_get() {
  local url="$1"
  local attempt=0
  local delay=15
  local body code
  while [ $attempt -lt 5 ]; do
    code=$(curl -s -o "/tmp/graph_resp_$$" -w "%{http_code}" \
      -H "Authorization: Bearer $token" \
      -G "$url" "${@:2}")
    body=$(cat "/tmp/graph_resp_$$")
    if [ "$code" = "429" ]; then
      attempt=$((attempt + 1))
      echo "[!] Rate limited (429), retry $attempt/5 in ${delay}s..." >&2
      sleep "$delay"
      delay=$((delay * 2))
    elif [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
      echo "$body"
      return 0
    else
      echo "[!] Graph API error ${code}: $body" >&2
      return 1
    fi
  done
  echo "[!] Graph API still rate limiting after 5 retries" >&2
  return 1
}
