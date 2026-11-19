// terre-lab 용 복사본: 팀의 11/5 부하 시나리오(develop scripts/loadtest)를 그대로 쓰고,
// 실험실 계정이 운영 계정과 섞이지 않게 계정 이름 접두사(PREFIX)만 바꿀 수 있게 했다.
// 부하 테스트 공통 설정·도우미. a-tiles.js · b-flow.js 가 같이 쓴다.
import http from 'k6/http';

// 대상 주소. 기본은 배포 서버, 로컬 연습은 -e BASE=http://localhost:8088
export const BASE = (__ENV.BASE || 'http://127.0.0.1:18088').replace(/\/$/, '');
// [terre-lab AWS 단계] 행정구역(sgg·emd) 타일만 CloudFront(S3)에서 받는다. 비우면 원래대로 BASE
export const TILE_CDN = (__ENV.TILE_CDN || '').replace(/\/$/, '');

// 어떤 값을 넣어도 동시 사용자 200명을 넘기지 않는다(공용 교육망에서 공격으로 보일 수 있음)
const MAX_VUS = 200;

/**
 * 부하 단계. -e STEPS=50,100,200 처럼 바꾼다(기본 50,100,200).
 * 데우기 5명(WARMUP, 기본 2분. 0s 면 생략) → 단계마다 30초 올리고 HOLD(기본 3분) 유지 → 단계 사이 1분은 절반으로 낮춰 회복 확인 → 30초에 0명으로.
 * run.ps1 은 단계를 하나씩 따로 돌린다(-e STEPS=100 -e WARMUP=0s). 그래야 단계별 수치가 나오고, 무너진 단계 다음을 건너뛸 수 있다.
 */
export function stages() {
  const steps = (__ENV.STEPS || '50,100,200').split(',').map(Number).filter(n => n > 0)
    .map(n => Math.min(n, MAX_VUS));
  const hold = __ENV.HOLD || '3m';
  const warm = __ENV.WARMUP || '2m';
  const out = [];
  if (!/^0+(s|m)?$/.test(warm)) out.push({ duration: '30s', target: 5 }, { duration: warm, target: 5 });
  steps.forEach((n, i) => {
    out.push({ duration: '30s', target: n }, { duration: hold, target: n });
    if (i < steps.length - 1) out.push({ duration: '1m', target: Math.ceil(n / 2) });
  });
  out.push({ duration: '30s', target: 0 });
  return out;
}

/** 공통 판정. 에러율 10% 를 넘으면 30초 지켜본 뒤 테스트를 스스로 멈춘다(서버 보호). 나머지는 기록용 기준. */
export function thresholds(extra) {
  const out = Object.assign({
    http_req_failed: [
      { threshold: 'rate<0.10', abortOnFail: true, delayAbortEval: '30s' },
      'rate<0.01',
    ],
  }, extra);
  // 이름별 실패율도 summary 에 남기기(report.py 7절). 'rate<=1' 은 늘 통과하는 기준이라 판정에는 영향 없음
  for (const k of Object.keys(extra || {})) {
    const m = /^http_req_duration\{name:([^}]+)\}$/.exec(k);
    if (m) out[`http_req_failed{name:${m[1]}}`] = ['rate<=1'];
  }
  return out;
}

export const rand = (a, b) => a + Math.random() * (b - a);
export const pick = arr => arr[Math.floor(Math.random() * arr.length)];

// 지도를 여는 위치 후보(사람이 많이 보는 도시·국립공원 근처). 좌표는 [경도, 위도]
export const PLACES = [
  [126.978, 37.566], [129.075, 35.180], [127.385, 36.351], [126.853, 35.160], [128.601, 35.871],
  [126.705, 37.456], [127.009, 37.264], [128.591, 37.751], [126.531, 33.499], [127.731, 37.881],
  [126.522, 33.362], [127.731, 35.337], [128.477, 38.119], [127.480, 36.636], [127.147, 35.824],
];

/** 경도·위도·줌 → 타일 번호 */
export function tileOf(lng, lat, z) {
  const n = 2 ** z;
  const x = Math.floor(((lng + 180) / 360) * n);
  const r = (lat * Math.PI) / 180;
  const y = Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * n);
  return [x, y];
}

/**
 * 화면 하나를 열 때 지도가 부르는 타일 묶음. 프런트 style.ts 기준:
 * protected·sgg 는 줌 5~14, emd 는 9~14, 지형(dem)은 5~12. 화면은 가로 4 × 세로 3 타일로 본다.
 */
export function viewTiles(lng, lat, z) {
  const [cx, cy] = tileOf(lng, lat, z);
  const reqs = [];
  for (let dx = -2; dx <= 1; dx++) {
    for (let dy = -1; dy <= 1; dy++) {
      const x = cx + dx, y = cy + dy;
      const tag = name => ({ tags: { name } });
      reqs.push(['GET', `${BASE}/api/v1/tiles/protected/${z}/${x}/${y}.mvt`, null, tag('tile_protected')]);
      reqs.push(['GET', `${TILE_CDN || BASE}/api/v1/tiles/sgg/${z}/${x}/${y}.mvt`, null, tag('tile_sgg')]);
      if (z >= 9) reqs.push(['GET', `${TILE_CDN || BASE}/api/v1/tiles/emd/${z}/${x}/${y}.mvt`, null, tag('tile_emd')]);
      if (z <= 12) reqs.push(['GET', `${BASE}/api/v1/tiles/dem/${z}/${x}/${y}.png`, null, tag('tile_dem')]);
    }
  }
  return reqs;
}

/** 타일 묶음을 브라우저처럼 동시에 보낸다(k6 기본: 같은 주소에 6개씩) */
export const loadView = (lng, lat, z) => http.batch(viewTiles(lng, lat, z));

// H3 해상도별 평균 칸 넓이(km²). 프런트는 h3-js 로 칸을 만들지만 서버는 칸 번호를 검사하지 않고
// 단순 다각형인지만 보므로, 같은 넓이의 육각형 격자를 직접 만들어 칸 수·계산량을 실제와 맞춘다.
const H3_AREA_KM2 = { 6: 36.129, 7: 5.161, 8: 0.737, 9: 0.105, 10: 0.015 };

/** 사업장 중심에서 반경 radiusKm 안을 덮는 육각형 칸 목록(최대 3000칸). POST /sites/{id}/hex 의 cells */
export function hexCells(lng, lat, radiusKm, resolution) {
  const area = H3_AREA_KM2[resolution] || H3_AREA_KM2[8];
  const s = Math.sqrt((2 * area) / (3 * Math.sqrt(3)));   // 한 변 길이(km)
  const kmLng = 111.32 * Math.cos((lat * Math.PI) / 180), kmLat = 110.57;
  const w = Math.sqrt(3) * s, h = 1.5 * s;
  const cells = [];
  const rows = Math.ceil(radiusKm / h);
  for (let r = -rows; r <= rows && cells.length < 3000; r++) {
    const cols = Math.ceil(radiusKm / w) + 1;
    for (let c = -cols; c <= cols && cells.length < 3000; c++) {
      const x = c * w + (r % 2 ? w / 2 : 0), y = r * h;
      if (x * x + y * y > radiusKm * radiusKm) continue;
      const ring = [];
      for (let k = 0; k < 6; k++) {
        const a = (Math.PI / 180) * (60 * k - 30);
        ring.push([+(lng + (x + s * Math.cos(a)) / kmLng).toFixed(7), +(lat + (y + s * Math.sin(a)) / kmLat).toFixed(7)]);
      }
      cells.push({ id: `lt-${r}-${c}`, ring });
    }
  }
  return cells;
}
