import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const timeoutCounter = new Counter('custom_timeouts_total');

const baseUrl = __ENV.SCIM_BASE_URL || 'http://scim-bridge:8080';
const token = __ENV.SCIM_BEARER_TOKEN;
const profile = __ENV.LOAD_PROFILE || 'ramp';
const targetRate = Number(__ENV.TARGET_RATE || '100');
const duration = __ENV.TEST_DURATION || '5m';
const preAllocatedVUs = Number(__ENV.PRE_ALLOCATED_VUS || '50');
const maxVUs = Number(__ENV.MAX_VUS || '300');
const groupName = __ENV.NB_DEMO_GROUP || 'demo-users';

function scenarioFor(loadProfile) {
  if (loadProfile === 'steady') {
    return {
      executor: 'constant-arrival-rate',
      rate: targetRate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs,
      maxVUs,
    };
  }

  if (loadProfile === 'spike') {
    return {
      executor: 'ramping-arrival-rate',
      startRate: Math.max(1, Math.floor(targetRate * 0.2)),
      timeUnit: '1s',
      preAllocatedVUs,
      maxVUs,
      stages: [
        { target: Math.max(1, Math.floor(targetRate * 0.3)), duration: '1m' },
        { target: targetRate * 2, duration: '1m' },
        { target: targetRate * 2, duration: '1m' },
        { target: targetRate, duration: '1m' },
      ],
    };
  }

  return {
    executor: 'ramping-arrival-rate',
    startRate: 1,
    timeUnit: '1s',
    preAllocatedVUs,
    maxVUs,
    stages: [
      { target: Math.max(1, Math.floor(targetRate * 0.5)), duration: '2m' },
      { target: targetRate, duration: '2m' },
      { target: targetRate, duration },
    ],
  };
}

export const options = {
  scenarios: {
    main: scenarioFor(profile),
  },
  thresholds: {
    http_req_duration: ['p(95)<500'],
    http_req_failed: ['rate<0.01'],
  },
};

if (!token) {
  throw new Error('SCIM_BEARER_TOKEN is required');
}

function authHeaders() {
  return {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  };
}

export default function () {
  const id = `${Date.now()}-${__VU}-${__ITER}`;
  const payload = JSON.stringify({
    userName: `lt-user-${id}`,
    externalId: `lt-user-${id}`,
    active: true,
    name: { givenName: 'Load', familyName: 'Test' },
    emails: [{ value: `lt-user-${id}@localtest.me`, primary: true }],
    password: 'load-test-password',
    groups: [{ display: groupName }],
  });

  const res = http.post(`${baseUrl}/scim/v2/Users`, payload, {
    headers: authHeaders(),
    tags: { scenario: 'scim_user_create' },
    timeout: '10s',
  });

  if (res.status === 0) {
    timeoutCounter.add(1);
  }

  check(res, {
    'status is 200/201': (r) => r.status === 200 || r.status === 201,
  });

  sleep(0.05);
}
