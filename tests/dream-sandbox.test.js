// Checks the `memory dream` sandbox rules in skills/agent-memory/dream/opencode.json
// with a matcher that follows OpenCode V2's documented rules: whole-value
// wildcards (`*` = any run of characters including `/`, `?` = one character),
// a pattern ending in ` *` also matches the bare command, last matching rule
// wins, and the unmatched default is deny (the rule lists start with deny `*`).
// Matching is case-insensitive, as observed with OpenCode v2.0.19.
// This file does not run OpenCode; it catches rule regressions.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const STORE = "/Users/u/.agent-memory";
const HOME = "/Users/u";
const BIN = "/opt/agent-memory/skills/agent-memory/bin/memory";
const raw = readFileSync(new URL("../skills/agent-memory/dream/opencode.json", import.meta.url), "utf8")
  .replaceAll("__STORE__", STORE)
  .replaceAll("__HOME__", HOME)
  .replaceAll("__MEMORY_BIN__", BIN);
const config = JSON.parse(raw);

function glob(pattern, value) {
  const re = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".");
  const full = new RegExp(`^${re}$`, "is");
  if (full.test(value)) return true;
  return pattern.endsWith(" *") && new RegExp(`^${re.slice(0, -3)}$`, "is").test(value);
}

function decide(rules, action, resource) {
  let effect = "deny";
  for (const r of rules) {
    const [a, res] = r.action === "permission" ? [r.resource.split(":")[0], r.resource.slice(r.resource.indexOf(":") + 1)] : [r.action, r.resource];
    if (glob(a, action) && glob(res, resource)) effect = r.effect;
  }
  return effect;
}

// A check passes only if both the hard policy and the agent's own rules allow it.
function allowed(agent, action, resource) {
  const policy = decide(config.experimental.policies, action, resource);
  const own = decide(config.agents[agent].permissions, action, resource);
  return policy === "allow" && own === "allow";
}

const dream = (action, resource) => allowed("memory-dream", action, resource);
const check = (action, resource) => allowed("memory-dream-check", action, resource);

test("dream agent: allowed shell commands", () => {
  for (const cmd of [
    `${BIN} dream --report`,
    `${BIN} dream --report --workspace work`,
    `git -C ${STORE} status --short`,
    `git -C ${STORE} log --oneline -5`,
    `git -C ${STORE} add work/projects/a/x.md`,
    `git -C ${STORE} rm work/projects/a/x.md`,
    // Refused in a live run by an old `*config*` substring rule.
    `git -C ${STORE} rm -q work/projects/agents-configs/pending-claude-skills-configuration.md`,
    `git -C /Users/u/work/app show HEAD:app/push_notifications.py`,
    `rtk git -C ${STORE} status --short`,
    `git -C /Users/u/work/app log --format=%h --date=short -3 origin/production`,
    `rtk git -C /Users/u/work/app log --format="%h %cd %s" --date=short -3 origin/production`,
    `git -C /Users/u/work/app ls-tree origin/master --name-only`,
    `git -C /Users/u/work/app show HEAD:app/config.py`,
    `readlink /Users/u/work/app/.memory/project`,
  ]) assert.ok(dream("shell", cmd), `should allow: ${cmd}`);
});

test("dream agent: blocked shell commands", () => {
  for (const cmd of [
    `${BIN} dream`,
    `${BIN} init work`,
    `${BIN} backup --push`,
    `git -C ${STORE} push`,
    `git -C ${STORE} push origin HEAD`,
    `git -C ${STORE} log push`,
    `git -C ${STORE} status push origin`,
    `git -C ${STORE} config user.name x`,
    `git -C ${STORE} log config core.hooksPath /tmp`,
    `git -C ${STORE} remote add origin https://example.com/x`,
    `git -C ${STORE} -c core.pager=sh log`,
    `git -C ${STORE} log -c core.pager=sh`,
    `rtk git -C ${STORE} -c core.pager=sh log`,
    `git -C ${STORE} log --config-env=core.pager=X`,
    `git -C ${STORE} commit -m x`,
    `git -C ${STORE} reset --hard HEAD~1`,
    `git -C /Users/u/work/app checkout .`,
    `git -C /Users/u/work/app log --output=/tmp/leak -1`,
    `git -C /Users/u/work/app log -1 --ext-diff`,
    `git diff --no-index /etc/hosts ${HOME}/.ssh/id_ed25519`,
    `git -C ${STORE} status; touch /tmp/x`,
    `git -C ${STORE} status && touch /tmp/x`,
    `git -C ${STORE} log | sh`,
    `git -C ${STORE} log > /tmp/x`,
    `git -C ${STORE} log $(touch /tmp/x)`,
    "git -C " + STORE + " log `touch /tmp/x`",
    `cat ${HOME}/.ssh/id_ed25519`,
    `rg --pre sh x`,
    `find / -exec sh {} ;`,
    `touch /tmp/x`,
    `rm -rf ${STORE}`,
    `curl https://example.com`,
  ]) assert.ok(!dream("shell", cmd), `should block: ${cmd}`);
});

test("dream agent: edits only inside the store, never .git", () => {
  for (const p of ["work/projects/a/x.md", "work/groups/g/x.md", `${STORE}/work/workspace/x.md`])
    assert.ok(dream("edit", p), `should allow edit: ${p}`);
  for (const p of [
    "/tmp/x", `${HOME}/.zshrc`, "../x", "../../etc/passwd",
    ".git/config", ".git/hooks/pre-commit", "work/.git/x",
    `${STORE}/.git/config`, `${STORE}/.git/hooks/post-commit`,
  ]) assert.ok(!dream("edit", p), `should block edit: ${p}`);
});

test("both agents: reads anywhere except secrets", () => {
  for (const agent of [dream, check]) {
    for (const p of ["/Users/u/work/app/app/main.py", "/etc/hosts", "work/projects/a/x.md", "/Users/u/work/app/.env.example"])
      assert.ok(agent("read", p), `should allow read: ${p}`);
    for (const p of [
      `${HOME}/.ssh/id_ed25519`, `${HOME}/.aws/credentials`, `${HOME}/.gnupg/secring.gpg`,
      `${HOME}/.netrc`, `${HOME}/.kube/config`, `${HOME}/.docker/config.json`,
      `${HOME}/Library/Keychains/login.keychain-db`, `${HOME}/.local/share/opencode/auth.json`,
      "/Users/u/work/app/.env", "/Users/u/work/app/.env.production",
    ]) assert.ok(!agent("read", p), `should block read: ${p}`);
  }
});

test("subagents: only the read-only checker, which cannot write or delegate", () => {
  assert.ok(dream("subagent", "memory-dream-check"));
  for (const name of ["general", "build", "fixer", "memory-dream"]) assert.ok(!dream("subagent", name), name);
  assert.ok(!check("edit", "work/projects/a/x.md"));
  assert.ok(!check("edit", `${STORE}/work/x.md`));
  assert.ok(!check("subagent", "memory-dream-check"));
  assert.ok(!check("shell", `git -C ${STORE} add x`));
  assert.ok(check("shell", "git -C /Users/u/work/app log -3"));
});

test("web is allowed, nothing unlisted is", () => {
  assert.ok(dream("webfetch", "https://example.com"));
  assert.ok(dream("websearch", "anything"));
  for (const action of ["execute", "skill", "todowrite", "question", "some_mcp_tool"])
    assert.ok(!dream(action, "*"), `should block action: ${action}`);
});
