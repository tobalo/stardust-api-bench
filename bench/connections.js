/**
 * Connection capacity: how many concurrent keep-alive connections one server holds.
 *
 * One client can open only ~64,500 connections to one server address (one ephemeral port each),
 * so the test spreads them over every address in BASE_URLS: the server's IPv4, its IPv6, and the
 * eight addresses of its routed IPv6 /64 (deploy/linode/main.tf). Each VU holds one keep-alive
 * connection to each address and asks GET /health (a StardustDB read) on it about every
 * CONNS / RATE seconds, so the server sees RATE requests/s at every step, ramp included, and only
 * the number of open connections changes. This measures the network layer and the host's memory,
 * not the challenge score.
 *
 *   k6 run -e BASE_URLS='http://203.0.113.5,http://[2001:db8::5]' -e VUS=100000 bench/connections.js
 *
 * Env: BASE_URLS (comma-separated; default BASE_URL), VUS (connections, default 1000; the VU count
 *      is VUS / addresses), RATE (requests/s, default 1000), DURATION (the hold after the ramp, default 5m).
 *
 * Pass: p95 < 500 ms, p99 < 1000 ms, under 1% failed requests: load.js's thresholds.
 */
import http from 'k6/http';
import { check, sleep } from 'k6';

const URLS = (__ENV.BASE_URLS || __ENV.BASE_URL).split(',').filter(Boolean);
const CONNS = Number(__ENV.VUS || 1000);
const VUS = Math.ceil(CONNS / URLS.length);
const PERIOD = CONNS / Number(__ENV.RATE || 1000); // seconds between requests on one connection, on average

export const options = {
  scenarios: {
    connections: {
      executor: 'ramping-vus',
      stages: [
        { duration: `${Math.ceil(PERIOD)}s`, target: VUS }, // CONNS / PERIOD new connections per second = RATE
        { duration: __ENV.DURATION || '5m', target: VUS },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  for (const base of URLS) {
    check(http.get(`${base}/health`, { tags: { name: 'GET /health' } }), { 'health 200': (r) => r.status === 200 });
  }
  sleep(PERIOD * (0.5 + Math.random()));
}
