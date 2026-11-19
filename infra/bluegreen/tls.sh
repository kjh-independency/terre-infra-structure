#!/usr/bin/env bash
# ④ 실험용 자체 서명 인증서를 만든다(없을 때만, 30일). 개인 키는 실험실 폴더 안(600)에만 두고 저장소·화면에 내놓지 않는다
set -euo pipefail
D=/home/ubuntu/terre-lab/bluegreen/tls
if [ -s "$D/lab.crt" ] && [ -s "$D/lab.key" ]; then
  echo "인증서 있음: $(openssl x509 -in "$D/lab.crt" -noout -subject -enddate | tr '\n' ' ')"; exit 0
fi
command -v openssl >/dev/null || { echo "중단: 서버에 openssl 이 없습니다"; exit 1; }
mkdir -p "$D" && chmod 700 "$D"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -subj "/CN=terre-lab.local" -addext "subjectAltName=DNS:terre-lab.local,DNS:localhost,IP:127.0.0.1" \
  -keyout "$D/lab.key" -out "$D/lab.crt" 2>/dev/null
chmod 600 "$D/lab.key" && chmod 644 "$D/lab.crt"
echo "인증서 만듦: $(openssl x509 -in "$D/lab.crt" -noout -subject -enddate | tr '\n' ' ')"
