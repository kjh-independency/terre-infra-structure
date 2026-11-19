#!/usr/bin/env bash
# ②-2 GitHub Actions 전용 제한 키를 공용 서버의 ~/.ssh/authorized_keys 에 넣고 빼는 스크립트(10-gha-setup.cmd 가 부른다).
#   add    : 표준 입력의 공개 키 한 줄을 'restrict,command=...' 를 붙여 맨 끝에 덧붙인다(기존 줄은 한 글자도 바꾸지 않음)
#   remove : 표시(terre-lab-gha)가 붙은 줄만 뺀다(실험실 정리 때, 11/26 까지)
#   check  : 표시 줄이 몇 개인지, 전체 키 수
#   info   : 배포 전 점검(읽기만)
#   hostkey <호스트이름> : GitHub Secrets(LAB_KNOWN_HOSTS)에 넣을 서버 공개 호스트 키 한 줄
# 안전장치: 바꾸기 전에 사본(~/.ssh/authorized_keys.bak-terre-lab)을 만들고, 바꾼 뒤 키 수가 기대와 다르면 사본으로 되돌린다.
set -euo pipefail
AK=$HOME/.ssh/authorized_keys
BAK=$HOME/.ssh/authorized_keys.bak-terre-lab
MARK=terre-lab-gha
ENTRY='/home/ubuntu/terre-lab/bluegreen/gha-deploy.sh'
count() { ssh-keygen -l -f "$AK" 2>/dev/null | wc -l; }
marked() { grep -c " $MARK\$" "$AK" || true; }

case "${1:-}" in
  add)
    IFS= read -r pub
    pub=${pub%$'\r'}
    [[ $pub =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}\ $MARK$ ]] || { echo "중단: 공개 키 형식이 예상과 다릅니다"; exit 2; }
    [ "$(marked)" = 0 ] || { echo "이미 등록돼 있습니다(표시 줄 $(marked)개). 그대로 둡니다"; exit 0; }
    before=$(count)
    cp -p "$AK" "$BAK"
    [ -z "$(tail -c1 "$AK")" ] || echo >> "$AK"   # 마지막 줄에 줄바꿈이 없으면 붙인다
    printf 'restrict,command="bash %s" %s\n' "$ENTRY" "$pub" >> "$AK"
    after=$(count)
    if [ "$after" != $((before + 1)) ]; then cp -p "$BAK" "$AK"; echo "중단: 키 수가 $before → $after 라 사본으로 되돌렸습니다"; exit 1; fi
    echo "등록: 키 $before 개 → $after 개(맨 끝 한 줄 추가, 기존 줄 변경 없음). 사본: $BAK"
    ;;
  remove)
    [ "$(marked)" != 0 ] || { echo "등록된 줄이 없습니다"; exit 0; }
    before=$(count); n=$(marked)
    cp -p "$AK" "$BAK"
    grep -v " $MARK\$" "$BAK" > "$AK.tmp-terre-lab" || true
    after=$(ssh-keygen -l -f "$AK.tmp-terre-lab" 2>/dev/null | wc -l)
    if [ "$after" != $((before - n)) ] || [ "$after" = 0 ]; then rm -f "$AK.tmp-terre-lab"; echo "중단: 키 수가 맞지 않아 바꾸지 않았습니다"; exit 1; fi
    cat "$AK.tmp-terre-lab" > "$AK"; rm -f "$AK.tmp-terre-lab"   # 같은 파일에 덮어써 권한·소유자를 그대로 둔다
    echo "삭제: 키 $before 개 → $after 개. 사본: $BAK"
    ;;
  check)
    echo "전체 키 $(count)개, 실험실 제한 키 $(marked)개, 권한 $(stat -c '%a %U' "$AK")"
    ;;
  hostkey)
    [ -n "${2:-}" ] || { echo "사용: gha-key.sh hostkey <호스트이름>"; exit 2; }
    echo "$2 $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
    ;;
  info)   # 배포 전에 확인할 서버 사실(읽기만): CPU 종류, docker·compose 버전, 디스크, 실험실 DB 의 마이그레이션 번호
    echo "cpu=$(uname -m) docker=$(docker version -f '{{.Server.Version}}' 2>/dev/null) compose=$(docker compose version --short 2>/dev/null)"
    echo "disk_free=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)GB variant=$(cat /home/ubuntu/terre-lab/variant 2>/dev/null) active=$(cat /home/ubuntu/terre-lab/bluegreen/state/active 2>/dev/null)"
    u=$(grep '^LAB_DB_USER=' /home/ubuntu/terre-lab/.env | cut -d= -f2-)
    echo "lab_db_migrations(최근 3개)=$(docker exec terre-lab-db-1 psql -U "$u" -d terre -tAc "select string_agg(version, ',') from (select version from flyway_schema_history where success order by installed_rank desc limit 3) t" 2>/dev/null)"
    ;;
  *) echo "사용: gha-key.sh add|remove|check|info|hostkey <호스트>"; exit 2 ;;
esac
