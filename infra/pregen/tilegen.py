#!/usr/bin/env python3
"""terre-lab 개선 1: 경계 벡터 타일 미리 생성기 (표준 라이브러리만 사용)

backend 가 요청마다 PostGIS 로 만들던 타일을, backend 에게 한 번씩 받아 파일로 저장해 둔다.
같은 backend 응답을 그대로 저장하므로 화면에 그려지는 결과가 같다. nginx 는 파일이 있으면 파일을,
없으면 지금처럼 backend 로 넘긴다(nginx-pregen.conf).

- 행정구역(sgg·emd): 거의 바뀌지 않는다. 한 번 만들어 두고, 자료를 다시 적재할 때만 다시 만든다.
- 보호지역(protected): 공개 여부가 바뀌면 옛 주소로도 즉시 사라져야 한다(팀 요구).
  레이어 목록(/api/v1/layers) 응답의 지문을 POLL 초마다 확인하고, 바뀌면
  ① current 를 빈 폴더로 바꿔 그 순간부터 backend 가 현재 상태로 그리게 하고
  ② 새 세대 폴더를 처음부터 다시 만든 뒤 ③ 만드는 동안 또 바뀌지 않았으면 current 를 새 폴더로 바꾼다.

명령: watch(기본) | build <sgg|emd|protected> | status
"""
import concurrent.futures as cf
import hashlib
import json
import math
import os
import shutil
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

BACKEND = os.environ.get("BACKEND", "http://backend:8080").rstrip("/")
OUT = os.environ.get("OUT", "/srv/pregen")
ZMIN = int(os.environ.get("ZMIN", "5"))
ZMAX = int(os.environ.get("ZMAX", "12"))
BBOX = tuple(float(v) for v in os.environ.get("BBOX", "124.0,33.0,132.0,39.0").split(","))
WORKERS = int(os.environ.get("WORKERS", "2"))
POLL = float(os.environ.get("POLL", "5"))
TIMEOUT = float(os.environ.get("TIMEOUT", "60"))
STATIC_LAYERS = ("sgg", "emd")
LAYER_MIN_ZOOM = {"sgg": 0, "emd": 9, "protected": 0}  # backend TileLayer 의 minZoom 과 같다
KST = timezone(timedelta(hours=9))
_lock = threading.Lock()


def now():
    return datetime.now(KST).strftime("%Y-%m-%d %H:%M:%S")


def log(event, **fields):
    line = f"{now()} {event}" + "".join(f" {k}={v}" for k, v in fields.items())
    print(line, flush=True)
    os.makedirs(OUT, exist_ok=True)
    with _lock, open(os.path.join(OUT, "events.log"), "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def load_state():
    try:
        with open(os.path.join(OUT, "state.json"), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    tmp = os.path.join(OUT, ".state.json.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, os.path.join(OUT, "state.json"))


def tile_of(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    r = math.radians(lat)
    y = int((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n)
    return x, y


def tiles_for(layer):
    """BBOX(한국 주변) 안의 ZMIN~ZMAX 타일. backend 가 빈 타일만 주는 줌은 건너뛴다."""
    lon0, lat0, lon1, lat1 = BBOX
    for z in range(max(ZMIN, LAYER_MIN_ZOOM[layer]), ZMAX + 1):
        x0, y0 = tile_of(lon0, lat1, z)
        x1, y1 = tile_of(lon1, lat0, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                yield z, x, y


def config_key(layer):
    return f"{layer}:z{ZMIN}-{ZMAX}:bbox{','.join(str(v) for v in BBOX)}"


def http_get(path, retries=2):
    last = None
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(BACKEND + path, timeout=TIMEOUT) as res:
                return res.status, res.read()
        except urllib.error.HTTPError as e:
            return e.code, b""
        except (urllib.error.URLError, OSError) as e:  # 연결 실패·시간 초과는 잠깐 쉬고 다시
            last = e
            time.sleep(1 + attempt)
    raise RuntimeError(f"backend 응답 없음: {path} ({last})")


def fingerprint():
    """보호지역 타일 내용을 바꾸는 것(공개 종류·종류 이름·도형 개정)은 모두 레이어 목록 응답에 드러난다."""
    status, body = http_get("/api/v1/layers")
    if status != 200:
        raise RuntimeError(f"레이어 목록 응답 {status}")
    return hashlib.sha256(body).hexdigest()[:16]


def build(layer, dest, stop=None):
    """dest 폴더에 layer 타일을 모두 저장한다. stop() 이 참이 되면 중단하고 None."""
    os.makedirs(dest, exist_ok=True)
    jobs = list(tiles_for(layer))
    started = time.monotonic()
    stats = {"tiles": 0, "empty": 0, "bytes": 0, "errors": 0}

    def one(t):
        z, x, y = t
        status, body = http_get(f"/api/v1/tiles/{layer}/{z}/{x}/{y}.mvt")
        if status != 200:
            return t, None
        path = os.path.join(dest, str(z), str(x))
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, f"{y}.mvt"), "wb") as fh:
            fh.write(body)  # 빈 타일도 backend 처럼 200·빈 본문으로 주려고 0바이트 파일로 둔다
        return t, len(body)

    last_report = time.monotonic()
    with cf.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        pending = set()
        it = iter(jobs)
        done_all = False
        while True:
            while not done_all and len(pending) < WORKERS * 4:
                try:
                    pending.add(pool.submit(one, next(it)))
                except StopIteration:
                    done_all = True
            if not pending:
                break
            finished, pending = cf.wait(pending, return_when=cf.FIRST_COMPLETED)
            for f in finished:
                try:
                    _, size = f.result()
                except Exception:  # noqa: BLE001 — 실패한 칸은 파일을 두지 않는다(nginx 가 backend 로 넘김)
                    size = None
                if size is None:
                    stats["errors"] += 1
                else:
                    stats["tiles"] += 1
                    stats["bytes"] += size
                    stats["empty"] += size == 0
            if stop is not None and stop():
                for p in pending:
                    p.cancel()
                return None
            if time.monotonic() - last_report > 30:
                last_report = time.monotonic()
                log("progress", layer=layer, done=stats["tiles"] + stats["errors"], total=len(jobs))
    stats["seconds"] = round(time.monotonic() - started, 1)
    stats["total"] = len(jobs)
    return stats


def publish_static(layer, stats):
    """다 만든 폴더를 한 번에 바꿔 끼운다. 바꾸는 순간 잠깐 비어도 nginx 가 backend 로 넘겨 그대로 동작한다."""
    final = os.path.join(OUT, layer)
    old = os.path.join(OUT, f".{layer}.old")
    shutil.rmtree(old, ignore_errors=True)
    if os.path.exists(final):
        os.rename(final, old)
    os.rename(os.path.join(OUT, f".{layer}.tmp"), final)
    shutil.rmtree(old, ignore_errors=True)
    state = load_state()
    state[layer] = dict(stats, key=config_key(layer), built_at=now())
    save_state(state)
    log("published", layer=layer, tiles=stats["tiles"], errors=stats["errors"], seconds=stats["seconds"])


def build_static(layer, force=False):
    state = load_state().get(layer, {})
    if not force and state.get("key") == config_key(layer) and os.path.isdir(os.path.join(OUT, layer)):
        log("skip", layer=layer, reason="already-built", built_at=state.get("built_at"))
        return
    tmp = os.path.join(OUT, f".{layer}.tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    log("build-start", layer=layer, total=sum(1 for _ in tiles_for(layer)))
    stats = build(layer, tmp)
    publish_static(layer, stats)


def point_current(target):
    """protected/current 를 target(상대 경로)으로 바꾼다. 같은 폴더 안 rename 이라 한 번에 바뀐다."""
    base = os.path.join(OUT, "protected")
    os.makedirs(os.path.join(base, "empty"), exist_ok=True)
    tmp = os.path.join(base, ".current.tmp")
    if os.path.lexists(tmp):
        os.remove(tmp)
    os.symlink(target, tmp)
    os.replace(tmp, os.path.join(base, "current"))


def cleanup_generations(keep):
    base = os.path.join(OUT, "protected")
    for name in os.listdir(base):
        if name.startswith("gen-") and name != keep:
            shutil.rmtree(os.path.join(base, name), ignore_errors=True)


def build_protected(fp):
    """현재 지문 fp 기준으로 새 세대를 만들고, 그동안 지문이 그대로면 공개한다. 바뀌었으면 False."""
    gen = "gen-" + datetime.now(KST).strftime("%Y%m%dT%H%M%S")
    dest = os.path.join(OUT, "protected", gen)
    changed = {"value": False}
    last_check = {"t": time.monotonic()}

    def stop():
        # 만드는 동안에도 POLL 초마다 지문을 본다. 또 바뀌면 이 세대는 버린다.
        if time.monotonic() - last_check["t"] < POLL:
            return False
        last_check["t"] = time.monotonic()
        try:
            changed["value"] = fingerprint() != fp
        except RuntimeError:
            return False
        return changed["value"]

    log("build-start", layer="protected", gen=gen, fingerprint=fp, total=sum(1 for _ in tiles_for("protected")))
    stats = build("protected", dest, stop)
    if stats is None or fingerprint() != fp:
        shutil.rmtree(dest, ignore_errors=True)
        log("build-discarded", layer="protected", gen=gen, reason="layers-changed-during-build")
        return False
    point_current(gen)
    cleanup_generations(keep=gen)
    state = load_state()
    state["protected"] = dict(stats, key=config_key("protected"), built_at=now(), gen=gen, fingerprint=fp)
    save_state(state)
    log("published", layer="protected", gen=gen, tiles=stats["tiles"], errors=stats["errors"], seconds=stats["seconds"])
    return True


def hide_protected(reason):
    point_current("empty")
    state = load_state()
    state.setdefault("protected", {})["hidden_at"] = now()
    state["protected"]["fingerprint"] = None
    save_state(state)
    log("hidden", layer="protected", reason=reason)


def watch():
    os.makedirs(os.path.join(OUT, "protected", "empty"), exist_ok=True)
    while True:
        try:
            fingerprint()
            break
        except RuntimeError as e:
            log("waiting-backend", detail=str(e).replace(" ", "_"))
            time.sleep(5)
    published = load_state().get("protected", {}).get("fingerprint")
    current_ok = os.path.islink(os.path.join(OUT, "protected", "current"))
    fp = fingerprint()
    if published != fp or not current_ok:
        hide_protected("start" if not current_ok else "changed-while-stopped")
        published = None
    # 보호지역을 먼저 만든다(요청 비중이 크고 즉시 숨김 대상). 행정구역은 그다음.
    while published is None:
        fp = fingerprint()
        if build_protected(fp):
            published = fp
    for layer in STATIC_LAYERS:
        build_static(layer)
    log("ready", layers="sgg,emd,protected")
    state = load_state()
    state["ready_at"] = now()
    save_state(state)
    while True:
        time.sleep(POLL)
        try:
            fp = fingerprint()
        except RuntimeError as e:
            log("poll-failed", detail=str(e).replace(" ", "_"))
            continue
        if fp == published:
            continue
        hide_protected("layers-changed")  # 바로 숨긴다: 이 순간부터 backend 가 현재 공개 상태로 그린다
        published = None
        while published is None:
            fp = fingerprint()
            if build_protected(fp):
                published = fp


def status():
    state = load_state()
    cur = os.path.join(OUT, "protected", "current")
    state["protected_current"] = os.readlink(cur) if os.path.islink(cur) else None
    print(json.dumps(state, ensure_ascii=False, indent=1))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "watch"
    if cmd == "watch":
        watch()
    elif cmd == "build" and len(argv) > 2 and argv[2] in STATIC_LAYERS:
        build_static(argv[2], force=True)
    elif cmd == "build" and len(argv) > 2 and argv[2] == "protected":
        hide_protected("manual-build")
        while not build_protected(fingerprint()):
            pass
    elif cmd == "status":
        status()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
