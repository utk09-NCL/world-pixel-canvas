# Working rules for the local model

You run on a local 27B model with a limited context window and reply cap. Your thinking counts against the reply cap.

- **Write files in small steps.** Never write more than ~250 lines in one tool call. For a big file, create it with the skeleton first, then add to it with edits. Prefer several small modules (the `src/canvas/`, `src/realtime/` layout) over one big file.
- **Think briefly, then act.** Plan in a few lines. Don't draft the whole file in your reasoning before you write it.
- **Read only what you need.** Use grep/glob first, then read the relevant line ranges.
- **Delegate to keep your window small.** For a multi-file feature, hand each self-contained task to `code-writer`. It works in its own context and returns a short summary.
- **The stack is fixed:** React 19 + Vite + TypeScript, laid out as in AGENTS.md. Don't add a library or pick another structure: the `vite-app` skill
  has the templates.
- **Check after each change:** run `npm run check`. If you touched SQL, run `npm run db:reset`, then `npm run db:types`.
- **Screenshots:** for UI work, start `npm run dev` in the background, open `http://localhost:5173` with the chrome-devtools tools, and take a screenshot to check the result.
- Never run commands against the hosted Supabase project (`db push`, `link`, `--linked`) without asking the user. AGENTS.md has the full rules.
