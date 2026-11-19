#!/usr/bin/env python3
"""미리 만든 행정구역 타일(시군구·읍면동)을 S3 에 올릴 묶음으로 만든다.

- 입력: pregen 볼륨(읽기 전용)의 /src/sgg, /src/emd  (tilegen 이 만든 z/x/y.mvt)
- 출력: /out/admin-tiles.tar  — 안의 경로가 그대로 S3 키가 된다: api/v1/tiles/<layer>/<z>/<x>/<y>.mvt
        각 파일은 gzip 으로 압축해 둔다(S3 에 Content-Encoding: gzip 으로 올림)
        /out/result.md       — 장수·크기 요약과 CloudShell 에서 쓸 명령
보호지역은 넣지 않는다(공개 여부가 바뀌므로 서버 nginx 파일 제공 + 변경 감지로 둔다).
사용: export_tiles.py <src> <out>
"""
import gzip
import io
import os
import sys
import tarfile
import time

SRC, OUT = sys.argv[1], sys.argv[2]
LAYERS = ("sgg", "emd")


def main():
    stats = {}
    tar_path = os.path.join(OUT, "admin-tiles.tar")
    with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tar:
        for layer in LAYERS:
            base = os.path.join(SRC, layer)
            if not os.path.isdir(base):
                raise SystemExit(f"중단: {base} 가 없습니다. 개선 1(타일 미리 생성)이 적용돼 있어야 합니다")
            n = empty = raw = packed = 0
            for root, _dirs, files in os.walk(base):
                for name in sorted(files):
                    if not name.endswith(".mvt"):
                        continue
                    path = os.path.join(root, name)
                    rel = os.path.relpath(path, base).replace(os.sep, "/")
                    with open(path, "rb") as fh:
                        body = fh.read()
                    gz = gzip.compress(body, compresslevel=9, mtime=0)
                    info = tarfile.TarInfo(f"api/v1/tiles/{layer}/{rel}")
                    info.size = len(gz)
                    info.mtime = int(time.time())
                    info.mode = 0o644
                    tar.addfile(info, io.BytesIO(gz))
                    n += 1
                    empty += (len(body) == 0)
                    raw += len(body)
                    packed += len(gz)
            if n == 0:
                raise SystemExit(f"중단: {layer} 타일이 0장입니다")
            stats[layer] = (n, empty, raw, packed)

    mb = lambda b: f"{b / 1024 / 1024:.1f}MB"  # noqa: E731
    total = sum(v[0] for v in stats.values())
    lines = ["# 행정구역 타일 S3 묶음", "",
             f"- 만든 시각(한국): {time.strftime('%Y-%m-%d %H:%M', time.gmtime(time.time() + 9 * 3600))}",
             f"- 묶음 파일: admin-tiles.tar ({mb(os.path.getsize(tar_path))}), 타일 {total:,}장",
             "- 안의 경로가 그대로 S3 키(api/v1/tiles/<layer>/z/x/y.mvt). 파일마다 gzip 압축", "",
             "| 레이어 | 타일 | 빈 타일 | 원본 크기 | 압축 후 |", "|---|---|---|---|---|"]
    for layer, (n, empty, raw, packed) in stats.items():
        lines.append(f"| {layer} | {n:,} | {empty:,} | {mb(raw)} | {mb(packed)} |")
    lines += ["", "## CloudShell 에서 S3 로 올리는 명령 (BUCKET 은 실제 버킷 이름으로)", "", "```",
              "mkdir -p ~/tiles && tar -xf ~/admin-tiles.tar -C ~/tiles",
              "aws s3 cp ~/tiles/ s3://BUCKET/ --recursive \\",
              "  --content-type application/vnd.mapbox-vector-tile \\",
              "  --content-encoding gzip \\",
              "  --cache-control 'public, max-age=86400' --only-show-errors",
              "aws s3 ls s3://BUCKET/api/v1/tiles/ --recursive --summarize | tail -n 2",
              "```", ""]
    with open(os.path.join(OUT, "result.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
