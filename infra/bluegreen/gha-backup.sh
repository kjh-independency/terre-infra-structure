#!/usr/bin/env bash
# ③ S3 백업. gha-deploy.sh(제한 키 입구)가 "backup" 요청을 받으면 이 스크립트로 넘긴다.
# 표준 입력: GitHub Actions 가 OIDC 로 받은 임시 권한으로 만든 S3 '업로드 전용' 주소(서명된 URL, 1시간 안에 만료) 한 줄.
# 서버와 GitHub 어디에도 AWS 키를 두지 않는다. 이 주소로는 정해진 파일 하나를 올리는 것만 가능하다.
# 백업 범위: 실험실 DB 전체 구조 + 공공·참조 데이터. 사용자·고객이 만든 데이터 표는 구조만(데이터 제외).
# 덤프 내용은 열어 보지 않는다. 크기와 sha256 만 기록한다.
set -uo pipefail
umask 077
LAB=/home/ubuntu/terre-lab
RES=$LAB/results
DB=terre-lab-db-1
BUCKET_RE='^https://your-backup-bucket\.s3\.ap-northeast-2\.amazonaws\.com/lab-db/[0-9]{8}-[0-9]{4}\.dump\?[!-~]+$'
CI_WAIT=600
# 데이터를 빼고 구조만 넣을 표(사용자·고객이 만든 데이터). 이름 규칙(*)은 pg_dump 패턴
NO_DATA=(
  public.member public.inquiry                                   # 개인정보(이메일·이름·비밀번호 해시·문의)
  public.organization public.org_framework public.site public.site_material public.customer_project
  public.assessment public.indicator_explanation public.report_snapshot public.evidence
  public.issue_result public.issue_activity public.pressure_result public.action_recommendation
  public.spatial_finding public.priority_matrix public.survey_summary
  public.monitoring_kpi public.monitoring_value public.species_observation public.species_candidate
  public.upload public.upload_log public.pdf_analysis public.pdf_evidence_candidate
  public.company_evidence_review public.candidate_review_log public.app_setting 'public.rnw_*'
)

say() { echo "[$(TZ=Asia/Seoul date '+%m-%d %H:%M:%S')] $*"; }
hist() { printf '%s\t%s\n' "$(TZ=Asia/Seoul date '+%F %T')" "$*" >> "$RES/backup-history.log"; }
deny() { say "백업하지 않음: $1"; hist "skip $1"; exit "${2:-4}"; }
ci_busy() {
  local n rp
  n=$(docker ps --format '{{.Names}}' | grep -c '^runner-' || true)
  rp=$(pgrep -o -x gitlab-runner || true)
  if [ -n "$rp" ] && pgrep -P "$rp" >/dev/null 2>&1; then n=$((n + 1)); fi
  [ "$n" -gt 0 ]
}
backup_window() { local hm; hm=$(TZ=Asia/Seoul date +%H%M); [ "$((10#$hm))" -ge 350 ] && [ "$((10#$hm))" -le 420 ]; }

mkdir -p "$RES"
IFS= read -r -t 15 url || deny "업로드 주소를 받지 못했습니다"
[[ $url =~ $BUCKET_RE ]] || deny "업로드 주소가 예상한 버킷·경로가 아닙니다"
key=${url%%\?*}; key=${key#*amazonaws.com/}

[ "$(docker inspect -f '{{.State.Running}}' "$DB" 2>/dev/null)" = true ] || deny "실험실 DB 가 떠 있지 않습니다"
if [ -f "$RES/current.pid" ] && kill -0 "$(cat "$RES/current.pid")" 2>/dev/null; then deny "실험실 측정·구성 작업이 진행 중입니다"; fi
backup_window && deny "팀 새벽 백업 시간대(03:50~04:20)입니다"
t0=$SECONDS
while ci_busy; do
  [ $((SECONDS - t0)) -ge "$CI_WAIT" ] && deny "팀 CI 가 10분 넘게 돌고 있습니다"
  say "팀 CI 작업이 돌고 있어 기다립니다(30초마다 확인)"; sleep 30
done
disk=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "$disk" -ge 15 ] || deny "디스크 여유가 15GB보다 적습니다(${disk}GB)"

u=$(grep '^LAB_DB_USER=' "$LAB/.env" | cut -d= -f2-)
exc=(); for t in "${NO_DATA[@]}"; do exc+=(--exclude-table-data="$t"); done
mkdir -p "$LAB/backup" && chmod 700 "$LAB/backup"
tmp="$LAB/backup/$(basename "$key")"
trap 'rm -f "$tmp"' EXIT

say "덤프 시작: 실험실 DB(구조 전체 + 공공·참조 데이터, 사용자·고객 데이터 표 ${#NO_DATA[@]}개는 구조만) → $key"
s=$SECONDS
docker exec "$DB" pg_dump -U "$u" -d terre -Fc -Z 6 "${exc[@]}" > "$tmp" || deny "pg_dump 실패" 5
dump_s=$((SECONDS - s)); size=$(stat -c %s "$tmp"); sum=$(sha256sum "$tmp" | cut -c1-64)
say "덤프 완료: $((size / 1048576))MB, ${dump_s}초"

s=$SECONDS
code=$(curl -sS -o /dev/null -w '%{http_code}' --retry 2 --max-time 900 --upload-file "$tmp" "$url") || code=000
up_s=$((SECONDS - s))
[ "$code" = 200 ] || deny "S3 업로드 실패(HTTP $code)" 6
say "업로드 완료: HTTP 200, ${up_s}초 (서버의 임시 파일은 지움)"
hist "ok $key size=$size sha256=$sum dump=${dump_s}s upload=${up_s}s"
printf 'result=uploaded\nkey=%s\nsize_bytes=%s\nsha256=%s\ndump_seconds=%s\nupload_seconds=%s\n' "$key" "$size" "$sum" "$dump_s" "$up_s"
