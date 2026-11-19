#!/usr/bin/env bash
# ④ 공용 서버가 바깥에 무엇을 열어 두었는지 본다(읽기만, 아무것도 바꾸지 않음). 16-lab-https.cmd 가 표준 입력으로 실행
echo "== 모든 주소(바깥 포함)에서 받는 TCP 포트"
ss -tlnH | awk '{print $4}' | grep -v -E '^(127\.|\[::1\]|::1:)' | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | tr '\n' ' '; echo
echo "== 서버 안(127.0.0.1)에서만 받는 TCP 포트"
ss -tlnH | awk '{print $4}' | grep -E '^(127\.|\[::1\])' | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq | tr '\n' ' '; echo
echo "== 도커 컨테이너가 모든 주소에 공개한 포트(컨테이너 이름: 포트)"
docker ps --format '{{.Names}}: {{.Ports}}' | grep -E '0\.0\.0\.0|\[::\]|:::' || echo "(없음)"
echo "== 실험실(terre-lab) 컨테이너가 공개한 포트"
docker ps --filter name=terre-lab --format '{{.Names}}: {{.Ports}}' | grep -E '[0-9]->' || echo "(없음)"
echo "== 방화벽(ufw) 상태(읽기, 권한이 있을 때만)"
sudo -n ufw status 2>/dev/null | head -25 || echo "확인 불가(권한 없음)"
echo "== 도커 공개 포트는 ufw 를 거치지 않는다: DOCKER-USER 체인(읽기)"
sudo -n iptables -S DOCKER-USER 2>/dev/null | head -10 || echo "확인 불가(권한 없음)"
echo "== 운영 입구 응답(서버 안에서): http :8088 → $(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:8088/), https :443 → $(curl -sk -o /dev/null -m 5 -w '%{http_code}' https://127.0.0.1/ 2>/dev/null || true)"
