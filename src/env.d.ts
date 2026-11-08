// Types for import.meta.env. `strictImportMetaEnv` makes a misspelled or undeclared VITE_ variable a type error.
// Add every new VITE_ variable here and to .env.local.example.
interface ViteTypeOptions {
  strictImportMetaEnv: unknown
}

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string
  readonly VITE_SUPABASE_PUBLISHABLE_KEY: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
