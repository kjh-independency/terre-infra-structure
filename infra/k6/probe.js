// terre-lab 시험 T3(배포 중 끊김)·T5(장애 회복)용 감시 요청.
// 1초에 RATE번(기본 10) DURATION(기본 5m) 동안 web → backend → DB 를 지나는 가벼운 API 를 부른다.
// 요청마다 성공·실패와 시각이 결과 파일(json.gz)에 남아, 언제부터 언제까지 끊겼는지 계산할 수 있다.
import http from 'k6/http';
import { check } from 'k6';

const BASE = (__ENV.BASE || 'http://web').replace(/\/$/, '');

export const options = {
  discardResponseBodies: true,
  scenarios: {
    probe: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 10),
      timeUnit: '1s',
      duration: __ENV.DURATION || '5m',
      preAllocatedVUs: 20,
      maxVUs: 60,
    },
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const r = http.get(`${BASE}/api/v1/layers`, { tags: { name: 'layers' }, timeout: '5s' });
  check(r, { 'layers 200': (x) => x.status === 200 });
}
