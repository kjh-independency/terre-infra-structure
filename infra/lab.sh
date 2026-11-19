#!/usr/bin/env bash
# terre-lab: 11/6 구성(4ae439fb)을 운영과 분리해 같은 서버에서 재현하고 측정하는 실험실 (포트폴리오용)
#
# 지키는 것
#   - 운영(terre-service)·팀 CI·백업·방화벽·nginx 설정은 바꾸지 않는다.
#     운영은 읽기만 한다: 이미지 ID 확인, 응답 확인, 최신 백업 파일 읽기.
#   - 운영 .env 는 읽지 않는다. 실험실 비밀값은 새로 만들고 화면에 출력하지 않는다.
#   - 실험실 전체를 terrelab.slice 에 넣고 CPU 2개·메모리 4GB 상한과 낮은 우선순위를 건다. 부하 도구는 CPU 0.5개.
#   - 실험실 포트는 서버 안(127.0.0.1:18088)에만 연다.
#   - 이미지 이름에 '/backend:' 같은 글자를 넣지 않는다(팀 CI 의 이미지 정리 규칙에 걸리지 않게).
#   - 시험 중 운영 응답을 10초마다 확인하고, 1초 초과·오류가 2번 연속이면 실험실을 멈춘다.
#   - 팀 CI 가 도는 중이거나 새벽 4시 백업 시간대(03:50~04:20)면 시작하지 않는다.
#
# 사용: lab.sh preflight | up | status | test <tiles|flow|deploy|restore|crash-backend|crash-db> | down [purge]
#       lab.sh bg <명령...>  (서버에서 백그라운드로 실행)    lab.sh follow  (진행 기록 보기)
set -euo pipefail
export LC_ALL=C.UTF-8

LAB=/home/ubuntu/terre-lab
RES=$LAB/results
P=terre-lab
SLICE=terrelab.slice
LAB_URL=http://127.0.0.1:18088
PROD_PROBE=http://127.0.0.1:8088/api/v1/layers
BACKUP_DIR=/home/ubuntu/app/backups
TILES_HOST_DIR=/home/ubuntu/app/data/tiles
K6_IMAGE=grafana/k6:1.0.0
STEPS="${STEPS:-10 25 50 75 100}"
# 실험실 구성: base(11/6 구성) 또는 pregen(개선 1: 타일 미리 생성). 4-lab-apply 가 $LAB/variant 에 적는다
DC=(docker compose -p "$P" -f "$LAB/compose.lab.yml")
if [ "$(cat "$LAB/variant" 2>/dev/null)" = pregen ]; then DC+=(-f "$LAB/pregen/compose.pregen.yml"); fi
DC+=(--env-file "$LAB/.env")
# ②-1 블루-그린 구성은 bluegreen/compose.bg.yml 하나로 띄운다(4-lab-apply → 2)
if [ "$(cat "$LAB/variant" 2>/dev/null)" = bluegreen ]; then
  DC=(docker compose -p "$P" --project-directory "$LAB" -f "$LAB/bluegreen/compose.bg.yml" --env-file "$LAB/.env")
fi

say()   { printf '[%s] %s\n' "$(TZ=Asia/Seoul date '+%m-%d %H:%M:%S')" "$*"; }
die()   { say "중단: $*"; exit 1; }
now()   { date +%s.%N; }
secs()  { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
gt()    { awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0)>(b+0))}'; }
stamp() { TZ=Asia/Seoul date '+%m%d-%H%M'; }
load_env() { [ -f "$LAB/.env" ] || die "실험실 .env 가 없습니다. 1-lab-up 을 먼저 실행하세요"; set -a; . "$LAB/.env"; set +a; }
lab_exists() { [ -f "$LAB/.env" ] && [ -n "$("${DC[@]}" ps -aq 2>/dev/null)" ]; }
prod_probe() { curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}' "$PROD_PROBE" 2>/dev/null || true; }
lab_probe()  { curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}' "$LAB_URL/api/v1/layers" 2>/dev/null || true; }
mib() { awk '{ if ($1 ~ /^[0-9]+$/) printf "%d", $1/1048576; else printf "%s", $1 }'; }

ci_busy() {
  local n rp
  n=$(docker ps --format '{{.Names}}' | grep -c '^runner-' || true)
  rp=$(pgrep -o -x gitlab-runner || true)
  if [ -n "$rp" ] && pgrep -P "$rp" >/dev/null 2>&1; then n=$((n + 1)); fi
  [ "$n" -gt 0 ]
}
backup_window() { local hm; hm=$(TZ=Asia/Seoul date +%H%M); [ "$hm" -ge 350 ] && [ "$hm" -le 420 ]; }

preflight() {
  local ok=1 code t mem load disk
  if backup_window; then say "새벽 4시 백업 시간대(03:50~04:20)입니다"; ok=0; fi
  if ci_busy; then say "팀 CI 작업이 돌고 있습니다"; ok=0; fi
  read -r code t <<<"$(prod_probe)"
  if [ "${code:-000}" != 200 ] || gt "${t:-9}" 1.0; then say "운영 응답이 정상이 아닙니다(코드 ${code:-없음}, ${t:-?}초)"; ok=0
  else say "운영 응답 정상: 코드 $code, ${t}초"; fi
  mem=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  load=$(cut -d' ' -f1 /proc/loadavg)
  disk=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  say "서버 여유: 메모리 ${mem}MB, 1분 부하 평균 ${load}, 디스크 ${disk}GB"
  [ "$mem" -ge 6000 ] || { say "메모리 여유가 6GB보다 적습니다"; ok=0; }
  gt 2.0 "$load" || { say "서버 부하가 높습니다"; ok=0; }
  [ "$disk" -ge 20 ] || { say "디스크 여유가 20GB보다 적습니다"; ok=0; }
  [ "$ok" = 1 ] || die "사전 확인을 통과하지 못했습니다. 조금 뒤에 다시 실행하세요"
  say "사전 확인 통과"
}

ensure_env() {
  [ -f "$LAB/.env" ] && return 0
  umask 077
  local pw jwt adm lt
  pw=$(openssl rand -hex 16); jwt=$(openssl rand -hex 32); adm=$(openssl rand -hex 12); lt=$(openssl rand -hex 8)
  cat > "$LAB/.env" <<ENV
LAB_DB_USER=terre
LAB_DB_PASSWORD=$pw
LAB_JWT_SECRET=$jwt
LAB_ADMIN_EMAIL=lab-admin@example.com
LAB_ADMIN_PASSWORD=Lab-${adm}!A1
TILES_DIR=$TILES_HOST_DIR
LAB_WEB_PORT=18088
LAB_DEPLOY_ID=initial
ENV
  printf 'LOADTEST_PASSWORD=Lt-%s!A1\nPREFIX=lablt\n' "$lt" > "$LAB/.k6.env"
  chmod 600 "$LAB/.env" "$LAB/.k6.env"
  say "실험실 전용 비밀값을 새로 만들었습니다(화면에는 출력하지 않음)"
}

tag_images() {
  local s id
  for s in backend web screening; do
    docker image inspect "terre-lab-$s:snap" >/dev/null 2>&1 && continue
    id=$(docker inspect -f '{{.Image}}' "terre-service-$s-1" 2>/dev/null) || die "운영 $s 컨테이너의 이미지를 찾지 못했습니다"
    docker tag "$id" "terre-lab-$s:snap"
    echo "$s $(docker inspect -f '{{.Config.Image}}' "terre-service-$s-1") ${id:7:12}" >> "$LAB/images.txt"
  done
  say "실험실 이미지(운영 이미지에 이름만 추가): $(awk '{printf "%s=%s  ", $1, $2}' "$LAB/images.txt")"
}

limit_slice() {
  if ! sudo -n systemctl set-property "$SLICE" CPUQuota=200% CPUWeight=20 MemoryMax=4G; then
    "${DC[@]}" down -v >/dev/null 2>&1 || true
    die "실험실 자원 상한을 걸지 못해 실험실을 지웠습니다"
  fi
  local q m parent
  q=$(systemctl show "$SLICE" -p CPUQuotaPerSecUSec --value)
  m=$(systemctl show "$SLICE" -p MemoryMax --value)
  parent=$(docker inspect -f '{{.HostConfig.CgroupParent}}' terre-lab-db-1 2>/dev/null || true)
  if [ "$q" != "2s" ] || [ "$m" != "4294967296" ] || [ "$parent" != "$SLICE" ]; then
    "${DC[@]}" down -v >/dev/null 2>&1 || true
    die "자원 상한 확인 실패(CPU $q, 메모리 $m, 소속 $parent). 실험실을 지웠습니다"
  fi
  say "자원 상한 확인: 실험실 전체 CPU 2개, 메모리 4GB, 운영보다 낮은 우선순위"
}

wait_healthy() {
  local c="terre-lab-$1-1" t=0 s
  while :; do
    s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)
    [ "$s" = healthy ] && return 0
    [ "$t" -ge "$2" ] && die "$1 이(가) ${2}초 안에 준비되지 않았습니다(상태 $s)"
    sleep 2; t=$((t + 2))
  done
}
wait_url() {
  local t=0 code
  while :; do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || true)
    [ "$code" = 200 ] && return 0
    [ "$t" -ge "$2" ] && die "$1 이(가) ${2}초 안에 응답하지 않았습니다(코드 $code)"
    sleep 2; t=$((t + 2))
  done
}

write_meta() {
  local out=$1
  {
    echo "test=$2"
    echo "kst=$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S')"
    echo "load_avg=$(cut -d' ' -f1-3 /proc/loadavg)"
    echo "mem_available_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
    echo "ci_busy=$(ci_busy && echo yes || echo no)"
    echo "prod_probe=$(prod_probe)"
    echo "slice_cpu=$(systemctl show "$SLICE" -p CPUQuotaPerSecUSec --value 2>/dev/null || true)"
    echo "slice_mem_max=$(systemctl show "$SLICE" -p MemoryMax --value 2>/dev/null || true)"
    [ -f "$LAB/images.txt" ] && awk '{print "image_" $1 "=" $2 " (" $3 ")"}' "$LAB/images.txt"
    echo "k6_image=$K6_IMAGE"
  } > "$out/meta.txt"
}

restore_db() {
  local out=$1 f t1 t2 t3
  f=$(ls -1t "$BACKUP_DIR"/*.sql.gz 2>/dev/null | head -1 || true)
  [ -n "$f" ] || die "운영 백업 파일을 찾지 못했습니다"
  {
    echo "backup_file=$(basename "$f")"
    echo "backup_size_mb=$(( $(stat -c %s "$f") / 1048576 ))"
    echo "backup_age_minutes=$(( ($(date +%s) - $(stat -c %Y "$f")) / 60 ))"
  } >> "$out/metrics.txt"
  docker exec terre-lab-db-1 sh -c 'dropdb -U "$POSTGRES_USER" --if-exists --force terre && createdb -U "$POSTGRES_USER" -T template0 terre'
  say "복원 시작: $(basename "$f") → 실험실 DB (내용은 화면에 출력하지 않음)"
  t1=$(now); echo "$t1" > "$out/.t_restore_start"
  gunzip -c "$f" | docker exec -i terre-lab-db-1 sh -c 'psql -U "$POSTGRES_USER" -d terre -q -v ON_ERROR_STOP=0 >/dev/null' 2> "$out/.restore.err" || true
  t2=$(now)
  docker exec terre-lab-db-1 sh -c 'vacuumdb -U "$POSTGRES_USER" -d terre --analyze-only -q'
  t3=$(now)
  echo "restore_seconds=$(secs "$t1" "$t2")" >> "$out/metrics.txt"
  echo "analyze_seconds=$(secs "$t2" "$t3")" >> "$out/metrics.txt"
  # 오류는 종류별 건수만 남긴다. 값이 섞일 수 있는 DETAIL·LINE 줄은 버리고, 따옴표 안 글자와 숫자는 가린다
  grep -oE 'ERROR: .*' "$out/.restore.err" 2>/dev/null | sed -E 's/"[^"]*"/"~"/g; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -20 > "$out/restore-errors.txt" || true
  rm -f "$out/.restore.err"
  echo "restore_error_kinds=$(wc -l < "$out/restore-errors.txt" | tr -d ' ')" >> "$out/metrics.txt"
  docker exec terre-lab-db-1 sh -c 'psql -U "$POSTGRES_USER" -d terre -At -c "select count(*) from species" -c "select count(*) from protected_area" -c "select coalesce(max(version::int),0) from flyway_schema_history where success"' \
    | paste -sd' ' | awk '{print "verify_species=" $1; print "verify_protected_area=" $2; print "verify_flyway=V" $3}' >> "$out/metrics.txt"
  say "복원 끝: $(secs "$t1" "$t2")초, 통계 갱신 $(secs "$t2" "$t3")초"
}

start_app_and_measure() {
  local out=$1 t4 t5
  t4=$(now)
  "${DC[@]}" up -d
  wait_healthy backend 600
  wait_url "$LAB_URL/api/v1/layers" 180
  t5=$(now)
  echo "app_start_seconds=$(secs "$t4" "$t5")" >> "$out/metrics.txt"
  echo "rto_seconds=$(secs "$(cat "$out/.t_restore_start")" "$t5")" >> "$out/metrics.txt"
  say "서비스 응답 확인: 앱 시작 $(secs "$t4" "$t5")초, 복원 시작부터 $(secs "$(cat "$out/.t_restore_start")" "$t5")초"
}

after_check() {
  local out=$1
  {
    echo "prod_probe=$(prod_probe)"
    echo "lab_probe=$(lab_probe)"
    echo "slice_memory_mb=$(systemctl show "$SLICE" -p MemoryCurrent --value 2>/dev/null | mib)"
    docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}'
  } | tee "$out/after.txt"
}

finish() {
  local out=$1
  python3 "$LAB/tools/summarize.py" "$out" || say "주의: 결과 정리 중 오류가 났습니다"
  cp "$RES/current.log" "$out/run.log" 2>/dev/null || true
}

cmd_up() {
  mkdir -p "$RES"
  preflight
  lab_exists && die "이미 terre-lab이 있습니다. 3-lab-status 로 확인하거나 9-lab-down 으로 지운 뒤 다시 하세요"
  ensure_env; load_env; tag_images
  docker pull -q "$K6_IMAGE" >/dev/null 2>&1 || say "주의: 부하 도구 이미지를 받지 못했습니다(시험 때 다시 시도)"
  local out; out="$RES/$(stamp)-T4-up"; mkdir -p "$out"
  say "1/4 DB·Redis 시작"
  "${DC[@]}" up -d db redis
  limit_slice
  write_meta "$out" "T4 백업 복원 (실험실 처음 띄우기)"
  wait_healthy db 180; wait_healthy redis 60
  say "2/4 최신 운영 백업을 실험실 DB로 복원 (T4 측정)"
  restore_db "$out"
  say "3/4 backend·screening·web 시작"
  start_app_and_measure "$out"
  say "4/4 운영·실험실 상태 확인"
  after_check "$out"
  finish "$out"
}

# ---------- 시험 ----------
k6_run() {   # k6_run <결과폴더> <스크립트> <이름> [docker -e 인자...]
  local out=$1 script=$2 tag=$3; shift 3
  docker run --rm --name terre-lab-k6 --label terre-lab=k6 --network terre-lab_default \
    --cpus 0.5 --memory 1g --cpu-shares 256 --user "$(id -u):$(id -g)" \
    -v "$LAB/k6:/scripts:ro" -v "$out:/out" --env-file "$LAB/.k6.env" -e BASE=http://web "$@" \
    "$K6_IMAGE" run --quiet --summary-export "/out/$tag.json" "/scripts/$script" > "$out/$tag.log" 2>&1
}
k6_probe() { # k6_probe <결과폴더> <시간>
  docker run --rm --name terre-lab-k6 --label terre-lab=k6 --network terre-lab_default \
    --cpus 0.5 --memory 1g --cpu-shares 256 --user "$(id -u):$(id -g)" \
    -v "$LAB/k6:/scripts:ro" -v "$1:/out" -e BASE=http://web -e RATE=10 -e DURATION="$2" \
    "$K6_IMAGE" run --quiet --summary-export /out/probe.json --out json=/out/probe.json.gz /scripts/probe.js > "$1/probe.log" 2>&1
}

watchdog() {  # 운영 보호: 10초마다 운영 응답 확인, 1초 초과·오류 2번 연속이면 실험실 정지
  set +e
  local out=$1 bad=0 code t
  echo "kst,code,seconds" > "$out/prod.csv"
  while [ ! -f "$out/.stop" ]; do
    read -r code t <<<"$(prod_probe)"
    echo "$(TZ=Asia/Seoul date '+%H:%M:%S'),${code:-000},${t:-5}" >> "$out/prod.csv"
    if [ "${code:-000}" != 200 ] || gt "${t:-5}" 1.0; then bad=$((bad + 1)); else bad=0; fi
    if [ "$bad" -ge 2 ]; then
      echo "운영 응답 이상(코드 ${code:-000}, ${t:-?}초)이 2번 연속이라 실험실을 멈췄습니다" > "$out/ABORTED"
      docker rm -f $(docker ps -q --filter label=terre-lab=k6) >/dev/null 2>&1
      "${DC[@]}" stop >/dev/null 2>&1
      say "운영 보호 장치 작동: 실험실을 멈췄습니다"
      break
    fi
    if ci_busy; then  # 팀 CI 가 시험 도중 시작되면 CPU 를 빼앗겨 결과가 왜곡되므로 부하만 멈춘다(실험실은 그대로)
      echo "팀 CI가 시험 도중($(TZ=Asia/Seoul date '+%H:%M:%S')) 시작돼 부하를 멈췄습니다. CPU를 빼앗긴 상태라 이 결과는 쓰지 않고 CI가 끝난 뒤 다시 잽니다" > "$out/ABORTED"
      docker rm -f $(docker ps -q --filter label=terre-lab=k6) >/dev/null 2>&1
      say "팀 CI가 시작돼 시험을 멈췄습니다(실험실은 그대로 둡니다). CI가 끝난 뒤 같은 번호로 다시 하세요"
      break
    fi
    sleep 10
  done
}
monitor() {   # 3~5초마다 컨테이너별 CPU·메모리(운영 포함), 실험실 DB 연결 수 기록
  set +e
  local out=$1 e c
  echo "epoch,name,cpu,mem" > "$out/stats.csv"
  echo "epoch,active,total,parallel" > "$out/dbconn.csv"
  while [ ! -f "$out/.stop" ]; do
    e=$(date +%s)
    docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' 2>/dev/null | sed "s/^/$e,/" >> "$out/stats.csv"
    c=$(docker exec terre-lab-db-1 sh -c "psql -U \"\$POSTGRES_USER\" -d terre -At -F, -c \"select count(*) filter (where state='active' and backend_type='client backend'), count(*) filter (where backend_type='client backend'), count(*) filter (where backend_type='parallel worker') from pg_stat_activity where datname='terre'\"" 2>/dev/null)
    [ -n "$c" ] && echo "$e,$c" >> "$out/dbconn.csv"
    sleep 3
  done
}

run_steps() {  # 동시 사용자 단계를 하나씩 따로 돌린다(단계별 수치가 나오고, 무너진 단계 다음은 건너뛴다)
  local out=$1 script=$2 n first=1 rc warm s err
  echo "step,start,end,rc" > "$out/steps.csv"
  for n in $STEPS; do
    [ -f "$out/ABORTED" ] && { say "운영 보호 장치가 작동해 남은 단계를 건너뜁니다"; break; }
    warm=0s; [ "$first" = 1 ] && warm=1m; first=0
    say "단계: 동시 사용자 ${n}명 (올리기 30초 + 유지 2분 + 내리기 30초$([ "$warm" = 1m ] && echo ' + 데우기 1분 30초'))"
    s=$(date +%s); rc=0
    k6_run "$out" "$script" "step-$n" -e STEPS="$n" -e HOLD=2m -e WARMUP="$warm" -e ACCOUNTS=10 "${K6_EXTRA[@]}" || rc=$?
    echo "$n,$s,$(date +%s),$rc" >> "$out/steps.csv"
    err=$(python3 "$LAB/tools/summarize.py" --err "$out/step-$n.json" 2>/dev/null || echo 1)
    say "  끝: 에러율 $err (k6 종료 코드 $rc)"
    if gt "$err" 0.10; then say "에러율이 10%를 넘어 더 높은 단계는 하지 않습니다"; break; fi
    say "  1분 쉬기"; sleep 60
  done
}

ensure_accounts() {
  local out=$1 rc=0
  [ -f "$LAB/.accounts_ready" ] && return 0
  say "시나리오 B 테스트 계정 10개·사업장 준비 (실험실 DB에만 만든다)"
  k6_run "$out" setup-accounts.js setup-accounts -e ACCOUNTS=10 || rc=$?
  if [ "$rc" != 0 ]; then tail -n 20 "$out/setup-accounts.log" || true; die "테스트 계정 준비 실패(종료 코드 $rc)"; fi
  touch "$LAB/.accounts_ready"
}

crash() {
  local svc=$1 pid
  pid=$(docker inspect -f '{{.State.Pid}}' "terre-lab-$svc-1" 2>/dev/null || true)
  { [ -n "$pid" ] && [ "$pid" != 0 ]; } || die "실험실 $svc 프로세스를 찾지 못했습니다"
  say "실험실 $svc 을(를) 강제 종료합니다(kill -9). 자동 재시작 정책으로 다시 뜨는지 봅니다"
  sudo -n kill -9 "$pid"
}

run_event() {  # 5분 동안 1초에 10번 요청하면서 1분 뒤에 사건(배포·장애)을 일으킨다
  local out=$1 kind=$2 kp
  echo "event,epoch" > "$out/events.csv"
  say "1초에 10번씩 5분 동안 요청을 보내면서, 1분 뒤에 '$kind' 을(를) 일으킵니다"
  local pd=5m; [ "$kind" = deploy-bg ] && pd=7m   # 블루-그린은 준비가 길어 7분 동안 본다
  k6_probe "$out" "$pd" & kp=$!
  sleep 60
  if [ -f "$out/ABORTED" ]; then say "시험이 중단돼 사건을 일으키지 않습니다"; wait "$kp" || true; return 0; fi
  echo "start,$(now)" >> "$out/events.csv"
  case $kind in
    deploy)
      say "지금 방식대로 배포: backend·screening·web 을 그 자리에서 새로 만듭니다(팀 CI 의 compose up 과 같은 순서)"
      LAB_DEPLOY_ID="deploy-$(date +%s)" "${DC[@]}" up -d >> "$out/event.log" 2>&1 || say "주의: 배포 명령이 오류로 끝났습니다(event.log 확인)"
      ;;
    crash-backend) crash backend ;;
    deploy-bg)
      say "블루-그린 배포: 쉬는 색에 새 버전을 띄우고, 준비되면 입구만 새 색으로 바꿉니다"
      bash "$LAB/bluegreen/bg.sh" deploy > "$out/bg-deploy.txt" 2>&1 || say "주의: 블루-그린 배포가 전환 없이 끝났습니다(bg-deploy.txt 확인)"
      grep -E "^(result|from|to|prep_cpus|prepare_seconds|total_seconds)=" "$out/bg-deploy.txt" >> "$out/metrics.txt" 2>/dev/null || true
      ;;
    crash-db) crash db ;;
  esac
  echo "end,$(now)" >> "$out/events.csv"
  say "사건 끝. 남은 시간 동안 회복을 지켜봅니다"
  wait "$kp" || true
}

run_restore() {
  local out=$1
  say "앱을 멈추고 실험실 DB를 지운 뒤 최신 백업에서 다시 복원합니다(T4 재측정)"
  "${DC[@]}" stop backend screening web
  restore_db "$out"
  rm -f "$LAB/.accounts_ready"
  start_app_and_measure "$out"
}

run_hide() {  # T6 보호지역 즉시 숨김: 실험실 DB 에서 종류 하나를 잠깐 비공개로 바꿨다가 되돌린다
  local out=$1
  say "보호지역 즉시 숨김 시험: 실험실 DB 에서 보호지역 종류 하나를 잠깐 비공개로 바꿉니다(운영 DB 는 건드리지 않음)"
  python3 "$LAB/pregen/hide_test.py" "$out" "$LAB_URL" || say "주의: 숨김 시험이 오류로 끝났습니다(결과 폴더 확인)"
}

cmd_test() {
  local kind=${1:-} label out wpid mpid
  case "$kind" in
    tiles) label=T1-tiles ;; flow) label=T2-flow ;; deploy) label=T3-deploy ;;
    restore) label=T4-restore ;; crash-backend) label=T5-crash-backend ;; crash-db) label=T5-crash-db ;;
    hide) label=T6-hide ;;
    tiles-cdn) label=T1-tiles-cdn ;;
    deploy-cdn) label=T3-deploy-cdn ;;
    deploy-bg) label=T3-deploy-bg ;;
    *) die "알 수 없는 시험: $kind (tiles|tiles-cdn|flow|deploy|deploy-cdn|deploy-bg|restore|crash-backend|crash-db|hide)" ;;
  esac
  load_env
  lab_exists || die "terre-lab이 떠 있지 않습니다. 1-lab-up 을 먼저 실행하세요"
  preflight
  [ "$(lab_probe | cut -d' ' -f1)" = 200 ] || die "실험실이 응답하지 않습니다. 3-lab-status 로 확인하세요"
  out="$RES/$(stamp)-$label"; mkdir -p "$out"
  write_meta "$out" "$label"
  local v; v=$(cat "$LAB/variant" 2>/dev/null || echo base)
  echo "variant=$v" >> "$out/meta.txt"
  case "$v" in pregen) v="개선 1 적용(경계 타일 미리 생성)" ;; bluegreen) v="개선 1 + ②-1 블루-그린(입구 nginx + 색깔별 web·backend)" ;; *) v="기준(11/6 구성)" ;; esac
  printf '## 실험실 구성\n\n- %s\n' "$v" > "$out/variant.md"
  K6_EXTRA=(); local cdn=""
  if [ "$kind" = tiles-cdn ] || [ "$kind" = deploy-cdn ]; then  # AWS 단계: 행정구역 타일만 CloudFront(S3)에서 받는다
    cdn=$(tr -d '\r\n ' < "$LAB/pregen/cdn_url" 2>/dev/null)
    [ -n "$cdn" ] || die "pregen/cdn_url 에 CloudFront 주소가 없습니다"
    K6_EXTRA=(-e TILE_CDN="$cdn")
    printf -- '- 행정구역(시군구·읍면동) 타일: CloudFront(S3) %s 에서 받음. 나머지는 실험실\n' "$cdn" >> "$out/variant.md"
  fi
  watchdog "$out" & wpid=$!
  monitor "$out" & mpid=$!
  case "$kind" in
    tiles|tiles-cdn) run_steps "$out" a-tiles.js ;;
    flow) ensure_accounts "$out"; run_steps "$out" b-flow.js ;;
    deploy|crash-backend|crash-db) run_event "$out" "$kind" ;;
    deploy-bg)
      [ "$(cat "$LAB/variant" 2>/dev/null)" = bluegreen ] || die "블루-그린 구성이 아닙니다. 4-lab-apply → 2 를 먼저 하세요"
      run_event "$out" deploy-bg ;;
    deploy-cdn)  # 배포 동안 행정구역 타일을 서버 nginx 와 CloudFront 두 경로로 받아 비교
      local tp; python3 "$LAB/pregen/tile_probe.py" "$out" "$LAB_URL" "$cdn" > "$out/tile-probe.log" 2>&1 & tp=$!
      run_event "$out" deploy
      touch "$out/.probe_stop"; wait "$tp" 2>/dev/null || true ;;
    restore) run_restore "$out" ;;
    hide) run_hide "$out" ;;
  esac
  touch "$out/.stop"; wait "$wpid" "$mpid" 2>/dev/null || true
  after_check "$out" >/dev/null
  finish "$out"
}

cmd_status() {
  if [ ! -f "$LAB/.env" ]; then say "terre-lab이 아직 없습니다"; return 0; fi
  load_env
  "${DC[@]}" ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}' || true
  say "운영 응답: $(prod_probe)"
  say "실험실 응답: $(lab_probe)"
  say "실험실 자원: CPU 상한 $(systemctl show "$SLICE" -p CPUQuotaPerSecUSec --value 2>/dev/null | sed 's/s$/개/'), 메모리 상한 $(systemctl show "$SLICE" -p MemoryMax --value 2>/dev/null | mib)MB, 지금 메모리 $(systemctl show "$SLICE" -p MemoryCurrent --value 2>/dev/null | mib)MB"
  docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}'
  if [ -f "$RES/current.pid" ] && kill -0 "$(cat "$RES/current.pid")" 2>/dev/null; then say "서버에서 진행 중인 작업이 있습니다"; fi
  say "결과 폴더: $(ls -1 "$RES" 2>/dev/null | grep -v '^current' | tr '\n' ' ')"
}

cmd_down() {
  local purge=${1:-}
  if [ -f "$RES/current.pid" ] && kill -0 "$(cat "$RES/current.pid")" 2>/dev/null; then kill "$(cat "$RES/current.pid")" 2>/dev/null || true; fi
  docker rm -f $(docker ps -aq --filter label=terre-lab=k6) >/dev/null 2>&1 || true
  if [ -f "$LAB/.env" ]; then "${DC[@]}" down -v --remove-orphans || true; fi
  sudo -n systemctl revert "$SLICE" >/dev/null 2>&1 || true
  rm -f "$LAB/.accounts_ready"
  say "terre-lab 컨테이너·저장 공간·네트워크를 지우고 자원 상한 설정을 되돌렸습니다"
  if [ "$purge" = purge ]; then
    docker rmi terre-lab-backend:snap terre-lab-web:snap terre-lab-screening:snap >/dev/null 2>&1 || true
    docker rmi "$K6_IMAGE" >/dev/null 2>&1 || true
    rm -f "$LAB/images.txt"
    say "실험실 이미지 이름과 부하 도구 이미지를 지웠습니다(운영 이미지는 그대로)"
    docker image ls --format '{{.Repository}}:{{.Tag}}' | grep '^ghcr.io/kjh-independency/terre-' | xargs -r docker rmi >/dev/null 2>&1 || true
    if [ -f "$LAB/bluegreen/gha-key.sh" ]; then bash "$LAB/bluegreen/gha-key.sh" remove || say "GitHub Actions 제한 키 줄을 빼지 못했습니다. 직접 확인하세요"; fi
    say "②-2 GHCR 이미지와 GitHub Actions 제한 키 줄도 정리했습니다"
  fi
  say "운영 응답: $(prod_probe)"
}

cmd_bg() {
  mkdir -p "$RES"
  if [ -f "$RES/current.pid" ] && kill -0 "$(cat "$RES/current.pid")" 2>/dev/null; then die "이미 서버에서 진행 중인 작업이 있습니다(3-lab-status 로 확인)"; fi
  setsid nohup bash "$LAB/lab.sh" "$@" > "$RES/current.log" 2>&1 < /dev/null &
  echo $! > "$RES/current.pid"
  say "서버에서 시작했습니다: $*  (이 창을 닫아도 서버에서는 계속 진행됩니다)"
}
cmd_follow() {
  local pid; pid=$(cat "$RES/current.pid" 2>/dev/null || true)
  [ -n "$pid" ] || die "진행 중인 작업이 없습니다"
  tail --pid="$pid" -n +1 -f "$RES/current.log" || true
}

case "${1:-}" in
  preflight) preflight ;;
  up) cmd_up ;;
  status) cmd_status ;;
  test) cmd_test "${2:-}" ;;
  down) cmd_down "${2:-}" ;;
  bg) shift; cmd_bg "$@" ;;
  follow) cmd_follow ;;
  *) sed -n '2,17p' "$0" ;;
esac
