// terre-lab 용 복사본: 팀의 11/5 부하 시나리오(develop scripts/loadtest)를 그대로 쓰고,
// 실험실 계정이 운영 계정과 섞이지 않게 계정 이름 접두사(PREFIX)만 바꿀 수 있게 했다.
// 시나리오 B: 로그인한 기업 담당자의 사업장 분석 흐름
// 가상 사용자마다 처음 한 번만 로그인하고(쿠키 유지), 이후 반복마다
// 사업장 목록 → 상세 → 주변 분석 → 지도 타일 묶음 → 육각형 평가(조회 전용 계산) → 지역 요약·종 목록 → 지역 검색을
// 요청 사이 1~3초 쉬며 돈다. 데이터를 바꾸는 요청은 없다(계정·사업장은 setup-accounts.js 로 미리 만든다).
//   k6 run -e LOADTEST_PASSWORD=... scripts/loadtest/b-flow.js
import http from 'k6/http';
import { check, sleep, fail } from 'k6';
import { BASE, stages, thresholds, rand, pick, loadView, hexCells } from './lib.js';

const ACCOUNTS = Number(__ENV.ACCOUNTS || 10);
const PASSWORD = __ENV.LOADTEST_PASSWORD;
const PREFIX = __ENV.PREFIX || 'loadtest';
const QUERIES = ['서울', '부산', '강릉', '제주', '설악', '지리산', '대전', '춘천'];

export const options = {
  scenarios: { b_flow: { executor: 'ramping-vus', startVUs: 0, stages: stages(), gracefulRampDown: '30s' } },
  // k6 는 기본으로 반복마다 쿠키를 지운다. 로그인 쿠키를 가상 사용자 동안 유지하려면 꺼야 한다
  noCookiesReset: true,
  thresholds: thresholds({
    'http_req_duration{name:sites}': ['p(95)<1000'],
    'http_req_duration{name:site}': ['p(95)<1000'],
    'http_req_duration{name:nearby}': ['p(95)<3000'],
    'http_req_duration{name:hex_params}': ['p(95)<1000'],
    'http_req_duration{name:hex_eval}': ['p(95)<3000'],
    'http_req_duration{name:region}': ['p(95)<1000'],
    'http_req_duration{name:species}': ['p(95)<1000'],
    'http_req_duration{name:region_search}': ['p(95)<1000'],
    'http_req_duration{name:tile_protected}': ['p(95)<1000'],
    'checks{name:login}': ['rate>0.99'],
  }),
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

const json = { headers: { 'Content-Type': 'application/json' } };
let loggedIn = false;
let hexBody = {};   // 사업장별 육각형 칸(가상 사용자 안에서 한 번 만들고 재사용)

function login() {
  const email = `${PREFIX}-${String(((__VU - 1) % ACCOUNTS) + 1).padStart(2, '0')}@example.com`;
  const res = http.post(`${BASE}/api/v1/auth/login`, JSON.stringify({ email, password: PASSWORD }),
    Object.assign({ tags: { name: 'login' } }, json));
  loggedIn = check(res, { 'login 200': r => r.status === 200 }, { name: 'login' });
}

export function setup() {
  if (!PASSWORD) fail('LOADTEST_PASSWORD 가 없습니다. run.ps1 로 실행하거나 -e LOADTEST_PASSWORD=... 를 주세요');
}

export default function () {
  if (!loggedIn) { login(); if (!loggedIn) { sleep(5); return; } }

  const sites = http.get(`${BASE}/api/v1/sites`, { tags: { name: 'sites' } });
  if (sites.status === 401) { loggedIn = false; return; }   // 액세스 토큰(30분) 만료 → 다음 반복에서 다시 로그인
  if (!check(sites, { 'sites 200': r => r.status === 200 && r.json().length > 0 })) { sleep(3); return; }
  const site = pick(sites.json());
  sleep(rand(1, 3));

  const id = site.id;
  check(http.get(`${BASE}/api/v1/sites/${id}`, { tags: { name: 'site' } }), { 'site 200': r => r.status === 200 });
  check(http.get(`${BASE}/api/v1/sites/${id}/nearby`, { tags: { name: 'nearby' } }), { 'nearby 200': r => r.status === 200 });
  const tiles = loadView(site.lng, site.lat, 11);
  check(tiles, { 'tiles 200': rs => rs.every(r => r.status === 200) });
  sleep(rand(1, 3));

  const params = http.get(`${BASE}/api/v1/sites/${id}/hex`, { tags: { name: 'hex_params' } });
  if (check(params, { 'hex params 200': r => r.status === 200 })) {
    if (!hexBody[id]) {
      const p = params.json();
      hexBody[id] = JSON.stringify({ cells: hexCells(p.lng, p.lat, p.radiusKm, p.resolution) });
    }
    check(http.post(`${BASE}/api/v1/sites/${id}/hex`, hexBody[id], Object.assign({ tags: { name: 'hex_eval' } }, json)),
      { 'hex eval 200': r => r.status === 200 });
  }
  sleep(rand(1, 3));

  // 지역 검색 → 첫 결과의 지역 요약·종 목록 (화면의 지역 탐색 순서와 같다)
  const found = http.get(`${BASE}/api/v1/regions?q=${encodeURIComponent(pick(QUERIES))}`, { tags: { name: 'region_search' } });
  check(found, { 'region search 200': r => r.status === 200 });
  sleep(rand(1, 3));

  const code = site.sggCode || site.sidoCode || (found.status === 200 && found.json().length ? found.json()[0].code : null);
  if (code) {
    check(http.get(`${BASE}/api/v1/regions/${code}`, { tags: { name: 'region' } }), { 'region 200': r => r.status === 200 });
    check(http.get(`${BASE}/api/v1/regions/species?codes=${code}`, { tags: { name: 'species' } }),
      { 'species 200': r => r.status === 200 });
  }
  sleep(rand(1, 3));
}
