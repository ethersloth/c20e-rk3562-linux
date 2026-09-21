#!/usr/bin/env bash

BASE='http://127.0.0.1:8765/api/download'
TOKEN='93422f2b09236dacf8c0f1b46a6b37a72ab4eca61b0da8d6b3526b5cb8368367'
CURL='/usr/bin/curl'

tests=(
  'clients/client1/client1.ovpn|200|valid client download'
  '../web_app.py|BLOCK|parent traversal to source file'
  '../../etc/passwd|BLOCK|parent traversal to /etc/passwd'
  '/etc/passwd|BLOCK|absolute /etc/passwd'
  'clients/client1/../../web_app.py|BLOCK|nested traversal to source file'
)

pass_count=0
fail_count=0

for test_case in "${tests[@]}"; do
  IFS='|' read -r test_path expected label <<< "$test_case"

  body_file="$(mktemp)"
  headers_file="$(mktemp)"

  status="$("$CURL" -sS \
    --get "$BASE" \
    --data-urlencode "path=$test_path" \
    --data-urlencode "csrf_token=$TOKEN" \
    -H 'Referer: http://127.0.0.1:8765/' \
    -D "$headers_file" \
    -o "$body_file" \
    -w '%{http_code}')"

  result='FAIL'

  if [[ "$expected" == '200' ]]; then
    if [[ "$status" == '200' ]]; then
      result='PASS'
    fi
  else
    if [[ "$status" != '200' ]]; then
      result='PASS'
    fi
  fi

  if grep -qE 'root:.*:0:0:|Copyright \(C\).*HMS|def |import ' "$body_file"; then
    result='FAIL'
  fi

  if [[ "$result" == 'PASS' ]]; then
    ((pass_count++))
  else
    ((fail_count++))
  fi

  printf '%-6s HTTP %-3s %-45s %s\n' "$result" "$status" "$test_path" "$label"

  rm -f "$body_file" "$headers_file"
done

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
