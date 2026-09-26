import { execFile } from "node:child_process"
import { realpath } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { Plugin } from "@opencode/plugin"

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

export default Plugin.define({
  id: "agent-memory",
  setup(ctx) {
    return registerMemoryRuntime(ctx, { memoryCli, runBackup: runCommand, logError })
  },
})
