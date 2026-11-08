// Writes the context length LM Studio has actually loaded into `limit.context` in .kilo/kilo.jsonc,
// so LM Studio is the one place you change it.
//
//   node .kilo/sync-lmstudio.mjs        (re-run after you change "Context Length" in LM Studio)
//
// Why a script and not a .env file: Kilo 7.8.27 rejects {env:...} in a project config, and {file:...} only yields a string, while
// `limit.context` must be a number (both tested). Only the numbers change; comments and formatting are kept.
import { readFileSync, writeFileSync } from "node:fs";

const FILE = new URL("./kilo.jsonc", import.meta.url);
const text = readFileSync(FILE, "utf8");

// Same length as `text` but with comments blanked out, so matches never land in a comment and indexes still point into `text`.
const code = text.replace(/("(?:\\.|[^"\\])*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (m, str) => str ?? m.replace(/[^\n]/g, " "));

// Index of the `}` that closes the `{` at `open`, skipping braces inside strings.
function closeOf(open) {
  for (let i = open, depth = 0, inStr = false; i < code.length; i++) {
    const c = code[i];
    if (inStr) {
      if (c === "\\") i++;
      else if (c === '"') inStr = false;
    } else if (c === '"') inStr = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) return i;
  }
  throw new Error(`Unbalanced braces in kilo.jsonc after index ${open}`);
}

const baseURL = code.match(/"baseURL"\s*:\s*"([^"]+)"/)?.[1];
if (!baseURL) throw new Error("No baseURL in .kilo/kilo.jsonc");
const api = new URL("/api/v1/models", baseURL);

let models;
try {
  ({ models } = await (await fetch(api, { signal: AbortSignal.timeout(5000) })).json());
} catch (err) {
  console.error(`Cannot reach LM Studio at ${api} (${err.cause?.code ?? err.message}).`);
  console.error("Check: the server is running with 'Serve on Local Network', and the app running this script has macOS Local Network permission.");
  process.exit(1);
}

const edits = [];
for (const m of models) {
  if (m.type !== "llm") continue; // embeddings etc. are never Kilo chat models
  const decl = new RegExp(`"${m.key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"\\s*:\\s*\\{`).exec(code);
  const loaded = m.loaded_instances.map((i) => i.config.context_length);
  if (!decl) {
    if (loaded.length) console.log(`${m.key}: loaded in LM Studio but not declared in kilo.jsonc (skipped)`);
    continue;
  }
  const open = decl.index + decl[0].length - 1;
  const block = code.slice(open, closeOf(open));
  const ctx = /"context"\s*:\s*(\d+)/.exec(block);
  const out = /"output"\s*:\s*(\d+)/.exec(block);
  if (!ctx) {
    console.log(`${m.key}: no limit.context in kilo.jsonc (skipped)`);
    continue;
  }
  const current = Number(ctx[1]);
  if (!loaded.length) {
    console.log(`${m.key}: not loaded in LM Studio, left at ${current}`);
    continue;
  }
  const next = Math.min(...loaded); // several instances: the smallest window is the safe one
  const compactsAt = out ? ` | Kilo compacts at ~${Math.round((next - Number(out[1])) / 1000)}k (context - output)` : "";
  console.log(`${m.key}: context ${current === next ? `${next} (unchanged)` : `${current} -> ${next}`}${compactsAt}`);
  if (current !== next) {
    const at = open + ctx.index + ctx[0].length - ctx[1].length;
    edits.push({ at, len: ctx[1].length, value: String(next) });
  }
}

if (!edits.length) process.exit(0);
let result = text;
for (const e of edits.sort((a, b) => b.at - a.at)) result = result.slice(0, e.at) + e.value + result.slice(e.at + e.len);
writeFileSync(FILE, result);
console.log(`Updated .kilo/kilo.jsonc (${edits.length} model${edits.length > 1 ? "s" : ""}).`);
