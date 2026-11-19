#!/usr/bin/env python3
"""terre-lab 결과 폴더를 읽어 result.md(사람이 읽는 표)와 result.json(기록용)을 만든다.
사용: summarize.py <결과 폴더>
      summarize.py --err <k6 summary json>   (에러율만 출력, lab.sh 가 단계 사이에 쓴다)
"""
import csv
import gzip
import json
import os
import re
import sys
from datetime import datetime

TARGET_P95_MS = 1000      # 목표치: 동시 50명에서 p95 1초 이하
TARGET_ERR = 0.01         # 목표치: 에러율 1% 미만


def load_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def k6_metrics(path):
    return (load_json(path) or {}).get('metrics', {})


def err_rate(m):
    v = m.get('http_req_failed') or {}
    r = v.get('value', v.get('rate'))
    return float(r) if r is not None else None


if len(sys.argv) == 3 and sys.argv[1] == '--err':
    r = err_rate(k6_metrics(sys.argv[2]))
    print(1 if r is None else round(r, 4))
    sys.exit(0)

OUT = sys.argv[1]


def path(name):
    return os.path.join(OUT, name)


def kv(name):
    d = {}
    if os.path.exists(path(name)):
        for line in open(path(name), encoding='utf-8'):
            if '=' in line:
                k, v = line.rstrip('\n').split('=', 1)
                d[k] = v
    return d


def rows(name):
    if not os.path.exists(path(name)):
        return []
    with open(path(name), encoding='utf-8') as f:
        return list(csv.reader(f))


def num(x):
    try:
        return float(str(x).rstrip('%'))
    except Exception:
        return None


STATS = []
for r in rows('stats.csv')[1:]:
    if len(r) >= 3 and num(r[0]) is not None and num(r[2]) is not None:
        STATS.append((int(float(r[0])), r[1], num(r[2])))


def peak(name, t0=None, t1=None):
    vals = [c for e, n, c in STATS if n == name and (t0 is None or t0 <= e <= t1)]
    return max(vals) if vals else None


def db_active_peak(t0=None, t1=None):
    best = None
    for r in rows('dbconn.csv')[1:]:
        if len(r) >= 3 and num(r[0]) is not None and num(r[1]) is not None:
            e = int(float(r[0]))
            if t0 is None or t0 <= e <= t1:
                best = int(num(r[1])) if best is None else max(best, int(num(r[1])))
    return best


def prod_summary():
    secs, bad = [], 0
    for r in rows('prod.csv')[1:]:
        if len(r) >= 3 and num(r[2]) is not None:
            secs.append(num(r[2]))
            bad += r[1] != '200'
    return {'checks': len(secs), 'max_seconds': max(secs) if secs else None, 'non_200': bad}


def f(x, unit='', nd=0):
    if x is None:
        return '-'
    return f'{x:.{nd}f}{unit}'


def pct(x):
    return '-' if x is None else f'{x * 100:.2f}%'


def cpu_txt(v):
    m = re.match(r'^(\d+(?:\.\d+)?)s$', v or '')
    return f'{m.group(1)}개' if m else (v or '-')


def mem_txt(v):
    n = num(v)
    return f'{n / 1073741824:.0f}GB' if n else (v or '-')


meta, met = kv('meta.txt'), kv('metrics.txt')
test = meta.get('test', os.path.basename(OUT))
md = [f'# {test}', '', f'- 측정 시각(한국): {meta.get("kst", "-")}',
      f'- 조건: 실험실 CPU 상한 {cpu_txt(meta.get("slice_cpu"))}, 메모리 상한 {mem_txt(meta.get("slice_mem_max"))}, '
      f'시작 때 서버 부하 {meta.get("load_avg", "-")}, 팀 CI 작동 {meta.get("ci_busy", "-")}',
      f'- 앱 이미지: {meta.get("image_backend", "-")}', '']
result = {'test': test, 'meta': meta}

# ---- T4: 백업 복원 ----
if 'restore_seconds' in met:
    result['restore'] = met
    age = num(met.get('backup_age_minutes'))
    md += ['## 백업 복원 (T4)', '',
           '| 항목 | 값 |', '|---|---|',
           f'| 백업 파일 | {met.get("backup_file", "-")} ({met.get("backup_size_mb", "-")}MB, 만든 지 {f(age / 60 if age is not None else None, "시간", 1)}) |',
           f'| DB 복원 | {met.get("restore_seconds", "-")}초 |',
           f'| 통계 갱신(ANALYZE) | {met.get("analyze_seconds", "-")}초 |',
           f'| 앱 시작~응답 | {met.get("app_start_seconds", "-")}초 |',
           f'| **RTO(복원 시작~서비스 응답)** | **{met.get("rto_seconds", "-")}초** |',
           f'| RPO | 백업이 하루 1번(04:00)이라 최악의 경우 직전 백업 뒤 최대 24시간치 데이터를 잃음 |',
           f'| 검증 | 보호종 {met.get("verify_species", "-")}건, 보호지역 {met.get("verify_protected_area", "-")}건, 스키마 {met.get("verify_flyway", "-")} |',
           f'| 복원 중 오류 종류 | {met.get("restore_error_kinds", "-")}가지 (restore-errors.txt) |', '']

# ---- T1·T2: 단계별 부하 ----
steps = rows('steps.csv')
if len(steps) > 1:
    table = []
    for r in steps[1:]:
        n, s, e = int(r[0]), int(r[1]), int(r[2])
        m = k6_metrics(path(f'step-{n}.json'))
        d = m.get('http_req_duration') or {}
        named = {k[len('http_req_duration{name:'):-1]: (v or {}).get('p(95)')
                 for k, v in m.items() if k.startswith('http_req_duration{name:')}
        table.append({
            'users': n, 'rps': (m.get('http_reqs') or {}).get('rate'), 'p50': d.get('p(50)'), 'p95': d.get('p(95)'),
            'p99': d.get('p(99)'), 'err': err_rate(m), 'named_p95': named,
            'lab_db_cpu': peak('terre-lab-db-1', s, e), 'lab_backend_cpu': peak('terre-lab-backend-1', s, e),
            'lab_web_cpu': peak('terre-lab-web-1', s, e), 'k6_cpu': peak('terre-lab-k6', s, e),
            'db_active_conn': db_active_peak(s, e),
            'prod_db_cpu': peak('terre-service-db-1', s, e), 'prod_backend_cpu': peak('terre-service-backend-1', s, e)})
    result['steps'] = table
    ok = [t['users'] for t in table if t['err'] is not None and t['p95'] is not None
          and t['err'] < TARGET_ERR and t['p95'] < TARGET_P95_MS]
    result['max_users_meeting_target'] = max(ok) if ok else 0
    md += ['## 단계별 결과', '',
           '| 동시 사용자 | 초당 요청 | 응답 p50 | 응답 p95 | 응답 p99 | 에러율 | 실험실 DB CPU 최대 | backend CPU 최대 | DB 활성 연결 최대 | 운영 DB CPU 최대 |',
           '|---|---|---|---|---|---|---|---|---|---|']
    for t in table:
        md.append(f'| {t["users"]}명 | {f(t["rps"], "", 1)} | {f(t["p50"], "ms")} | {f(t["p95"], "ms")} | {f(t["p99"], "ms")} | '
                  f'{pct(t["err"])} | {f(t["lab_db_cpu"], "%")} | {f(t["lab_backend_cpu"], "%")} | {f(t["db_active_conn"])} | {f(t["prod_db_cpu"], "%")} |')
    names = sorted({k for t in table for k in t['named_p95']})
    if names:
        md += ['', '### 요청 종류별 p95(ms)', '', '| 동시 사용자 | ' + ' | '.join(names) + ' |', '|---|' + '---|' * len(names)]
        for t in table:
            md.append(f'| {t["users"]}명 | ' + ' | '.join(f(t['named_p95'].get(k)) for k in names) + ' |')
    md += ['', f'- **목표(p95 1초 이하, 에러율 1% 미만)를 지킨 최대 동시 사용자: {result["max_users_meeting_target"]}명**',
           '- CPU 값은 코어 1개를 100%로 본다(실험실 전체 상한은 200%).']
    hot = [t['users'] for t in table if t['k6_cpu'] is not None and t['k6_cpu'] >= 48]
    if hot:
        md.append(f'- 주의: {", ".join(map(str, hot))}명 단계에서 부하 도구 CPU가 상한(50%)에 닿았다. 그 단계 수치는 부하 도구 한계가 섞였을 수 있다.')
    md.append('')


# ---- T3·T5: 사건 전후 끊김 ----
def parse_time(s):
    m = re.match(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)', s)
    frac = (m.group(2) or '.0')[:7]
    tz = '+00:00' if m.group(3) == 'Z' else m.group(3)
    return datetime.fromisoformat(m.group(1) + frac + tz).timestamp()


if os.path.exists(path('probe.json.gz')):
    reqs, lat = [], []
    def probe_lines():
        # 시험이 중간에 멈추면(팀 CI 등) 압축 파일 끝이 잘린다: 읽은 데까지만 쓴다
        try:
            with gzip.open(path('probe.json.gz'), 'rt', encoding='utf-8') as fh:
                for line in fh:
                    yield line
        except (EOFError, OSError):
            return

    for line in probe_lines():
        if '"Point"' not in line:
            continue
        try:
            j = json.loads(line)
        except ValueError:
            continue
        d = j.get('data', {})
        if j.get('metric') == 'http_req_failed':
            reqs.append((parse_time(d['time']), int(d['value'])))
        elif j.get('metric') == 'http_req_duration':
            lat.append((parse_time(d['time']), float(d['value'])))
    reqs.sort()
    ev = {r[0]: float(r[1]) for r in rows('events.csv')[1:] if len(r) >= 2}
    fails = [t for t, v in reqs if v]
    total = len(reqs)
    t0 = ev.get('start')
    info = {'requests': total, 'failed': len(fails), 'event_seconds': (ev['end'] - ev['start']) if 'end' in ev and 'start' in ev else None}
    if fails:
        first, last = fails[0], fails[-1]
        recovered = next((t for t, v in reqs if not v and t > last), None)
        info.update({'first_fail_after_event_s': first - t0 if t0 else None,
                     'outage_s': (recovered - first) if recovered else None,
                     'recovered_after_event_s': (recovered - t0) if (recovered and t0) else None})
    slow = [ms for t, ms in lat if t0 and t >= t0 and ms > 1000]
    info['slow_over_1s_after_event'] = len(slow)
    info['max_latency_ms_after_event'] = max([ms for t, ms in lat if t0 and t >= t0], default=None)
    result['event'] = info
    md += ['## 사건 전후 (1초에 10번 요청)', '',
           '| 항목 | 값 |', '|---|---|',
           f'| 전체 요청 | {total}건 |',
           f'| **실패한 요청** | **{len(fails)}건 ({pct(len(fails) / total if total else None)})** |',
           f'| 사건 명령이 걸린 시간 | {f(info.get("event_seconds"), "초", 1)} |',
           f'| 사건 뒤 첫 실패까지 | {f(info.get("first_fail_after_event_s"), "초", 1)} |',
           f'| **끊긴 시간(첫 실패~다시 성공)** | **{f(info.get("outage_s"), "초", 1)}** |',
           f'| 사건 뒤 정상화까지 | {f(info.get("recovered_after_event_s"), "초", 1)} |',
           f'| 사건 뒤 1초 넘게 걸린 요청 | {info["slow_over_1s_after_event"]}건 (최대 {f(info["max_latency_ms_after_event"], "ms")}) |', '']

# ---- 운영 영향 ----
ps = prod_summary()
result['production'] = ps
if ps['checks']:
    md += ['## 운영 영향 (10초마다 운영 응답 확인)', '',
           f'- 확인 {ps["checks"]}번, 가장 느린 응답 {f(ps["max_seconds"] * 1000 if ps["max_seconds"] is not None else None, "ms")}, 200이 아닌 응답 {ps["non_200"]}번', '']
for extra in ('hide.md', 'tile-probe.md', 'variant.md'):  # 개선 1: T6 결과와 실험실 구성
    if os.path.exists(path(extra)):
        md += [open(path(extra), encoding='utf-8').read().rstrip(), '']
if os.path.exists(path('ABORTED')):
    md += ['## 중단', '', open(path('ABORTED'), encoding='utf-8').read().strip(), '']

with open(path('result.md'), 'w', encoding='utf-8') as fo:
    fo.write('\n'.join(md) + '\n')
with open(path('result.json'), 'w', encoding='utf-8') as fo:
    json.dump(result, fo, ensure_ascii=False, indent=1, default=str)
print('\n'.join(md))
