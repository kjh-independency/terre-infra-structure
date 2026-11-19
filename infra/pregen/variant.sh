#!/usr/bin/env bash
# terre-lab 구성 바꾸기: base(11/6 구성) <-> pregen(개선 1: 경계 타일 미리 생성)
#   start <base|pregen> : 서버에서 백그라운드로 바꾸기 시작 (lab.sh bg 와 같은 방식, 창을 닫아도 계속)
#   status              : 지금 구성과 타일 생성 상태
# 실험실(terre-lab) 컨테이너만 다루며 팀 서비스(terre-service)는 건드리지 않는다.
set -uo pipefail
LAB=/home/ubuntu/terre-lab
RES=$LAB/results
P=terre-lab
WEB=terre-lab-web-1
TILEGEN=terre-lab-tilegen-1
BUILD_LIMIT_SECONDS=10800

say() { echo "[$(TZ=Asia/Seoul date '+%m-%d %H:%M:%S')] $*"; }
die() { say "중단: $*"; exit 1; }
stamp() { TZ=Asia/Seoul date '+%m%d-%H%M'; }
variant() { cat "$LAB/variant" 2>/dev/null || echo base; }

dc() {
  local files=(-f "$LAB/compose.lab.yml")
  [ "$(variant)" = pregen ] && files+=(-f "$LAB/pregen/compose.pregen.yml")
  if [ "$(variant)" = bluegreen ]; then files=(--project-directory "$LAB" -f "$LAB/bluegreen/compose.bg.yml"); fi
  docker compose -p "$P" "${files[@]}" --env-file "$LAB/.env" "$@"
}

ci_busy() {  # lab.sh 와 같은 판단: 팀 Runner 작업 컨테이너가 있거나 gitlab-runner 가 자식 작업을 돌리는 중
  local n rp
  n=$(docker ps --format '{{.Names}}' | grep -c '^runner-' || true)
  rp=$(pgrep -o -x gitlab-runner || true)
  if [ -n "$rp" ] && pgrep -P "$rp" >/dev/null 2>&1; then n=$((n + 1)); fi
  [ "$n" -gt 0 ]
}

tilegen_state() { docker exec "$WEB" cat /srv/pregen/state.json 2>/dev/null || echo '{}'; }
ready() { tilegen_state | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ready_at") else 1)'; }
last_event() { docker exec "$WEB" sh -c 'tail -n 1 /srv/pregen/events.log 2>/dev/null' || true; }

summary() { tilegen_state | python3 "$LAB/pregen/summary.py"; }

cmd_status() {
  local vv; case "$(variant)" in pregen) vv='개선 1(타일 미리 생성)' ;; bluegreen) vv='개선 1 + ②-1 블루-그린' ;; *) vv='기준(11/6 구성)' ;; esac
  say "실험실 구성: $vv"
  [ "$(variant)" = bluegreen ] && bash "$LAB/bluegreen/bg.sh" status
  if [ "$(variant)" = pregen ] || [ "$(variant)" = bluegreen ]; then
    say "타일 미리 생성 상태:"
    summary
    say "마지막 기록: $(last_event)"
  fi
}

cmd_start() {
  local mode=${1:-}
  case "$mode" in base|pregen|bluegreen) ;; *) die "base, pregen, bluegreen 중에서 지정하세요" ;; esac
  [ -f "$LAB/.env" ] || die "terre-lab 이 떠 있지 않습니다. 1-lab-up 을 먼저 실행하세요"
  mkdir -p "$RES"
  if [ -f "$RES/current.pid" ] && kill -0 "$(cat "$RES/current.pid")" 2>/dev/null; then
    die "이미 서버에서 진행 중인 작업이 있습니다(3-lab-status 로 확인)"
  fi
  setsid nohup bash "$LAB/pregen/variant.sh" _run "$mode" > "$RES/current.log" 2>&1 < /dev/null &
  echo $! > "$RES/current.pid"
  say "서버에서 시작했습니다: 구성 바꾸기 → $mode (이 창을 닫아도 서버에서는 계속 진행됩니다)"
}

cmd_run() {
  local mode=$1 out started waited=0 paused=0
  if ci_busy; then die "팀 CI 작업이 돌고 있습니다. 끝난 뒤 다시 하세요"; fi
  echo "$mode" > "$LAB/variant"
  if [ "$mode" = bluegreen ]; then
    say "②-1 블루-그린 구성으로 바꿉니다(개선 1 미리 만든 타일은 그대로 씀)"
    bash "$LAB/bluegreen/bg.sh" init || die "블루-그린 구성 실패(3-lab-status 로 확인)"
    say "완료. 이제 2-lab-test → 10 으로 블루-그린 배포 중 끊김을 잽니다"
    return 0
  fi
  if [ "$mode" = base ]; then
    say "기준(11/6 구성)으로 되돌립니다: web 설정을 nginx-1106.conf 로, tilegen 은 내립니다"
    dc up -d --remove-orphans || die "compose 실행 실패"
    say "완료. 미리 만든 타일 볼륨(terre-lab_pregen)은 남겨 둡니다(다시 적용할 때 재사용, 9-lab-down 때 함께 삭제)"
    return 0
  fi
  out="$RES/$(stamp)-pregen-build"; mkdir -p "$out"
  say "개선 1(타일 미리 생성)을 적용합니다: web 설정을 nginx-pregen.conf 로 바꾸고 tilegen 을 띄웁니다"
  dc up -d --remove-orphans || die "compose 실행 실패"
  started=$(date +%s)
  say "타일을 만드는 동안에도 실험실은 그대로 동작합니다(파일이 없는 타일은 backend 가 만듦). 팀 CI 가 돌면 잠깐 멈춥니다"
  while ! ready; do
    sleep 10
    waited=$(( $(date +%s) - started ))
    if ci_busy; then
      if [ "$paused" = 0 ]; then docker pause "$TILEGEN" >/dev/null 2>&1 && paused=1 && say "팀 CI 가 돌고 있어 타일 만들기를 멈췄습니다"; fi
    elif [ "$paused" = 1 ]; then
      docker unpause "$TILEGEN" >/dev/null 2>&1; paused=0; say "팀 CI 가 끝나 타일 만들기를 이어갑니다"
    fi
    [ $((waited % 60)) -lt 10 ] && say "진행: $(last_event)"
    if [ "$waited" -gt "$BUILD_LIMIT_SECONDS" ]; then
      [ "$paused" = 1 ] && docker unpause "$TILEGEN" >/dev/null 2>&1
      die "3시간 안에 끝나지 않았습니다. 3-lab-status 로 확인하세요"
    fi
  done
  [ "$paused" = 1 ] && docker unpause "$TILEGEN" >/dev/null 2>&1
  {
    echo "# 개선 1 적용: 경계 타일 미리 생성"
    echo
    echo "- 적용 시각(한국): $(TZ=Asia/Seoul date -d "@$started" '+%Y-%m-%d %H:%M:%S')"
    echo "- 전체 걸린 시간: $(( $(date +%s) - started ))초 (팀 CI 로 멈춘 시간 포함)"
    echo "- 범위: 한국 주변(124~132°E, 33~39°N), 줌 5~12. 그 밖의 줌·지역은 backend 가 그대로 만든다"
    echo
    echo "## 레이어별"
    echo
    summary
  } > "$out/result.md"
  tilegen_state > "$out/state.json"
  docker exec "$WEB" sh -c 'cat /srv/pregen/events.log 2>/dev/null' > "$out/tilegen-events.log" || true
  cat "$out/result.md"
  say "완료. 이제 2-lab-test 로 T1·T2 를 다시 재면 개선 1 결과가 나옵니다"
}

cmd_reset_if_down() {  # 실험실이 내려가 있을 때만 구성 표시를 지운다(새로 띄우면 늘 11/6 구성부터)
  local ids
  ids=$(docker ps -aq --filter "label=com.docker.compose.project=$P") || return 0  # docker 를 못 읽으면 건드리지 않는다
  if [ -z "$ids" ]; then rm -f "$LAB/variant"; fi
}

case "${1:-}" in
  start) cmd_start "${2:-}" ;;
  reset-if-down) cmd_reset_if_down ;;
  _run) cmd_run "${2:-}" ;;
  status) cmd_status ;;
  *) echo "사용: variant.sh start <base|pregen> | status | reset-if-down"; exit 2 ;;
esac
