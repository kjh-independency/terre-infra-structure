#!/usr/bin/env bash
# ④ 실험실 HTTPS 입구 확인(읽기만). 16-lab-https.cmd 가 적용 뒤 표준 입력으로 실행
H=https://127.0.0.1:18443
echo "== 1) 손님용 평문 18080: $(curl -s -o /dev/null -m 5 -w '%{http_code} → %{redirect_url}' http://127.0.0.1:18080/api/v1/layers)"
echo "== 2) 손님용 HTTPS 18443: $(curl -sk -o /dev/null -m 5 -w '%{http_code}, HTTP/%{http_version}, %{time_total}초' $H/api/v1/layers)"
echo "== 3) 협상된 TLS: $(curl -skv -o /dev/null -m 5 $H/api/v1/layers 2>&1 | grep -m1 -o -E 'SSL connection using [^ ]+ / [^ ]+')"
echo "== 4) TLS 1.2 로 제한해도 접속: $(curl -sk -o /dev/null -m 5 --tls-max 1.2 -w '%{http_code}' $H/api/v1/layers)"
echo "== 5) HSTS 헤더: $(curl -skI -m 5 $H/api/v1/layers | grep -i '^strict-transport-security' | tr -d '\r')"
echo "== 6) 인증서: $(echo | openssl s_client -connect 127.0.0.1:18443 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null | tr '\n' ' ')"
echo "== 7) 안쪽 측정용 평문 18088(서버 안 전용): $(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:18088/api/v1/layers)"
echo "== 8) 실험실 포트가 열린 주소(모두 127.0.0.1 이어야 함)"
ss -tlnH | awk '{print $4}' | grep -E ':(18080|18088|18443)$' | sort
echo "== 9) 앱 컨테이너(backend·색깔별 web·db·redis)는 공개 포트가 없어야 함"
docker ps --filter name=terre-lab --format '{{.Names}}: {{.Ports}}' | grep -v -E '^terre-lab-web-1:' | grep -E '[0-9]->' || echo "(없음: 입구만 공개)"
echo "== 10) 지금 서비스 중인 색으로 HTTPS 가 이어지는지: $(cat /home/ubuntu/terre-lab/bluegreen/state/active 2>/dev/null)"
