#!/usr/bin/env bash
# ③ 백업 설계용: 실험실 DB 의 크기와 표·열 '이름'만 본다(데이터 내용은 읽지 않음). 15-db-info.cmd 가 표준 입력으로 실행
LAB=/home/ubuntu/terre-lab
u=$(grep '^LAB_DB_USER=' "$LAB/.env" | cut -d= -f2-)
q() { docker exec terre-lab-db-1 psql -U "$u" -d terre -tA -F ' | ' -c "$1"; }
echo "== DB 전체 크기: $(q "select pg_size_pretty(pg_database_size('terre'))")"
echo "== 스키마: $(q "select string_agg(nspname, ', ') from pg_namespace where nspname !~ '^pg_' and nspname <> 'information_schema'")"
echo "== 표(큰 순): 스키마.표 | 예상 행 수 | 크기"
q "select n.nspname||'.'||c.relname, c.reltuples::bigint, pg_size_pretty(pg_total_relation_size(c.oid)) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p') and n.nspname !~ '^pg_' and n.nspname <> 'information_schema' order by pg_total_relation_size(c.oid) desc"
echo "== 개인정보일 수 있는 열 이름(표 | 열)"
q "select table_schema||'.'||table_name, string_agg(column_name, ',' order by column_name) from information_schema.columns where table_schema !~ '^pg_' and table_schema <> 'information_schema' and column_name ~* '(email|mail|password|passwd|phone|tel|name|ip_|_ip$|address|token|contact|content|message|memo|body|comment|note|file|path|birth|user)' group by 1 order by 1"
