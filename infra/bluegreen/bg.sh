#!/usr/bin/env bash
# terre-lab ②-1 블루-그린 배포 (실험실 전용, 팀 서비스 terre-service 는 건드리지 않는다)
#   init      : 블루-그린 구성으로 처음 띄운다(파랑이 서비스). variant.sh 가 부른다
#   deploy [태그] : 쉬는 색에 새 버전을 띄워 준비되면 입구를 새 색으로 바꾸고, 옛 색을 내린다
#                   태그(커밋 해시)를 주면 GHCR 이미지(REG/terre-backend·terre-web:태그)로, 안 주면 지금 색과 같은 이미지로(실험 T3)
#   screening <태그> : screening 을 새 이미지로 바꾼다(한 벌뿐이라 블루-그린이 아니라 다시 만들기, 실패하면 옛 이미지로 되돌림)
#   rollback  : 직전 색으로 되돌린다(내려가 있으면 다시 띄운 뒤 전환)
#   edge      : ④ 입구 nginx 를 새 설정(HTTPS 입구·HSTS)으로 다시 만든다(먼저 nginx -t 로 검사)
#   status    : 지금 색과 컨테이너 상태
# 준비 확인에 실패하면 전환하지 않는다 → 옛 색이 그대로 서비스(자동 롤백). 종료 코드 1
# 색깔별 이미지는 release.env 에 적고, 배포가 성공했을 때만 바꾼다. 배포·롤백 기록은 results/deploy-history.log
set -uo pipefail
LAB=/home/ubuntu/terre-lab
P=terre-lab
ST=$LAB/bluegreen/state
REG=${REG:-ghcr.io/kjh-independency}   # GitHub Actions 가 이미지를 올리는 곳(비공개)
REL=$LAB/bluegreen/release.env         # 색깔별로 지금 쓰는 이미지(입구 nginx 가 읽는 state 폴더와 분리)
HIST=$LAB/results/deploy-history.log
EDGE=terre-lab-web-1
READY_LIMIT=${READY_LIMIT:-420}   # 새 backend 준비를 기다리는 최대 초(준비 중 CPU 를 묶어 길게 잡음)
DRAIN=${DRAIN:-15}                # 전환 뒤 옛 색이 맡은 요청을 끝내도록 기다리는 초
PREP_CPUS=${PREP_CPUS:-0.7}       # 새 색 backend 가 준비되는 동안만 쓰는 CPU 상한(서비스 중인 색을 보호). 0 이면 제한 안 함
PREP_SHARES=${PREP_SHARES:-256}   # 준비 중 CPU 우선순위(기본 1024). 낮을수록 서비스 중인 색에 양보

say() { echo "[$(TZ=Asia/Seoul date '+%m-%d %H:%M:%S')] $*"; }
now() { date +%s.%N; }
dc() { docker compose -p "$P" --project-directory "$LAB" -f "$LAB/bluegreen/compose.bg.yml" --env-file "$LAB/.env" "$@"; }
active() { cat "$ST/active" 2>/dev/null || echo blue; }
upper() { tr '[:lower:]' '[:upper:]' <<<"$1"; }
IMG_KEYS=(BLUE_BACKEND_IMAGE BLUE_WEB_IMAGE GREEN_BACKEND_IMAGE GREEN_WEB_IMAGE SCREENING_IMAGE)

# shellcheck disable=SC2034  # 아래 값들은 export 로 compose 에 넘긴다(셸 안에서 직접 쓰지 않음)
load_release() {  # 파일이 없으면 처음 구성 그대로(운영 이미지에 이름만 붙인 :snap)
  BLUE_BACKEND_IMAGE=terre-lab-backend:snap; BLUE_WEB_IMAGE=terre-lab-web:snap
  GREEN_BACKEND_IMAGE=terre-lab-backend:snap; GREEN_WEB_IMAGE=terre-lab-web:snap
  SCREENING_IMAGE=terre-lab-screening:snap
  # shellcheck source=/dev/null
  [ -f "$REL" ] && . "$REL"
  export "${IMG_KEYS[@]}"   # compose.bg.yml 의 ${BLUE_BACKEND_IMAGE} 등이 이 값을 쓴다
}
save_release() {  # 지금 값을 원자적으로 기록(반쯤 쓴 파일이 남지 않게)
  local k
  for k in "${IMG_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done > "$REL.tmp" && mv -f "$REL.tmp" "$REL"
}
hist() {  # hist <태그> <from> <to> <결과>
  mkdir -p "$(dirname "$HIST")"
  printf '%s\t%s\t%s->%s\t%s\n' "$(TZ=Asia/Seoul date '+%F %T')" "$1" "$2" "$3" "$4" >> "$HIST"
}
have_image() { docker image inspect "$1" >/dev/null 2>&1 || { say "서버에 이미지가 없습니다: $1 (먼저 받아야 합니다)"; return 1; }; }
lock() {  # 배포·롤백·screening 은 한 번에 하나만(GitHub Actions 배포와 실험 T3 가 겹치지 않게)
  exec 9>"$LAB/bluegreen/.lock"
  flock -n 9 || { say "다른 배포·롤백이 진행 중입니다"; exit 3; }
}
other() { [ "$1" = blue ] && echo green || echo blue; }
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$P-backend-$1-1" 2>/dev/null || echo missing; }
smoke() { docker exec "$EDGE" wget -q -T 5 -O /dev/null "http://web-$1/api/v1/layers"; }   # 새 색을 입구 밖에서 직접 확인

write_upstream() {  # 원자적으로 바꾼다(반쯤 쓴 파일을 nginx 가 읽지 않게)
  mkdir -p "$ST"
  printf 'upstream app {\n    server web-%s:80;\n    keepalive 16;\n}\n' "$1" > "$ST/upstream.conf.tmp"
  mv -f "$ST/upstream.conf.tmp" "$ST/upstream.conf"
}

wait_ready() {  # wait_ready <색>: backend 준비(readiness UP) → 앱 nginx 경유 API 200 까지
  local c=$1 t0=$SECONDS
  while [ $((SECONDS - t0)) -lt "$READY_LIMIT" ]; do
    if [ "$(health "$c")" = healthy ] && smoke "$c"; then return 0; fi
    sleep 2
  done
  return 1
}

limit_prep() {   # limit_prep <색>: 준비 중 새 backend 의 CPU 를 묶는다
  [ "$PREP_CPUS" = 0 ] && return 0
  docker update --cpus "$PREP_CPUS" --cpu-shares "$PREP_SHARES" "$P-backend-$1-1" >/dev/null && say "준비 중 $1 backend CPU 상한 ${PREP_CPUS}개·우선순위 낮춤"
}
unlimit() {      # 전환 뒤 원래대로(실험실 전체 상한이 CPU 2개라 2 = 사실상 제한 없음)
  docker update --cpus 2 --cpu-shares 1024 "$P-backend-$1-1" >/dev/null 2>&1 || true
}

switch_to() {  # 입구를 새 색으로. 설정 검사에 실패하면 원래대로 둔다
  local c=$1 prev
  prev=$(active)
  write_upstream "$c"
  if ! docker exec "$EDGE" nginx -t -q; then
    write_upstream "$prev"; say "입구 설정 검사 실패: 전환하지 않습니다"; return 1
  fi
  docker exec "$EDGE" nginx -s reload
  echo "$c" > "$ST/active"
}

cmd_init() {
  mkdir -p "$ST"
  write_upstream blue; echo blue > "$ST/active"
  say "블루-그린 구성으로 바꿉니다: db·redis·screening 은 그대로, backend·web 은 파랑으로 다시 띄웁니다"
  dc up -d --remove-orphans db redis screening backend-blue web-blue || return 1
  wait_ready_init blue || { say "파랑이 준비되지 않았습니다"; return 1; }
  dc up -d --remove-orphans web tilegen || return 1
  say "완료: 입구(web) → 파랑"
}
wait_ready_init() {  # 입구가 아직 없을 수 있어 backend 상태만 본다
  local c=$1 t0=$SECONDS
  while [ $((SECONDS - t0)) -lt "$READY_LIMIT" ]; do [ "$(health "$c")" = healthy ] && return 0; sleep 3; done; return 1
}

cmd_deploy() {
  local tag=${1:-} a n A N k t0 t1 t2 t3
  a=$(active); n=$(other "$a"); A=$(upper "$a"); N=$(upper "$n")
  if [ -n "$tag" ]; then
    [[ $tag =~ ^[0-9a-f]{7,40}$ ]] || { say "태그는 커밋 해시(소문자 16진수)여야 합니다: $tag"; return 2; }
    printf -v "${N}_BACKEND_IMAGE" '%s' "$REG/terre-backend:$tag"
    printf -v "${N}_WEB_IMAGE" '%s' "$REG/terre-web:$tag"
  else  # 태그 없이: 지금 서비스 중인 색과 같은 이미지로 다시 띄운다(무중단 실험 T3)
    k="${A}_BACKEND_IMAGE"; printf -v "${N}_BACKEND_IMAGE" '%s' "${!k}"
    k="${A}_WEB_IMAGE"; printf -v "${N}_WEB_IMAGE" '%s' "${!k}"
    tag=same
  fi
  k="${N}_BACKEND_IMAGE"; have_image "${!k}" || return 1
  k="${N}_WEB_IMAGE"; have_image "${!k}" || return 1
  t0=$(now)
  say "배포 시작($tag): 지금 $a 가 서비스 중. 쉬는 $n 에 새 버전을 띄웁니다(서비스는 $a 가 계속)"
  # 만들기 → CPU 묶기 → 시작 순서라, 처음부터 제한된 채로 뜬다
  LAB_DEPLOY_ID="bg-$(date +%s)" dc up --no-start --no-deps --force-recreate "backend-$n" "web-$n" || { say "새 색 만들기 실패"; return 1; }
  limit_prep "$n"
  dc start "backend-$n" "web-$n" || { say "새 색 시작 실패"; return 1; }
  if ! wait_ready "$n"; then
    say "$n 이(가) ${READY_LIMIT}초 안에 준비되지 않아 전환하지 않습니다(자동 롤백: $a 유지)"
    dc stop "backend-$n" "web-$n" >/dev/null 2>&1
    hist "$tag" "$a" "$n" rollback_not_ready
    echo "result=rollback_not_ready" ; return 1
  fi
  t1=$(now)
  say "$n 준비 완료($(awk "BEGIN{printf \"%.1f\", $t1-$t0}")초). 입구를 $a → $n 으로 바꿉니다"
  switch_to "$n" || { dc stop "backend-$n" "web-$n" >/dev/null 2>&1; hist "$tag" "$a" "$n" rollback_switch_failed; echo "result=rollback_switch_failed"; return 1; }
  t2=$(now)
  save_release   # 전환에 성공했을 때만 새 색의 이미지를 기록한다
  unlimit "$n"
  sleep "$DRAIN"
  dc stop "backend-$a" "web-$a" >/dev/null
  t3=$(now)
  say "완료: 입구 → $n, $a 는 내렸습니다(롤백할 때 다시 씀)"
  hist "$tag" "$a" "$n" switched
  printf 'result=switched\ntag=%s\nfrom=%s\nto=%s\nprep_cpus=%s\nprepare_seconds=%.1f\nswitch_epoch=%.3f\ntotal_seconds=%.1f\n' \
    "$tag" "$a" "$n" "$PREP_CPUS" "$(awk "BEGIN{print $t1-$t0}")" "$t2" "$(awk "BEGIN{print $t3-$t0}")"
}

cmd_screening() {  # screening <태그>
  local tag=${1:-} old img t0
  [[ $tag =~ ^[0-9a-f]{7,40}$ ]] || { say "태그는 커밋 해시여야 합니다: $tag"; return 2; }
  img="$REG/terre-screening:$tag"; old=$SCREENING_IMAGE
  have_image "$img" || return 1
  say "screening 을 $tag 로 바꿉니다(한 벌뿐이라 몇 초 동안 파일 분석 요청이 실패할 수 있음)"
  SCREENING_IMAGE=$img
  dc up -d --no-deps screening || { SCREENING_IMAGE=$old; dc up -d --no-deps screening; hist "$tag" screening screening failed; return 1; }
  t0=$SECONDS
  while [ $((SECONDS - t0)) -lt 120 ]; do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' "$P-screening-1" 2>/dev/null)" = healthy ]; then
      save_release; hist "$tag" screening screening switched; say "screening 완료"; return 0
    fi
    sleep 3
  done
  say "screening 이 2분 안에 준비되지 않아 옛 이미지로 되돌립니다"
  SCREENING_IMAGE=$old; dc up -d --no-deps screening
  hist "$tag" screening screening rollback_not_ready; return 1
}

cmd_rollback() {
  local a o
  a=$(active); o=$(other "$a")
  say "롤백: $a → $o"
  if [ "$(health "$o")" != healthy ]; then
    dc up --no-start --no-deps "backend-$o" "web-$o" || return 1
    limit_prep "$o"; dc start "backend-$o" "web-$o" || return 1
    wait_ready "$o" || { say "$o 이(가) 준비되지 않아 롤백하지 않습니다"; return 1; }
  fi
  switch_to "$o" && unlimit "$o" && sleep "$DRAIN" && dc stop "backend-$a" "web-$a" >/dev/null && say "완료: 입구 → $o" && hist rollback "$a" "$o" switched
}

cmd_edge() {  # ④ 입구 nginx 를 새 설정(HTTPS 입구 포함)으로 다시 만든다. 미리 검사에 실패하면 손대지 않는다
  local p t0
  for p in 18080 18443; do   # 새로 쓸 포트가 이미 다른 프로그램(팀 서비스 포함)에 쓰이고 있으면 멈춘다
    if ss -tlnH "sport = :$p" | grep -q . && ! docker port "$EDGE" 2>/dev/null | grep -q ":$p\$"; then
      say "포트 $p 를 이미 다른 프로그램이 쓰고 있어 바꾸지 않습니다"; return 1
    fi
  done
  bash "$LAB/bluegreen/tls.sh" || return 1
  say "새 입구 설정을 일회용 컨테이너로 먼저 검사합니다(nginx -t)"
  docker run --rm --network "${P}_default" \
    -v "$LAB/bluegreen/edge.conf:/etc/nginx/conf.d/default.conf:ro" -v "$ST:/etc/nginx/bg:ro" \
    -v "$LAB/bluegreen/tls:/etc/nginx/tls:ro" nginx:1.27-alpine nginx -t -q \
    || { say "검사 실패: 입구를 바꾸지 않습니다"; return 1; }
  say "입구를 다시 만듭니다(실험실만 몇 초 끊김, 팀 서비스와 무관)"
  dc up -d --no-deps web || return 1
  t0=$SECONDS
  until curl -s -o /dev/null -m 3 http://127.0.0.1:18088/api/v1/layers; do
    [ $((SECONDS - t0)) -ge 60 ] && { say "입구가 60초 안에 응답하지 않습니다"; return 1; }
    sleep 2
  done
  say "입구 다시 만들기 완료($((SECONDS - t0))초 안에 응답)"
}

cmd_status() {
  say "지금 서비스 중인 색: $(active)"
  for c in blue green; do echo "  backend-$c: $(health "$c")"; done
  local k; for k in "${IMG_KEYS[@]}"; do echo "  $k=${!k}"; done
  [ -f "$HIST" ] && { echo "  최근 배포 기록:"; tail -n 5 "$HIST" | sed 's/^/    /'; }
  dc ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || true
}

load_release
case "${1:-}" in
  init) lock; cmd_init ;;
  deploy) lock; cmd_deploy "${2:-}" ;;
  screening) lock; cmd_screening "${2:-}" ;;
  rollback) lock; cmd_rollback ;;
  edge) lock; cmd_edge ;;
  status) cmd_status ;;
  *) echo "사용: bg.sh init|deploy [태그]|screening <태그>|rollback|edge|status"; exit 2 ;;
esac
