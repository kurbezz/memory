import assert from "node:assert/strict"
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { loadMemoryIndexes, registerMemoryRuntime } from "../skills/agent-memory/opencode/memory-core.js"

async function workspace() {
  const root = await mkdtemp(join(tmpdir(), "agent-memory-plugin-"))
  await mkdir(join(root, ".memory", "project"), { recursive: true })
  await mkdir(join(root, ".memory", "workspace"), { recursive: true })
  await mkdir(join(root, ".memory", "groups", "platform"), { recursive: true })
  return root
}

async function writeIndex(root, level, text) {
  await writeFile(join(root, ".memory", level, "INDEX.md"), text)
}

function deferredEvents() {
  const queue = []
  let signal
  return {
    push(event) { queue.push(event) },
    aborted() { return signal?.aborted === true },
    async *subscribe({ signal: subscriptionSignal }) {
      signal = subscriptionSignal
      while (!signal.aborted) {
        const event = queue.shift()
        if (event) yield event
        else await new Promise((resolve) => setImmediate(resolve))
      }
    },
  }
}

async function waitFor(check) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (check()) return
    await new Promise((resolve) => setImmediate(resolve))
  }
  assert.fail("timed out waiting for async event processing")
}

function contextFor(root, events, runBackup, logEntries, locations = {}) {
  const hooks = new Map()
  return {
    hooks,
    session: {
      hook: async (name, callback) => hooks.set(name, callback),
      get: async ({ sessionID }) => {
        const location = await (locations[sessionID] ?? root)
        if (location instanceof Error) throw location
        return { id: sessionID, location: { directory: location } }
      },
    },
    event: { subscribe: ({ signal }) => events.subscribe({ signal }) },
    runBackup,
    logError: async (entry) => logEntries.push(entry),
  }
}

test("renders project, workspace, and group indexes in one memory block", async () => {
  const root = await workspace()
  await writeIndex(root, "project", "- [pool](pool.md) — gotcha: cap connections\n")
  await writeIndex(root, "workspace", "")
  await writeIndex(root, "groups/platform", "- [release](release.md) — convention: publish first\n")

  const block = await loadMemoryIndexes(root)

  assert.match(block, /<agent-memory>/)
  assert.match(block, /## \.memory\/project\/INDEX\.md \(1 facts\)/)
  assert.match(block, /## \.memory\/workspace\/INDEX\.md \(0 facts\)/)
  assert.match(block, /## \.memory\/groups\/platform\/INDEX\.md \(1 facts\)/)
  assert.match(block, /\(empty\)/)
  assert.match(block, /<\/agent-memory>/)
})

test("returns no context when the project has no memory", async () => {
  const root = await mkdtemp(join(tmpdir(), "agent-memory-empty-"))
  assert.equal(await loadMemoryIndexes(root), undefined)
})

test("loads project indexes when memory has no groups directory", async () => {
  const root = await mkdtemp(join(tmpdir(), "agent-memory-no-groups-"))
  await mkdir(join(root, ".memory", "project"), { recursive: true })
  await writeFile(join(root, ".memory", "project", "INDEX.md"), "- [pool](pool.md) — gotcha: cap connections\n")

  const block = await loadMemoryIndexes(root)

  assert.match(block, /\.memory\/project\/INDEX\.md/)
})

test("caps an oversized memory block and retains the truncation notice", async () => {
  const root = await workspace()
  const entries = Array.from({ length: 400 }, (_, index) =>
    `- [f${index}](f${index}.md) — gotcha: ${"x".repeat(90)}`,
  ).join("\n")
  await writeIndex(root, "project", entries)

  const block = await loadMemoryIndexes(root)

  assert.ok(block.length <= 25600)
  assert.match(block, /indexes truncated at 25600 characters/)
})

test("registers V2 context and compaction hooks that append one typed memory part", async (t) => {
  const root = await workspace()
  await writeIndex(root, "project", "- [pool](pool.md) — gotcha: cap connections\n")
  const events = deferredEvents(); const logs = []; const calls = []
  const ctx = contextFor(root, events, async (input) => {
    calls.push(input)
    return { exitCode: 0, stdout: "", stderr: "" }
  }, logs)
  const stop = await registerMemoryRuntime(ctx, { memoryCli: "/tmp/memory", runBackup: ctx.runBackup, logError: ctx.logError })
  t.after(stop)

  for (const name of ["context", "compaction"]) {
    const event = { sessionID: "s1", system: [{ type: "text", text: "base" }] }
    await ctx.hooks.get(name)(event)
    await ctx.hooks.get(name)(event)
    assert.equal(event.system.filter((part) => part.type === "text" && part.text.includes("<agent-memory>")).length, 1)
  }

  await stop()
  assert.equal(calls.length, 0)
  assert.equal(logs.length, 0)
})

test("does not duplicate an existing typed memory part or add one without .memory", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "agent-memory-empty-"))
  const events = deferredEvents(); const logs = []
  const ctx = contextFor(root, events, async () => ({ exitCode: 0, stdout: "", stderr: "" }), logs)
  const stop = await registerMemoryRuntime(ctx, { memoryCli: "/tmp/memory", runBackup: ctx.runBackup, logError: ctx.logError })
  t.after(stop)
  const existing = { sessionID: "s1", system: [{ type: "text", text: "<agent-memory>old</agent-memory>" }] }
  const empty = { sessionID: "s1", system: [{ type: "text", text: "base" }] }

  await ctx.hooks.get("context")(existing)
  await ctx.hooks.get("context")(empty)

  assert.equal(existing.system.length, 1)
  assert.equal(empty.system.length, 1)
  await stop()
})

test("does not duplicate memory blocks when overlapping injections load asynchronously", async (t) => {
  const root = await workspace()
  await writeIndex(root, "project", "- [pool](pool.md) — gotcha: cap connections\n")
  const events = deferredEvents(); const logs = []
  const ctx = contextFor(root, events, async () => ({ exitCode: 0, stdout: "", stderr: "" }), logs)
  const stop = await registerMemoryRuntime(ctx, { memoryCli: "/tmp/memory", runBackup: ctx.runBackup, logError: ctx.logError })
  t.after(stop)
  const event = { sessionID: "s1", system: [{ type: "text", text: "base" }] }

  await Promise.all([ctx.hooks.get("context")(event), ctx.hooks.get("compaction")(event)])

  assert.equal(event.system.filter((part) => part.type === "text" && part.text.includes("<agent-memory>")).length, 1)
})

test("backs up each idle session location once and aborts its event stream on cleanup", async (t) => {
  const root = await workspace(); const events = deferredEvents(); const logs = []; const calls = []
  const ctx = contextFor(root, events, async (input) => {
    calls.push(input)
    return { exitCode: 0, stdout: "", stderr: "" }
  }, logs)
  const stop = await registerMemoryRuntime(ctx, { memoryCli: "/tmp/memory", runBackup: ctx.runBackup, logError: ctx.logError })
  t.after(stop)
  events.push({ type: "session.idle", properties: { sessionID: "s1" } })
  await waitFor(() => calls.length === 1)
  assert.deepEqual(calls, [{ command: "/tmp/memory", args: ["backup"], cwd: root }])
  await stop()
  assert.equal(events.aborted(), true)
})

test("does not launch a backup after cleanup while its session lookup is pending", async (t) => {
  const root = await workspace(); const events = deferredEvents(); const logs = []; const calls = []
  let releaseLocation; let lookupStarted = false
  const location = new Promise((resolve) => { releaseLocation = resolve })
  const ctx = contextFor(root, events, async (input) => {
    calls.push(input)
    return { exitCode: 0, stdout: "", stderr: "" }
  }, logs, { s1: location })
  const get = ctx.session.get
  ctx.session.get = async (input) => {
    lookupStarted = true
    return get(input)
  }
  const stop = await registerMemoryRuntime(ctx, { memoryCli: "/tmp/memory", runBackup: ctx.runBackup, logError: ctx.logError })
  t.after(stop)
  events.push({ type: "session.idle", properties: { sessionID: "s1" } })
  await waitFor(() => lookupStarted)

  await stop()
  releaseLocation(root)
  await new Promise((resolve) => setImmediate(resolve))

  assert.deepEqual(calls, [])
})

test("serializes duplicate idle backups by directory while allowing other directories", async (t) => {
  const first = await workspace(); const second = await workspace()
  const events = deferredEvents(); const logs = []; const calls = []; let release
  const pending = new Promise((resolve) => { release = resolve })
  const ctx = contextFor(first, events, async (input) => {
    calls.push(input)
    await pending
    return { exitCode: 0, stdout: "", stderr: "" }
  }, logs, { s1: first, s2: second })
  const stop = await registerMemoryRuntime(ctx, { memoryCli: "/tmp/memory", runBackup: ctx.runBackup, logError: ctx.logError })
  t.after(stop)
  events.push({ type: "session.idle", properties: { sessionID: "s1" } })
  events.push({ type: "session.idle", properties: { sessionID: "s1" } })
  events.push({ type: "session.idle", properties: { sessionID: "s2" } })
  await waitFor(() => calls.length === 2)
  assert.deepEqual(calls.map((call) => call.cwd).sort(), [first, second].sort())
  release()
  await stop()
})

test("isolates index, session lookup, and backup failures with error logs", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "agent-memory-errors-"))
  await writeFile(join(root, ".memory"), "not a directory")
  const events = deferredEvents(); const logs = []
  const ctx = contextFor(root, events, async () => { throw new Error("runner failed") }, logs, {
    missing: new Error("session missing"),
  })
  const stop = await registerMemoryRuntime(ctx, { memoryCli: "/tmp/memory", runBackup: ctx.runBackup, logError: ctx.logError })
  t.after(stop)
  const indexFailure = { sessionID: "s1", system: [] }
  const lookupFailure = { sessionID: "missing", system: [] }

  await ctx.hooks.get("context")(indexFailure)
  await ctx.hooks.get("compaction")(lookupFailure)
  events.push({ type: "session.idle", properties: { sessionID: "missing" } })
  events.push({ type: "session.idle", properties: { sessionID: "s1" } })
  await waitFor(() => logs.length >= 4)

  assert.deepEqual(indexFailure.system, [])
  assert.deepEqual(lookupFailure.system, [])
  assert.deepEqual(logs.map((entry) => entry.message).sort(), [
    "Could not load memory indexes",
    "Could not resolve session location",
    "Could not resolve session location",
    "Could not start memory backup",
  ].sort())
  await stop()
})

test("logs nonzero backup results without throwing", async (t) => {
  const root = await workspace(); const events = deferredEvents(); const logs = []
  const ctx = contextFor(root, events, async () => ({ exitCode: 1, stdout: "out", stderr: "bad" }), logs)
  const stop = await registerMemoryRuntime(ctx, { memoryCli: "/tmp/memory", runBackup: ctx.runBackup, logError: ctx.logError })
  t.after(stop)

  events.push({ type: "session.idle", properties: { sessionID: "s1" } })
  await waitFor(() => logs.length === 1)

  assert.equal(logs[0].level, "error")
  assert.equal(logs[0].exitCode, 1)
  await stop()
})

test("swallows rejecting injected error loggers", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "agent-memory-rejecting-logger-"))
  await writeFile(join(root, ".memory"), "not a directory")
  const events = deferredEvents(); const logs = []
  const ctx = contextFor(root, events, async () => ({ exitCode: 0, stdout: "", stderr: "" }), logs)
  ctx.logError = async () => { throw new Error("logger failed") }
  const stop = await registerMemoryRuntime(ctx, { memoryCli: "/tmp/memory", runBackup: ctx.runBackup, logError: ctx.logError })
  t.after(stop)

  await ctx.hooks.get("context")({ sessionID: "s1", system: [] })

  assert.deepEqual(logs, [])
})

test("entrypoint is a native V2 Plugin.define adapter", async () => {
  const source = await readFile(new URL("../skills/agent-memory/opencode/agent-memory.js", import.meta.url), "utf8")
  assert.match(source, /import\s+\{\s*Plugin\s*\}\s+from\s+["']@opencode\/plugin["']/)
  assert.match(source, /Plugin\.define\(\{\s*id:\s*["']agent-memory["']/s)
  assert.doesNotMatch(source, /experimental\.|@opencode-ai\/plugin|createMemoryPlugin/)
})
