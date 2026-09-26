import { execFile } from "node:child_process"
import { realpath } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { registerMemoryRuntime } from "./memory-core.js"

const moduleDirectory = await realpath(dirname(fileURLToPath(import.meta.url)))
const memoryCli = resolve(moduleDirectory, "../bin/memory")

function runCommand({ command, args, cwd }) {
  return new Promise((resolveResult, reject) => {
    execFile(command, args, { cwd, encoding: "buffer", shell: false }, (error, stdout, stderr) => {
      if (!error) return resolveResult({ exitCode: 0, stdout, stderr })
      if (typeof error.code === "number") return resolveResult({ exitCode: error.code, stdout, stderr })
      reject(error)
    })
  })
}

async function logError(entry) {
  try {
    console.error("[agent-memory]", entry)
  } catch {
    // Logging must not interrupt OpenCode hooks.
  }
}

// A plain V2 plugin object ({ id, setup }). `Plugin.define` from
// @opencode/plugin is an identity function; importing it would make the plugin
// unloadable when installed as a copied skill with no node_modules next to it.
export default {
  id: "agent-memory",
  setup(ctx) {
    return registerMemoryRuntime(ctx, { memoryCli, runBackup: runCommand, logError })
  },
}
