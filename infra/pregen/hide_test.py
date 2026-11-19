#!/usr/bin/env python3
"""T6 보호지역 즉시 숨김 시험 (terre-lab 전용, 실험실 DB만 바꾼다)

보호지역 종류 하나를 실험실 DB에서 비공개로 바꾼 뒤, 같은 타일 주소(옛 주소)를 0.2초마다 다시 받아
그 종류가 타일에서 사라지기까지 걸린 시간을 잰다. 다시 공개로 되돌린 뒤 나타나기까지도 잰다.
타일(MVT)을 풀어 그 종류 코드가 값으로 들어 있는지로 판단한다.

- 기준(11/6 구성): backend 가 요청마다 현재 상태로 그리므로 바로 사라져야 한다.
- 개선 1(미리 생성): tilegen 이 변경을 감지해 current 를 비우는 순간 사라지고, 다시 만든 뒤 파일 제공으로 돌아온다.
끝나면(오류가 나도) 공개 상태를 처음대로 돌리고, 보호지역 표시 준비 표를 다시 맞춘다.

사용: hide_test.py <결과폴더> [실험실주소]
"""
import csv
import json
import math
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

OUT = sys.argv[1]
LAB_URL = (sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:18088").rstrip("/")
DB = "terre-lab-db-1"
WEB = "terre-lab-web-1"
ZOOM = 10
INTERVAL = 0.2
PREGEN_WAIT = 3600  # 다시 만들기를 기다리는 최대 시간(초)
BASE_WAIT = 60


def psql(sql):
    """실험실 DB 컨테이너 안의 psql 로 실행한다. SQL 은 표준 입력으로 넘겨 따옴표 문제를 피한다."""
    res = subprocess.run(
        ["docker", "exec", "-i", DB, "sh", "-c",
         'psql -U "$POSTGRES_USER" -d terre -At -F"|" -v ON_ERROR_STOP=1 -q'],
        input=sql, capture_output=True, text=True, timeout=300)
    if res.returncode != 0:
        raise RuntimeError("psql 실패: " + res.stderr.strip().splitlines()[-1] if res.stderr.strip() else "psql 실패")
    return [line.split("|") for line in res.stdout.strip().splitlines() if line]


def tile_of(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    r = math.radians(lat)
    y = int((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n)
    return x, y


def fetch(path):
    req = urllib.request.Request(LAB_URL + path, headers={"Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            return res.status, res.headers.get("X-Tile-Source") or "backend", res.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("X-Tile-Source") or "backend", b""
    except (urllib.error.URLError, OSError):
        return 0, "error", b""


def _varint(b, i):
    shift = result = 0
    while True:
        byte = b[i]
        i += 1
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result, i
        shift += 7


def _fields(b):
    i = 0
    while i < len(b):
        key, i = _varint(b, i)
        num, wire = key >> 3, key & 7
        if wire == 0:
            val, i = _varint(b, i)
        elif wire == 1:
            val, i = b[i:i + 8], i + 8
        elif wire == 2:
            ln, i = _varint(b, i)
            val, i = b[i:i + ln], i + ln
        elif wire == 5:
            val, i = b[i:i + 4], i + 4
        else:
            raise ValueError("MVT 해석 실패")
        yield num, wire, val


def string_values(tile):
    """MVT 레이어의 값 표에 든 문자열을 모은다. 종류 코드가 정확히 있는지로 판단해야
    'NATIONAL_PARK' 와 'NATIONAL_PARK_3KM' 처럼 이름이 겹치는 종류를 헷갈리지 않는다."""
    out = set()
    try:
        for num, wire, layer in _fields(tile):
            if num == 3 and wire == 2:
                for lnum, lwire, value in _fields(layer):
                    if lnum == 4 and lwire == 2:
                        for vnum, vwire, v in _fields(value):
                            if vnum == 1 and vwire == 2:
                                out.add(v.decode("utf-8", "replace"))
    except (ValueError, IndexError):
        pass
    return out


def variant():
    try:
        with open("/home/ubuntu/terre-lab/variant", encoding="utf-8") as fh:
            return fh.read().strip() or "base"
    except OSError:
        return "base"


def display_state():
    rows = psql("SELECT generation, built_generation FROM protected_area_display_state WHERE singleton;")
    return {"generation": rows[0][0], "built_generation": rows[0][1]} if rows else {}


def pick_target():
    """공개 종류 중 큰 도형부터 보며, 그 종류 이름이 실제로 들어 있는 줌 10 타일을 고른다."""
    rows = psql("""
        SELECT k.code, k.name, ST_X(t.pt), ST_Y(t.pt)
        FROM (SELECT p.kind, ST_PointOnSurface(p.geom) pt, ST_Area(p.geom) a,
                     row_number() OVER (PARTITION BY p.kind ORDER BY ST_Area(p.geom) DESC) rn
              FROM active_protected_area p) t
        JOIN protected_kind k ON k.code = t.kind AND k.is_public
        WHERE t.rn <= 3 ORDER BY t.a DESC LIMIT 30;
    """)
    for code, name, lon, lat in rows:
        x, y = tile_of(float(lon), float(lat), ZOOM)
        path = f"/api/v1/tiles/protected/{ZOOM}/{x}/{y}.mvt"
        status, source, body = fetch(path)
        if status == 200 and code in string_values(body):
            return {"code": code, "name": name, "path": path, "source_before": source}
    raise RuntimeError("시험할 보호지역 타일을 찾지 못했습니다")


def set_public(code, value):
    psql(f"UPDATE protected_kind SET is_public = {'true' if value else 'false'} WHERE code = '{code.replace(chr(39), '')}';")
    return time.monotonic()


def watch(path, code, want_present, t0, phase, rows, pregen):
    """want_present 상태가 될 때까지(개선 1이면 파일 제공으로 돌아올 때까지) 0.2초마다 받는다."""
    first_change = None
    first_pregen_ok = None
    stale = 0
    limit = PREGEN_WAIT if pregen else BASE_WAIT
    while True:
        status, source, body = fetch(path)
        t = time.monotonic() - t0
        present = code in string_values(body)
        ok = present == want_present and status == 200
        rows.append([phase, f"{t:.2f}", status, source, int(present)])
        if not ok:
            stale += 1
        if ok and first_change is None:
            first_change = t
        if ok and source == "pregen" and first_pregen_ok is None:
            first_pregen_ok = t
        done = first_change is not None and (first_pregen_ok is not None if pregen else t - first_change > 5)
        if done or t > limit or os.path.exists(os.path.join(OUT, "ABORTED")):
            break
        time.sleep(INTERVAL)
    return {"change_seconds": first_change, "pregen_back_seconds": first_pregen_ok, "wrong_responses": stale,
            "timed_out": not done}


def refresh_display():
    for _ in range(10):
        rows = psql("SELECT refresh_protected_area_display();")
        if rows and rows[0][0] == "t":
            return True
        time.sleep(2)
    return False


def toggle(code, value):
    """공개 여부를 바꾸고, 운영의 적재 흐름처럼 보호지역 표시 준비 표 갱신을 뒤에서 돌린다.
    갱신이 끝나기 전에도 backend 는 종류 공개 여부를 바로 반영하므로, 시간 측정은 UPDATE 시점부터 한다."""
    t = set_public(code, value)
    holder = {}

    def run():
        started = time.monotonic()
        holder["ok"] = refresh_display()
        holder["seconds"] = round(time.monotonic() - started, 1)

    th = threading.Thread(target=run, daemon=True)
    th.start()
    return t, th, holder


def tilegen_events():
    res = subprocess.run(["docker", "exec", WEB, "sh", "-c", "tail -n 40 /srv/pregen/events.log 2>/dev/null"],
                         capture_output=True, text=True, timeout=30)
    return res.stdout


def main():
    os.makedirs(OUT, exist_ok=True)
    pregen = variant() == "pregen"
    result = {"variant": "pregen" if pregen else "base", "zoom": ZOOM, "display_before": display_state()}
    target = pick_target()
    result["target"] = {"code": target["code"], "path": target["path"], "source_before": target["source_before"]}
    if pregen and target["source_before"] != "pregen":
        raise RuntimeError("개선 1이 적용됐지만 타일이 아직 파일로 나오지 않습니다(tilegen 준비 전). 3-lab-status 로 확인하세요")
    code = target["code"]
    rows = []
    restored = False
    try:
        t0, th, ref = toggle(code, False)
        result["hide"] = watch(target["path"], code, False, t0, "hide", rows, pregen)
        th.join(timeout=600)
        result["hide"]["display_refresh"] = ref
        t1, th, ref = toggle(code, True)
        restored = True
        result["show"] = watch(target["path"], code, True, t1, "show", rows, pregen)
        th.join(timeout=600)
        result["show"]["display_refresh"] = ref
    finally:
        if not restored:
            set_public(target["code"], True)
        result["display_refreshed"] = refresh_display()
        result["display_after"] = display_state()
    with open(os.path.join(OUT, "hide-timeline.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["phase", "seconds", "status", "source", "kind_present"])
        w.writerows(rows)
    if pregen:
        with open(os.path.join(OUT, "tilegen-events.log"), "w", encoding="utf-8") as fh:
            fh.write(tilegen_events())
    with open(os.path.join(OUT, "hide.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=1)

    def s(v):
        return "-" if v is None else f"{v:.1f}초"

    h, w_ = result["hide"], result["show"]
    md = ["## 보호지역 즉시 숨김 (T6)", "",
          f"- 구성: {'개선 1(미리 생성)' if pregen else '기준(11/6 구성)'}, 시험 종류 코드 {target['code']}, 타일 {target['path']}",
          "- 방법: 실험실 DB에서 그 종류를 비공개로 바꾼 뒤 같은 주소를 0.2초마다 다시 받아 그 종류가 타일에서 사라지는 시점을 잰다", "",
          "| 항목 | 비공개로 바꿀 때 | 다시 공개할 때 |", "|---|---|---|",
          f"| **옛 주소에서 바뀌기까지** | **{s(h['change_seconds'])}** | {s(w_['change_seconds'])} |",
          f"| 그사이 옛 내용이 나간 응답 | {h['wrong_responses']}건 | {w_['wrong_responses']}건 |"]
    if pregen:
        md.append(f"| 다시 만든 파일로 돌아오기까지 | {s(h['pregen_back_seconds'])} | {s(w_['pregen_back_seconds'])} |")
    md += ["", f"- 끝난 뒤 공개 상태를 되돌렸고, 표시 준비 표 다시 맞춤: {'완료' if result['display_refreshed'] else '실패(확인 필요)'}", ""]
    with open(os.path.join(OUT, "hide.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")
    print("\n".join(md))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        msg = f"T6 시험 오류: {e}"
        print(msg)
        with open(os.path.join(OUT, "ABORTED"), "a", encoding="utf-8") as fh:
            fh.write(msg + "\n")
        sys.exit(1)
