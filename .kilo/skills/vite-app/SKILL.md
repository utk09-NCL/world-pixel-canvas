---
name: vite-app
description: React 19 + Vite 8 + TypeScript 7 conventions for World Pixels - project layout, components, hooks, the store that bridges React and the canvas engine, CSS Modules, env variables, tsconfig and lint rules, dev server, build, screenshots. Use for any file in src/ (especially .tsx), vite.config.ts, tsconfig, package.json, index.html, import.meta.env, and for type-check, lint or build errors.
---

# React app (Vite 8 + React 19 + TypeScript 7)

The project is scaffolded and installed. **Never run create-vite again** (its `--overwrite` deletes AGENTS.md and `.kilo/`) and never add a
dependency without asking the user. Checked 2026-11-08: Vite 8.3, React 19.3, TypeScript 7.0, oxlint 1.x, supabase-js 2.119.

## Who owns what

| Thing | Owner | Where |
| - | - | - |
| Pixels, chunks, `seq`, viewport, pointer/wheel input, drawing | plain TS | `src/canvas/` |
| Sign-in, channel, snapshot, resync, `place_pixel`, cooldown timer | plain TS | `src/realtime/` |
| Starting and stopping all of the above | plain TS | `src/engine.ts`: `startWorld(canvas) -> stop()` |
| Selected color, status, notice, cooldown seconds | `src/store.ts` | read by both sides |
| Palette, status bar, setup banner, the `<canvas>` element | React | `src/components/` |

Plain TS files never `import` from `react`. Components never call `supabase` and never touch pixels.

## Files and naming

- One component per file in `src/components/`, named export, file name = component name: `Palette.tsx` exports `Palette`.
- Its styles: `Palette.module.css` in the same folder, imported as `styles`. Class names in camelCase (`styles.swatch`).
- Hooks: `src/hooks/useXxx.ts`, one hook per file.
- A component file exports only components (oxlint `only-export-components`, needed for Fast Refresh). Constants go in `config.ts`.
- Relative imports include the extension (`'./Palette.tsx'`, `'../store.ts'`). Type-only imports use `import type` or an inline `type`.

## Templates (copy these shapes)

`src/store.ts`: the only shared state. Each `setState` makes a new object, which is what `useSyncExternalStore` needs to see a change.

```ts
export type Status = 'connecting' | 'live' | 'busy' | 'offline'

export type AppState = {
  selectedColor: number // palette index
  status: Status
  notice: string | null // one-line message for StatusBar, e.g. a mapped place_pixel error
  cooldownLeft: number // whole seconds until the next pixel; 0 = ready. Written by the engine.
}

let state: AppState = { selectedColor: 1, status: 'connecting', notice: null, cooldownLeft: 0 }
const listeners = new Set<() => void>()

export function getState(): AppState {
  return state
}

export function setState(patch: Partial<AppState>): void {
  state = { ...state, ...patch }
  listeners.forEach((listener) => listener())
}

export function subscribe(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
```

`src/hooks/useAppState.ts`:

```ts
import { useSyncExternalStore } from 'react'
import { getState, subscribe, type AppState } from '../store.ts'

export function useAppState(): AppState {
  return useSyncExternalStore(subscribe, getState)
}
```

`src/supabase.ts`: the client is created on first use, never at import time. `createClient` throws without a URL, which would blank the page
instead of showing the setup banner.

```ts
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import type { Database } from './database.types.ts'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY

export const missingEnv: string[] = [!url && 'VITE_SUPABASE_URL', !key && 'VITE_SUPABASE_PUBLISHABLE_KEY'].filter((name) => typeof name === 'string')

let client: SupabaseClient<Database> | undefined

export function getSupabase(): SupabaseClient<Database> {
  client ??= createClient<Database>(url, key)
  return client
}
```

`src/App.tsx`:

```tsx
import { CanvasView } from './components/CanvasView.tsx'
import { Palette } from './components/Palette.tsx'
import { SetupBanner } from './components/SetupBanner.tsx'
import { StatusBar } from './components/StatusBar.tsx'
import { missingEnv } from './supabase.ts'

export function App() {
  if (missingEnv.length > 0) return <SetupBanner missing={missingEnv} />
  return (
    <>
      <CanvasView />
      <Palette />
      <StatusBar />
    </>
  )
}
```

`src/components/CanvasView.tsx`: the **only** place the engine starts. The empty dependency array is correct: the ref object never changes.

```tsx
import { useEffect, useRef } from 'react'
import { startWorld } from '../engine.ts'
import styles from './CanvasView.module.css'

export function CanvasView() {
  const ref = useRef<HTMLCanvasElement>(null)
  useEffect(() => startWorld(ref.current!), []) // returns stop(); StrictMode runs start, stop, start in dev
  return <canvas ref={ref} className={styles.canvas} />
}
```

```css
/* CanvasView.module.css */
.canvas {
  display: block;
  width: 100%;
  height: 100%;
  touch-action: none; /* pointer events get pinch and pan, not the browser */
  image-rendering: pixelated;
}
```

`src/components/Palette.tsx`: reads with `useAppState()`, writes with `setState()`. Real `<button>`s for keyboard and screen-reader access.

```tsx
import { PALETTE } from '../config.ts'
import { useAppState } from '../hooks/useAppState.ts'
import { setState } from '../store.ts'
import styles from './Palette.module.css'

export function Palette() {
  const { selectedColor } = useAppState()
  return (
    <div className={styles.palette} role="toolbar" aria-label="Colors">
      {PALETTE.map((hex, i) => (
        <button
          key={hex}
          type="button"
          className={styles.swatch}
          style={{ background: hex }}
          aria-label={`Color ${i + 1}`}
          aria-pressed={i === selectedColor}
          onClick={() => setState({ selectedColor: i })}
        />
      ))}
    </div>
  )
}
```

Props: a `type <Name>Props = { ... }` above the component, destructured in the signature with default values there:
`export function SetupBanner({ missing }: SetupBannerProps)`.

## React 19 rules

- Function components and hooks only. No class components, no `forwardRef` (`ref` is a normal prop), no `defaultProps`, no `propTypes`, no
  `import React` (the JSX runtime is automatic: `"jsx": "react-jsx"`).
- Not in v1, because there is no async React data: `use()`, Suspense, `lazy`, Actions, `<form action>`, `useActionState`, `useOptimistic`,
  `useTransition`. Optimistic paint is done by the engine in plain TS, not by `useOptimistic`.
- Effects only sync with something outside React (the engine). Every effect that starts something returns its cleanup. Don't call `setState`
  synchronously in an effect (oxlint warns): derive the value during render instead.
- Hooks run unconditionally at the top of the component (`rules-of-hooks`). Dependency arrays list everything used (`exhaustive-deps`). Both are
  lint **errors**.
- Timers live in the engine. React only renders `cooldownLeft`: no `setInterval` in components.
- List keys are stable values from the data (`hex`), never `Math.random()`.

## TypeScript (tsconfig.app.json)

- Strict is TS 7's default. Never weaken it, and never add `// @ts-ignore` or `any` to silence an error: fix the type.
- `erasableSyntaxOnly`: no `enum`, `namespace` or constructor parameter properties. Use `as const` objects and union types.
- `verbatimModuleSyntax`: type-only imports must be marked `type`.
- `noUnusedLocals` / `noUnusedParameters`: delete dead code, or prefix an unused parameter with `_`.
- CSS Module imports and `import.meta.env` are typed by `vite/client` and `src/env.d.ts`.

## Env variables

- In `.env.local` (gitignored). `.env.local.example` lists them. Only `VITE_*` variables reach the browser, and they are **public**: never put a
  secret or service-role key in one.
- `src/env.d.ts` declares every variable with `strictImportMetaEnv`, so a misspelled name is a type error. A new variable goes in `env.d.ts` and in
  `.env.local.example`.
- Vite reads env files at startup: restart `npm run dev` after changing them.

## Check, run, see

- `npm run check` (`tsc -b` + oxlint) after every change. `npm run build` before calling a feature done.
- `npm run dev` serves http://localhost:5173 and fails if the port is taken (`strictPort`). `npm run dev -- --host` also serves on the LAN, for a phone
  on the same Wi-Fi.
- To see a UI change: run `npm run dev` in the background, open http://localhost:5173 with the chrome-devtools tools, and take a screenshot.

## Gotchas

- `<StrictMode>` mounts, unmounts and remounts in dev. If `stop()` misses the channel (`supabase.removeChannel`), every event arrives twice.
- React's `onWheel` is passive, so `preventDefault()` is ignored and the page zooms. Wheel and pointer listeners are attached natively in
  `src/canvas/input.ts` with `{ passive: false }`.
- `useSyncExternalStore` compares snapshots by identity: `getState()` must return the same object until `setState` runs. Never build a new object
  inside `getState`.
- Updating the store on every broadcast re-renders every component that uses `useAppState`. Write to the store only when a UI value changes (e.g.
  the cooldown second, not every frame).
