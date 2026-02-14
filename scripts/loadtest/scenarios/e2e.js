import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const timeoutCounter = new Counter('custom_timeouts_total');

const baseUrl = __ENV.SCIM_BASE_URL || 'http://scim-bridge:8080';
const token = __ENV.SCIM_BEARER_TOKEN;
const profile = __ENV.LOAD_PROFILE || 'ramp';
const targetRate = Number(__ENV.TARGET_RATE || '80');
const duration = __ENV.TEST_DURATION || '5m';
const preAllocatedVUs = Number(__ENV.PRE_ALLOCATED_VUS || '50');
const maxVUs = Number(__ENV.MAX_VUS || '300');

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

function markTimeout(res) {
  if (res.status === 0) {
    timeoutCounter.add(1);
  }
}

export default function () {
  const id = `${Date.now()}-${__VU}-${__ITER}`;
  const groupName = `lt-group-${id}`;
  const username = `lt-user-${id}`;

  const groupRes = http.post(
    `${baseUrl}/scim/v2/Groups`,
    JSON.stringify({ displayName: groupName }),
    { headers: authHeaders(), tags: { scenario: 'e2e_group_create' }, timeout: '10s' }
  );
  markTimeout(groupRes);

  const userRes = http.post(
    `${baseUrl}/scim/v2/Users`,
    JSON.stringify({
      userName: username,
      externalId: username,
      active: true,
      name: { givenName: 'Load', familyName: 'E2E' },
      emails: [{ value: `${username}@localtest.me`, primary: true }],
      password: 'load-test-password',
      groups: [{ display: groupName }],
    }),
    { headers: authHeaders(), tags: { scenario: 'e2e_user_create' }, timeout: '10s' }
  );
  markTimeout(userRes);

  let userId = null;
  try {
    userId = JSON.parse(userRes.body).id;
  } catch (_err) {
    userId = null;
  }

  if (userId) {
    const patchRes = http.patch(
      `${baseUrl}/scim/v2/Users/${userId}`,
      JSON.stringify({
        Operations: [{ op: 'Replace', path: 'active', value: true }],
      }),
      { headers: authHeaders(), tags: { scenario: 'e2e_user_patch' }, timeout: '10s' }
    );
    markTimeout(patchRes);

    check(patchRes, {
      'patch status is 200': (r) => r.status === 200,
    });
  }

  check(groupRes, {
    'group status is 201/200': (r) => r.status === 201 || r.status === 200,
  });
  check(userRes, {
    'user status is 201/200': (r) => r.status === 201 || r.status === 200,
  });

  sleep(0.05);
}
