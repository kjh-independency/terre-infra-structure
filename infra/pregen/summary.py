#!/usr/bin/env python3
"""tilegen 의 state.json(표준 입력)을 사람이 읽는 요약으로 바꾼다."""
import json
import sys

s = json.load(sys.stdin)
names = {"protected": "보호지역", "sgg": "시군구", "emd": "읍면동"}
for key in ("protected", "sgg", "emd"):
    v = s.get(key) or {}
    if v.get("tiles") is None:
        print(f"- {names[key]}: 아직 없음")
        continue
    mb = (v.get("bytes") or 0) / 1048576
    print(f"- {names[key]}: 타일 {v.get('tiles')}장(빈 타일 {v.get('empty')}), {mb:.1f}MB, "
          f"{v.get('seconds')}초, 오류 {v.get('errors')}건, 만든 시각 {v.get('built_at')}")
print("- 준비 완료: " + (s.get("ready_at") or "아직"))
