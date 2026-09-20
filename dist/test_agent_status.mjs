// Run with: node --test dist/test_agent_status.mjs (Node 22.6+).
// Execute the exact bundled Pi adapter against its event contract, without
// touching the user's installed extension or terminal.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import vm from 'node:vm';

const swift = readFileSync(new URL('../macos/Sources/Features/Plugins/AgentStatusPlugin.swift', import.meta.url), 'utf8');
const source = swift.match(/private static let piExtension = #"""\n([\s\S]*?)\n"""#/)[1];

function fixture(tasks = []) {
  const hooks = new Map();
  const listeners = new Map();
  const states = [];
  const events = {
    on(name, fn) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(fn);
      return () => listeners.get(name).delete(fn);
    },
    emit(name, payload) {
      for (const fn of [...(listeners.get(name) ?? [])]) fn(payload);
      if (name === 'pi-background-tasks:request:v1') {
        events.emit('pi-background-tasks:response:v1', {
          request_id: payload.request_id, ok: true, result: { tasks },
        });
      }
      if (name === 'subagents:rpc:v1:request') {
        events.emit(`subagents:rpc:v1:reply:${payload.requestId}`, {
          success: true, data: { asyncSnapshot: { runs: [] } },
        });
      }
    },
  };
  const sandbox = {
    process: { pid: 123, env: {} },
    openSync: () => 1,
    closeSync() {},
    writeSync(_fd, sequence) {
      states.push(sequence.includes(';end=') ? 'end' : sequence.match(/omg_state=([^;\u0007]+)/)[1]);
    },
  };
  vm.createContext(sandbox);
  const js = stripTypeScriptTypes(source.replace(/^import .*node:fs.*;$/m, '')).replace('export default function', 'globalThis.install = function');
  vm.runInContext(js, sandbox);
  sandbox.install({ events, on: (name, fn) => hooks.set(name, fn) });
  const context = { isIdle: () => true };
  return { states, events, call: (name, event = {}) => hooks.get(name)(event, context) };
}

test('startup and repeated empty snapshots remain idle', async () => {
  const f = fixture();
  await f.call('session_start');
  f.events.emit('subagents:rpc:v1:ready');
  await f.call('agent_settled');
  assert.deepEqual(f.states, ['idle']);
});

test('a foreground turn completes once; snapshots cannot restore an acknowledged badge', async () => {
  const f = fixture();
  await f.call('session_start');
  await f.call('before_agent_start');
  await f.call('agent_start');
  await f.call('agent_settled');
  assert.equal(f.states.at(-1), 'done');
  const count = f.states.length;
  f.events.emit('subagents:rpc:v1:ready');
  f.events.emit('pi-background-tasks:terminal:v1', { task: { id: 'unknown' } });
  await f.call('agent_settled');
  assert.equal(f.states.length, count);
});

test('observed background work can complete while foreground is idle', async () => {
  const f = fixture([{ id: 'running-task', status: 'running' }]);
  await f.call('session_start');
  assert.deepEqual(f.states, ['idle', 'working']);
  f.events.emit('pi-background-tasks:terminal:v1', { task: { id: 'running-task' } });
  assert.equal(f.states.at(-1), 'done');
});

test('shutdown clears identity and ignores late background completion', async () => {
  const f = fixture();
  await f.call('session_start');
  f.events.emit('subagent:async-started', { id: 'child' });
  await f.call('session_shutdown');
  const count = f.states.length;
  f.events.emit('subagent:async-complete', { id: 'child' });
  assert.equal(f.states.length, count);
  assert.deepEqual(f.states.slice(-2), ['idle', 'end']);
});
