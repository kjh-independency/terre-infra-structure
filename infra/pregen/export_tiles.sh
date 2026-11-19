#!/usr/bin/env bash
# 미리 만든 행정구역 타일을 S3 에 올릴 묶음으로 만든다(실험실 볼륨을 읽기만 함, 서버 밖으로는 보내지 않음).
# 결과: results/<stamp>-s3-tiles/admin-tiles.tar, result.md → cmd 가 PC 의 lab-results 로 받아 간다.
set -euo pipefail
LAB=/home/ubuntu/terre-lab
RES=$LAB/results
out="$RES/$(TZ=Asia/Seoul date '+%m%d-%H%M')-s3-tiles"
docker volume inspect terre-lab_pregen >/dev/null 2>&1 || { echo "중단: 미리 만든 타일 볼륨이 없습니다(4-lab-apply → 1 먼저)"; exit 1; }
mkdir -p "$out"
echo "[$(TZ=Asia/Seoul date '+%m-%d %H:%M:%S')] 행정구역 타일을 묶습니다(시군구·읍면동, 1분 안쪽)"
docker run --rm --network none --cpus 0.5 --user "$(id -u):$(id -g)" \
  -v terre-lab_pregen:/src:ro -v "$LAB/pregen/export_tiles.py:/app/export_tiles.py:ro" -v "$out:/out" \
  python:3.12-alpine python /app/export_tiles.py /src /out
echo "[$(TZ=Asia/Seoul date '+%m-%d %H:%M:%S')] 완료: $out"
