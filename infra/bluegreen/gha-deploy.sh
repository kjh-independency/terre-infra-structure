#!/usr/bin/env bash
# ②-2 GitHub Actions 전용 입구. authorized_keys 에서 이 키에는 command= 로 이 스크립트만 묶여 있어,
# 키가 새더라도 할 수 있는 일은 아래 세 요청뿐이다(셸·포트 포워딩·파일 복사 불가).
#   ping                               : 상태만 답한다(읽기 전용, 연결 확인용)
#   deploy <커밋 40자> <커밋 40자|keep> : GHCR 에서 그 커밋 이미지를 받아 블루-그린 배포. 두 번째는 screening(바뀌지 않았으면 keep)
#   backup                             : ③ 실험실 DB 를 덤프해 S3 업로드 전용 주소로 올린다(gha-backup.sh, 주소는 표준 입력)
# GHCR 읽기 토큰은 표준 입력으로 한 줄 받는다. 워크플로가 끝나면 만료되는 임시 토큰(GITHUB_TOKEN)이고,
# 이번 배포 동안만 실험실 폴더 안(.docker-gha)에 두었다가 받기가 끝나면 지운다(~/.docker 는 건드리지 않음).
# 공용 서버 보호: 팀 CI 가 돌면 끝날 때까지 기다리고(최대 10분), 새벽 백업 시간·디스크 부족·실험 중이면 배포하지 않는다.
set -uo pipefail
umask 077
LAB=/home/ubuntu/terre-lab
RES=$LAB/results
REG=ghcr.io/kjh-independency
CI_WAIT=600

say() { echo "[$(TZ=Asia/Seoul date '+%m-%d %H:%M:%S')] $*"; }
deny() { say "배포하지 않음: $*"; exit "${2:-4}"; }
ci_busy() {  # lab.sh 와 같은 판단: 팀 Runner 작업 컨테이너가 있거나 gitlab-runner 가 자식 작업을 돌리는 중
  local n rp
  n=$(docker ps --format '{{.Names}}' | grep -c '^runner-' || true)
  rp=$(pgrep -o -x gitlab-runner || true)
  if [ -n "$rp" ] && pgrep -P "$rp" >/dev/null 2>&1; then n=$((n + 1)); fi
  [ "$n" -gt 0 ]
}
backup_window() { local hm; hm=$(TZ=Asia/Seoul date +%H%M); [ "$((10#$hm))" -ge 350 ] && [ "$((10#$hm))" -le 420 ]; }

req=${SSH_ORIGINAL_COMMAND:-}
if [ "$req" = ping ]; then
  say "ok: 실험실 구성=$(cat "$LAB/variant" 2>/dev/null || echo 없음), 서비스 중인 색=$(cat "$LAB/bluegreen/state/active" 2>/dev/null || echo 없음)"
  exit 0
fi
if [ "$req" = backup ]; then
  exec 8>"$LAB/.gha.lock"
  flock -n 8 || { echo "백업하지 않음: 다른 배포·백업이 진행 중입니다"; exit 3; }
  exec bash "$LAB/bluegreen/gha-backup.sh"   # 표준 입력(업로드 주소)이 그대로 넘어간다
fi
if [[ ! $req =~ ^deploy\ ([0-9a-f]{40})\ ([0-9a-f]{40}|keep)$ ]]; then
  echo "거부: 허용되지 않은 요청입니다(ping, backup, deploy <커밋> <커밋|keep> 만 가능)"; exit 2
fi
sha=${BASH_REMATCH[1]}; scr=${BASH_REMATCH[2]}
short=${sha:0:12}

exec 8>"$LAB/.gha.lock"
flock -n 8 || deny "다른 GitHub Actions 배포가 진행 중입니다" 3

# 1) 실험실 상태
[ "$(cat "$LAB/variant" 2>/dev/null)" = bluegreen ] || deny "실험실이 블루-그린 구성이 아닙니다(4-lab-apply → 2)"
if [ -f "$RES/current.pid" ] && kill -0 "$(cat "$RES/current.pid")" 2>/dev/null; then deny "실험실 측정·구성 작업이 진행 중입니다"; fi
# 2) 공용 서버 보호
backup_window && deny "새벽 백업 시간대(03:50~04:20)입니다"
t0=$SECONDS
while ci_busy; do
  [ $((SECONDS - t0)) -ge "$CI_WAIT" ] && deny "팀 CI 가 10분 넘게 돌고 있어 이번에는 배포하지 않습니다"
  say "팀 CI 작업이 돌고 있어 끝날 때까지 기다립니다(30초마다 확인)"; sleep 30
done
disk=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "$disk" -ge 15 ] || deny "디스크 여유가 15GB보다 적습니다(${disk}GB)"
say "사전 확인 통과: 디스크 여유 ${disk}GB, 배포할 커밋 $short, screening=$( [ "$scr" = keep ] && echo 그대로 || echo "${scr:0:12}")"

# 3) 이미지 받기: 임시 토큰으로 이번에만 로그인하고 바로 지운다
IFS= read -r -t 15 tok || deny "GHCR 토큰을 받지 못했습니다"
[[ $tok =~ ^[!-~]{20,4096}$ ]] || deny "GHCR 토큰 형식이 이상합니다"   # 공백 없는 출력 가능 문자만(GitHub 토큰 형식은 바뀔 수 있어 접두어·길이를 고정하지 않음)
export DOCKER_CONFIG=$LAB/.docker-gha
rm -rf "$DOCKER_CONFIG"; mkdir -m 700 "$DOCKER_CONFIG"
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
printf '%s' "$tok" | docker login ghcr.io -u gha --password-stdin >/dev/null 2>&1 || deny "GHCR 로그인 실패"
unset tok
imgs=("$REG/terre-backend:$sha" "$REG/terre-web:$sha")
[ "$scr" != keep ] && imgs+=("$REG/terre-screening:$scr")
for i in "${imgs[@]}"; do
  say "받는 중: ${i#"$REG"/}"
  docker pull -q "$i" >/dev/null || { docker logout ghcr.io >/dev/null 2>&1; deny "이미지를 받지 못했습니다: $i" 5; }
done
docker logout ghcr.io >/dev/null 2>&1; rm -rf "$DOCKER_CONFIG"
say "이미지 받기 완료, 로그인 정보는 지웠습니다"

# 4) 블루-그린 배포(준비 확인에 실패하면 bg.sh 가 전환하지 않고 옛 색을 유지한다 = 자동 롤백)
bash "$LAB/bluegreen/bg.sh" deploy "$sha"; rc=$?
if [ "$rc" = 0 ] && [ "$scr" != keep ]; then bash "$LAB/bluegreen/bg.sh" screening "$scr" || rc=6; fi

# 5) 공용 서버 디스크 보호: 두 색과 screening 이 쓰는 이미지만 남기고 지난 GHCR 이미지는 지운다
#    우리 GHCR 이미지(이름이 ghcr.io/kjh-independency/terre-*)만 대상. 팀 이미지·공용 정리(prune)는 하지 않는다
keep=$(cut -d= -f2 "$LAB/bluegreen/release.env" 2>/dev/null)
docker image ls --format '{{.Repository}}:{{.Tag}}' | grep "^$REG/terre-" | while read -r i; do
  grep -qxF "$i" <<<"$keep" || docker image rm "$i" >/dev/null 2>&1 || true   # 멈춘 컨테이너가 쓰는 이미지는 남는다
done
say "끝(종료 코드 $rc). 남긴 GHCR 이미지: $(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -c "^$REG/terre-")개"
exit "$rc"
