#!/usr/bin/env bash
# 블루-그린 배포가 롤백됐을 때 원인 보기(읽기만). 14-lab-diag.cmd 가 표준 입력으로 서버에 보내 실행한다.
LAB=/home/ubuntu/terre-lab
echo "== 지금 상태"; bash "$LAB/bluegreen/bg.sh" status
echo "== 입구 응답(실험실): $(curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}s' http://127.0.0.1:18088/api/v1/layers)"
for c in green blue; do
  n=terre-lab-backend-$c-1
  echo "== $n: $(docker inspect -f '{{.State.Status}} 재시작 {{.RestartCount}}회, 이미지 {{.Config.Image}}' "$n" 2>/dev/null)"
done
a=$(cat "$LAB/bluegreen/state/active" 2>/dev/null || echo blue); o=green; [ "$a" = green ] && o=blue
echo "== 서비스 안 하는 색($o) backend 의 오류 줄(마지막 시작 기준, 비밀값이 들어갈 만한 줄은 가림)"
docker logs --tail 400 "terre-lab-backend-$o-1" 2>&1 \
  | grep -E -A4 'APPLICATION FAILED|Description:|Caused by|Schema-validation|FlywayValidate|Migration|ERROR' \
  | grep -v -i -E 'password|secret|jwt|token' | cut -c1-260 | tail -n 45
