// terre-lab 용 복사본: 팀의 11/5 부하 시나리오(develop scripts/loadtest)를 그대로 쓰고,
// 실험실 계정이 운영 계정과 섞이지 않게 계정 이름 접두사(PREFIX)만 바꿀 수 있게 했다.
// 시나리오 A: 로그인 없이 지도를 여는 사용자
// 첫 화면 → 지도 레이어 목록 → 무작위 위치·줌의 타일 묶음(한 화면 24~48개)을 동시에 받는다.
// k6 는 브라우저 캐시를 쓰지 않으므로 "처음 지도를 연 사용자" 기준(가장 무거운 경우)이다.
//   k6 run scripts/loadtest/a-tiles.js                     (배포 서버, 50·100·200명)
//   k6 run -e BASE=http://localhost:8088 -e STEPS=5 -e HOLD=30s -e WARMUP=10s scripts/loadtest/a-tiles.js   (로컬 연습)
import http from 'k6/http';
import { check, sleep } from 'k6';
import { BASE, stages, thresholds, rand, pick, PLACES, loadView } from './lib.js';

export const options = {
  scenarios: { a_tiles: { executor: 'ramping-vus', startVUs: 0, stages: stages(), gracefulRampDown: '30s' } },
  thresholds: thresholds({
    'http_req_duration{name:index}': ['p(95)<1000'],
    'http_req_duration{name:layers}': ['p(95)<1000'],
    'http_req_duration{name:tile_protected}': ['p(95)<1000'],
    'http_req_duration{name:tile_sgg}': ['p(95)<1000'],
    'http_req_duration{name:tile_emd}': ['p(95)<1000'],
    'http_req_duration{name:tile_dem}': ['p(95)<1000'],
  }),
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const index = http.get(`${BASE}/`, { tags: { name: 'index' } });
  check(index, { 'index 200': r => r.status === 200 });
  const layers = http.get(`${BASE}/api/v1/layers`, { tags: { name: 'layers' } });
  check(layers, { 'layers 200': r => r.status === 200 });

  // 지도를 열고 2~3번 움직이거나 확대해 보는 사람
  const [lng, lat] = pick(PLACES);
  let z = Math.floor(rand(7, 10));
  for (let i = 0; i < 3; i++) {
    const res = loadView(lng + rand(-0.3, 0.3), lat + rand(-0.2, 0.2), z);
    check(res, { 'tiles 200': rs => rs.every(r => r.status === 200) });
    z = Math.min(z + 1, 12);
    sleep(rand(1, 3));
  }
}
