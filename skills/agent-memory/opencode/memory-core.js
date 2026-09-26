import { readdir, readFile } from "node:fs/promises"
import { join } from "node:path"

const LIMIT = 25600
const OPEN = "<agent-memory>"
const CLOSE = "</agent-memory>"
const TRUNCATED = `[agent-memory: indexes truncated at ${LIMIT} characters — consolidate the INDEX.md files]\n${CLOSE}`

function indexLines(text) {
  return text.split("\n").filter((line) => line.startsWith("- ["))
}

async function indexText(directory, relative) {
  try {
    const text = await readFile(join(directory, "INDEX.md"), "utf8")
    const lines = indexLines(text)
    return `## .memory/${relative}/INDEX.md (${lines.length} facts)\n${lines.length ? lines.join("\n") : "(empty)"}`
  } catch (error) {
    if (error && error.code === "ENOENT") return undefined
    throw error
  }
}

export async function loadMemoryIndexes(worktree) {
  const memory = join(worktree, ".memory")
  try {
    await readdir(memory)
  } catch (error) {
    if (error && error.code === "ENOENT") return undefined
    throw error
  }

  let groups
  try {
    groups = await readdir(join(memory, "groups"), { withFileTypes: true })
  } catch (error) {
    if (error && error.code === "ENOENT") groups = []
    else throw error
  }

  const sections = []
  for (const [directory, relative] of [
    [join(memory, "project"), "project"],
    [join(memory, "workspace"), "workspace"],
    ...groups.filter((entry) => entry.isDirectory() || entry.isSymbolicLink())
      .sort((left, right) => left.name.localeCompare(right.name))
      .map((entry) => [join(memory, "groups", entry.name), `groups/${entry.name}`]),
  ]) {
    const section = await indexText(directory, relative)
    if (section) sections.push(section)
  }
  if (sections.length === 0) return undefined

  const text = `${OPEN}\nThis project has long-term agent memory in ./.memory/. Indexes follow; open a fact only when relevant.\n\n${sections.join("\n\n")}\n${CLOSE}`
  if (text.length <= LIMIT) return text
  return `${text.slice(0, LIMIT - TRUNCATED.length - 1)}\n${TRUNCATED}`
}

async function log(logError, message, extra) {
  try {
    await logError({ service: "agent-memory", level: "error", message, ...extra })
  } catch {
    // Logging must not interrupt an OpenCode conversation.
  }
}

function hasMemoryBlock(parts) {
  return parts.some((part) => part.type === "text" && part.text.includes(OPEN))
}

async function appendMemoryBlock(parts, directory, logger) {
  if (hasMemoryBlock(parts)) return
  try {
    const text = await loadMemoryIndexes(directory)
    if (text && !hasMemoryBlock(parts)) parts.push({ type: "text", text })
  } catch (error) {
    await logger("Could not load memory indexes", { error: String(error), worktree: directory })
  }
}

export async function registerMemoryRuntime(ctx, { memoryCli, runBackup, logError }) {
  const backups = new Map()
  const controller = new AbortController()
  const logger = (message, extra) => log(logError, message, extra)

  async function directoryFor(sessionID) {
    const session = await ctx.session.get({ sessionID })
    return session.location.directory
  }

  async function inject(event) {
    try {
      await appendMemoryBlock(event.system, await directoryFor(event.sessionID), logger)
    } catch (error) {
      await logger("Could not resolve session location", { error: String(error), sessionID: event.sessionID })
    }
  }

  async function backup(sessionID) {
    let directory
    try {
      directory = await directoryFor(sessionID)
    } catch (error) {
      await logger("Could not resolve session location", { error: String(error), sessionID })
      return
    }
    if (controller.signal.aborted) return
    if (backups.has(directory)) return backups.get(directory)
    const pending = (async () => {
      try {
        const result = await runBackup({ command: memoryCli, args: ["backup"], cwd: directory })
        if (result.exitCode !== 0) await logger("memory backup exited nonzero", { ...result, worktree: directory })
      } catch (error) {
        await logger("Could not start memory backup", { error: String(error), worktree: directory })
      } finally {
        backups.delete(directory)
      }
    })()
    backups.set(directory, pending)
    return pending
  }

  await ctx.session.hook("context", inject)
  await ctx.session.hook("compaction", inject)
  void (async () => {
    for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
      if (event.type === "session.idle") void backup(event.properties.sessionID)
    }
  })().catch((error) => logger("Could not subscribe to OpenCode events", { error: String(error) }))
  return () => controller.abort()
}
