// terre-lab 용 복사본: 팀의 11/5 부하 시나리오(develop scripts/loadtest)를 그대로 쓰고,
// 실험실 계정이 운영 계정과 섞이지 않게 계정 이름 접두사(PREFIX)만 바꿀 수 있게 했다.
// 시나리오 B 용 테스트 계정·사업장 준비. 측정 전에 한 번만 돈다(사용자 1명, 1회).
// loadtest-01@example.com ~ loadtest-NN 을 가입시키고, 사업장이 없으면 1개씩 등록한다. 이미 있으면 건너뛴다.
// 측정 본 시나리오(a·b)는 데이터를 바꾸지 않고, 이 스크립트만 쓰기 요청을 한다. 정리는 docs/09 의 "테스트 데이터 정리".
//   k6 run -e LOADTEST_PASSWORD=... scripts/loadtest/setup-accounts.js
//
// 실패 처리(!138 리뷰): k6 의 fail() 은 그 iteration 만 끝내고 종료 코드는 0 이라 run.ps1 이 "준비 성공" 으로 오해했다.
// 그래서 오류를 metric(setup_errors)으로 세고 threshold 로 걸어, 하나라도 실패하면 k6 가 99 로 끝나게 한다.
// 준비된 계정 수(setup_ready)도 ACCOUNTS 와 같아야 통과한다. 비밀번호가 없으면 setup() 에서 던져 107 로 끝난다.
// 처음 가입하는 계정의 login 401 → signup 201 은 정상 경로라 HTTP 실패율로 판정하지 않는다.
import http from 'k6/http';
import { check, fail } from 'k6';
import { Counter } from 'k6/metrics';
import { BASE, PLACES } from './lib.js';

const ACCOUNTS = Number(__ENV.ACCOUNTS || 10);
const PASSWORD = __ENV.LOADTEST_PASSWORD;
const PREFIX = __ENV.PREFIX || 'loadtest';
const json = { headers: { 'Content-Type': 'application/json' } };

export const setupErrors = new Counter('setup_errors');
export const setupReady = new Counter('setup_ready');

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    setup_errors: ['count<1'],
    setup_ready: [`count>=${ACCOUNTS}`],
  },
};

export function setup() {
  if (!PASSWORD) throw new Error('LOADTEST_PASSWORD 가 없습니다');
}

function bad(msg) {
  setupErrors.add(1);
  fail(msg);
}

export default function () {
  for (let i = 1; i <= ACCOUNTS; i++) {
    const no = String(i).padStart(2, '0');
    const email = `${PREFIX}-${no}@example.com`;
    http.cookieJar().clear(BASE);

    let res = http.post(`${BASE}/api/v1/auth/login`, JSON.stringify({ email, password: PASSWORD }), json);
    if (res.status !== 200) {
      res = http.post(`${BASE}/api/v1/auth/signup`, JSON.stringify({
        email, password: PASSWORD, name: `부하테스트 ${no}`, orgName: `부하테스트 기업 ${no}`, agreedTerms: true,
      }), json);
      if (!check(res, { 'signup 201': r => r.status === 201 })) bad(`${email} 가입 실패: ${res.status}`);
    }

    const sites = http.get(`${BASE}/api/v1/sites`);
    if (!check(sites, { 'sites 200': r => r.status === 200 })) bad(`${email} 사업장 조회 실패: ${sites.status}`);
    let list;
    try { list = sites.json(); } catch (e) { bad(`${email} 사업장 목록이 JSON 이 아닙니다`); }
    if (!Array.isArray(list)) bad(`${email} 사업장 목록 형식이 다릅니다`);
    if (list.length === 0) {
      const [lng, lat] = PLACES[(i - 1) % PLACES.length];
      res = http.post(`${BASE}/api/v1/sites`, JSON.stringify({ name: `부하테스트 사업장 ${no}`, lat, lng }), json);
      if (!check(res, { 'site 201': r => r.status === 201 })) bad(`${email} 사업장 등록 실패: ${res.status}`);
    }
    setupReady.add(1);
    console.log(`${email} 준비됨`);
  }
}
