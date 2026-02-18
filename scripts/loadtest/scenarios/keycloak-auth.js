import http from "k6/http";
import { check } from "k6";
import { Counter } from "k6/metrics";

const customTimeoutsTotal = new Counter("custom_timeouts_total");

const baseUrl = __ENV.KC_BASE_URL || "http://keycloak:8080";
const realm = __ENV.KC_REALM || "master";
const clientId = __ENV.KC_CLIENT_ID || "netbird";
const username = __ENV.KC_USERNAME || "demo-user";
const password = __ENV.KC_PASSWORD || "dev-demo-password";
const profile = __ENV.LOAD_PROFILE || "ramp";
const targetRate = Number(__ENV.TARGET_RATE || "100");
const duration = __ENV.TEST_DURATION || "5m";
const preAllocatedVUs = Number(__ENV.PRE_ALLOCATED_VUS || "50");
const maxVUs = Number(__ENV.MAX_VUS || "300");

const tokenUrl = `${baseUrl}/realms/${realm}/protocol/openid-connect/token`;
const payload = `client_id=${encodeURIComponent(clientId)}&grant_type=password&username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`;
const params = {
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  timeout: "10s",
};

const profileOptions = {
  ramp: {
    executor: "ramping-arrival-rate",
    startRate: Math.max(1, Math.floor(targetRate * 0.1)),
    timeUnit: "1s",
    preAllocatedVUs,
    maxVUs,
    stages: [
      { target: Math.max(1, Math.floor(targetRate * 0.5)), duration: "30s" },
      { target: targetRate, duration: "60s" },
      { target: targetRate, duration },
      { target: Math.max(1, Math.floor(targetRate * 0.3)), duration: "30s" },
    ],
  },
  steady: {
    executor: "constant-arrival-rate",
    rate: targetRate,
    timeUnit: "1s",
    duration,
    preAllocatedVUs,
    maxVUs,
  },
  spike: {
    executor: "ramping-arrival-rate",
    startRate: Math.max(1, Math.floor(targetRate * 0.2)),
    timeUnit: "1s",
    preAllocatedVUs,
    maxVUs,
    stages: [
      { target: targetRate * 2, duration: "30s" },
      { target: Math.max(1, Math.floor(targetRate * 0.3)), duration: "60s" },
    ],
  },
};

export const options = {
  scenarios: {
    token_auth: profileOptions[profile] || profileOptions.ramp,
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<500"],
  },
};

export default function () {
  const res = http.post(tokenUrl, payload, params);
  const ok = check(res, {
    "token endpoint status is 200": (r) => r.status === 200,
    "access token exists": (r) => {
      try {
        return Boolean(r.json("access_token"));
      } catch (e) {
        return false;
      }
    },
  });

  if (!ok && res.error_code === 1050) {
    customTimeoutsTotal.add(1);
  }
}
