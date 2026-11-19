#!/usr/bin/env python3
"""T3-CDN 보조 측정: 배포(web·backend 재시작) 동안 같은 행정구역 타일을
실험실(서버 nginx)과 CloudFront(S3) 두 경로로 0.5초마다 받아 끊김을 비교한다.
사용: tile_probe.py <결과폴더> <실험실주소> <CloudFront주소>   ($OUT/.probe_stop 이 생기면 끝)
"""
import csv, os, sys, threading, time, urllib.error, urllib.request

OUT, LAB, CDN = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3].rstrip("/")
TILE = "/api/v1/tiles/sgg/12/3506/1583.mvt"
STOP = os.path.join(OUT, ".probe_stop")
rows, lock = [], threading.Lock()


def get(url):
    t = time.time()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept-Encoding": "gzip"}), timeout=3) as r:
            r.read(); code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception:  # noqa: BLE001  접속 거부·시간 초과
        code = 0
    return code, time.time() - t


def loop(name, base):
    end = time.time() + 600
    while not os.path.exists(STOP) and time.time() < end:
        t0 = time.time()
        code, dt = get(base + TILE)
        with lock:
            rows.append([f"{t0:.2f}", name, code, f"{dt:.3f}"])
        time.sleep(max(0, 0.5 - (time.time() - t0)))


ths = [threading.Thread(target=loop, args=a) for a in (("server", LAB), ("cloudfront", CDN))]
[t.start() for t in ths]
[t.join() for t in ths]
rows.sort()
with open(os.path.join(OUT, "tile-probe.csv"), "w", newline="") as fh:
    w = csv.writer(fh); w.writerow(["epoch", "target", "status", "seconds"]); w.writerows(rows)


def summary(name):
    rs = [r for r in rows if r[1] == name]
    bad = [r for r in rs if r[2] != 200]
    longest = cur = 0.0; start = None
    for r in rs:
        if r[2] != 200:
            start = start or float(r[0]); cur = float(r[0]) - start + 0.5
            longest = max(longest, cur)
        else:
            start = None
    return len(rs), len(bad), longest


md = ["## 배포 중 행정구역 타일 (서버 nginx vs CloudFront)", "",
      f"- 같은 타일({TILE})을 0.5초마다 두 경로로 받음. 배포는 backend·screening·web 을 그 자리에서 새로 만듦(T3 와 같음)", "",
      "| 경로 | 요청 | 200이 아닌 응답 | 가장 길게 끊긴 시간 |", "|---|---|---|---|"]
for name, label in (("server", "서버 nginx(실험실)"), ("cloudfront", "CloudFront(S3)")):
    n, b, l = summary(name)
    md.append(f"| {label} | {n} | {b} | {l:.1f}초 |")
with open(os.path.join(OUT, "tile-probe.md"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(md) + "\n")
print("\n".join(md))
