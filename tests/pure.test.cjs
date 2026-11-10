/**
 * Pure-function coverage for dsh-status-box (client half).
 * node:test + node:assert; loads the real client.js through the same fake
 * module loader the browser uses, then drives aggregate() / buildBridgePayload()
 * directly via the plugin's __internal export (no DOM, no React render).
 *
 * run: node --test tests/   (no dependencies; the helper stubs React)
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const CLIENT = path.join(__dirname, '..', 'client.js');
// The pure helpers never render, so a minimal stub is enough (no npm install).
const React = {
  createElement() { return null; },
  useState(value) { return [typeof value === 'function' ? value() : value, function () {}]; },
  useEffect() {},
  useMemo(factory) { return factory(); },
  useSyncExternalStore(_subscribe, getSnapshot) { return getSnapshot(); }
};

let captured = null;
global.window = {
  __ModuleLoader__: { load(def) { captured = def; } },
  addEventListener() {},
  removeEventListener() {}
};
global.document = {
  head: { appendChild() {} },
  createElement() {
    return { tagName: 'style', dataset: {}, textContent: '', remove() {} };
  },
  querySelectorAll() { return []; }
};

vm.runInThisContext(fs.readFileSync(CLIENT, 'utf8'), { filename: CLIENT });
assert.ok(captured, 'client half did not register itself');
const plugin = captured.factory((spec) => {
  if (spec === 'react') return React;
  throw new Error('unexpected require: ' + spec);
});
const { aggregate, buildBridgePayload } = plugin.__internal;

const NOW = 1700000000000;

function session(id, extra) {
  return Object.assign({ id, title: id, running: false, updatedAt: 0 }, extra || {});
}

function fixture() {
  const snapshot = {
    items: [
      { workspaceId: 'w-a', title: 'alpha', path: '/tmp/alpha', sessionIds: ['s-wait', 's-run', 's-done', 's-idle', 's-arch', 's-blank', 's-parent'], createdAt: 0, updatedAt: 0 },
      { workspaceId: 'w-b', title: '', path: '/tmp/beta', sessionIds: [], createdAt: 0, updatedAt: 0 }
    ],
    archivedSessionIds: ['s-arch'],
    pinnedSessionIds: []
  };
  const list = {
    ids: ['s-wait', 's-run', 's-done', 's-idle', 's-child', 's-stray'],
    byId: {
      's-wait': session('s-wait', { title: '等你处理', updatedAt: NOW - 1000 }),
      's-run': session('s-run', { title: '正在跑', running: true, updatedAt: NOW - 2000 }),
      's-done': session('s-done', { title: '已完成', updatedAt: NOW - 3000 }),
      's-idle': session('s-idle', { title: '空闲', updatedAt: NOW - 4000 }),
      's-arch': session('s-arch', { title: '归档', updatedAt: NOW - 5000 }),
      's-blank': session('s-blank', { title: '', blank: true }),
      's-parent': session('s-parent', { title: '父会话', running: true, updatedAt: NOW - 6000 }),
      's-child': session('s-child', { title: '子代理', origin: 'subagent', running: true, updatedAt: NOW - 7000 }),
      's-stray': session('s-stray', { title: '未分组', updatedAt: NOW - 8000 })
    },
    projectionsBySession: {
      's-parent': { values: { subagentCatalog: [{ id: 's-child' }] } }
    }
  };
  const statuses = new Map([
    ['s-wait', { running: true, pendingInteraction: { kind: 'approval' }, completionUnread: false }],
    ['s-run', { running: true }],
    ['s-done', { running: false, completionUnread: true }]
  ]);
  return { snapshot, list, statuses };
}

test('aggregate: groups by workspace, skips subagents / blanks / archived, keeps stray group', () => {
  const { snapshot, list, statuses } = fixture();
  const data = aggregate(snapshot, list, statuses, NOW);
  const ids = data.groups.map((group) => group.id).sort();
  assert.deepStrictEqual(ids, ['', 'w-a', 'w-b'], 'workspaces plus a stray group');
  assert.strictEqual(data.groups[0].id, 'w-a', 'the active workspace sorts first');

  const alpha = data.groups[0];
  assert.deepStrictEqual(alpha.rows.map((row) => row.id), ['s-wait', 's-run', 's-parent', 's-done', 's-idle'], 'rows: waiting, running (newest first), done, idle');
  assert.ok(!alpha.rows.some((row) => row.id === 's-child'), 'subagent rows are filtered out');
  assert.ok(!alpha.rows.some((row) => row.id === 's-arch'), 'archived rows are filtered out');
  assert.ok(!alpha.rows.some((row) => row.id === 's-blank'), 'blank rows are filtered out');
  const stray = data.groups.find((group) => group.id === '');
  assert.deepStrictEqual(stray.rows.map((row) => row.id), ['s-stray'], 'sessions outside every workspace land in the stray group');
});

test('aggregate: status priority and per-row subagent counters', () => {
  const { snapshot, list, statuses } = fixture();
  const data = aggregate(snapshot, list, statuses, NOW);
  const rows = data.groups[0].rows;
  const byId = Object.fromEntries(rows.map((row) => [row.id, row]));
  assert.strictEqual(byId['s-wait'].state, 'waiting', 'pendingInteraction wins over running');
  assert.strictEqual(byId['s-run'].state, 'running');
  assert.strictEqual(byId['s-done'].state, 'done');
  assert.strictEqual(byId['s-idle'].state, 'idle');
  assert.strictEqual(byId['s-parent'].subagents, 1, 'subagent catalog is counted');
  assert.strictEqual(byId['s-parent'].runningSubagents, 1, 'running child counted from the status map');
});

test('aggregate: totals and workspace title fallback', () => {
  const { snapshot, list, statuses } = fixture();
  const data = aggregate(snapshot, list, statuses, NOW);
  assert.deepStrictEqual(data.totals, { waiting: 1, running: 2, done: 1, idle: 2, total: 6 });
  const beta = data.groups.find((group) => group.id === 'w-b');
  assert.strictEqual(beta.title, '/tmp/beta', 'empty workspace title falls back to its path');
  assert.deepStrictEqual(data.workspaces, [
    { id: 'w-a', title: 'alpha' },
    { id: 'w-b', title: '/tmp/beta' }
  ], 'every workspace travels, empty ones included');
});

test('aggregate: tolerates missing snapshots', () => {
  const data = aggregate(undefined, undefined, undefined, NOW);
  assert.deepStrictEqual(data.groups, []);
  assert.deepStrictEqual(data.totals, { waiting: 0, running: 0, done: 0, idle: 0, total: 0 });
});

test('buildBridgePayload: shape, empty workspaces, idle filtering and the 10 session cap', () => {
  const many = [];
  const ids = [];
  for (let index = 0; index < 14; index += 1) {
    ids.push('s' + index);
    many.push(session('s' + index, { title: 'T' + index, running: true, updatedAt: NOW - index }));
  }
  const data = {
    totals: { waiting: 0, running: 14, done: 0, idle: 0, total: 14 },
    groups: [
      {
        id: 'w-a',
        title: 'alpha',
        counts: { waiting: 0, running: 14, done: 0, idle: 0 },
        rows: many.map((row) => ({ id: row.id, title: row.title, state: 'running', stateRank: 1, subagents: 0, runningSubagents: 0, updatedAt: row.updatedAt }))
          .concat([{ id: 'idle-1', title: 'idle', state: 'idle', stateRank: 3, subagents: 0, runningSubagents: 0, updatedAt: 0 }])
      },
      {
        id: 'w-empty',
        title: 'empty',
        counts: { waiting: 0, running: 0, done: 0, idle: 0 },
        rows: []
      }
    ]
  };
  const payload = buildBridgePayload(data);
  assert.strictEqual(payload.v, 1);
  assert.strictEqual(typeof payload.ts, 'number');
  assert.deepStrictEqual(payload.totals, data.totals, 'totals pass through untouched');
  assert.deepStrictEqual(payload.workspaces, [
    { id: 'w-a', title: 'alpha', waiting: 0, running: 14, done: 0 },
    { id: 'w-empty', title: 'empty', waiting: 0, running: 0, done: 0 }
  ], 'empty workspaces are advertised so the native popup can target them');
  assert.strictEqual(payload.sessions.length, 10, 'sessions are capped at ten');
  assert.ok(!payload.sessions.some((entry) => entry.state === 'idle'), 'idle sessions are not advertised');
  assert.deepStrictEqual(payload.sessions[0], { title: 'T0', state: 'running', workspace: 'alpha' });
});
