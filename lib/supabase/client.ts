/**
 * Cliente Supabase para el NAVEGADOR (componentes cliente).
 *
 * Usa la `anon key` (clave pública). Toda seguridad depende de RLS +
 * filtro explícito por `tenant_id` en cada query (regla no negociable #6
 * de CLAUDE.md). Nunca se usa la `service_role` key aquí.
 *
 * NOTA: el tipo `Database` se generará con
 *   supabase gen types typescript --project-id <id> > lib/supabase/database.types.ts
 * una vez aplicada la migración de Fase 1. Mientras tanto el cliente queda
 * sin genérico de tipos (any) — se conecta después.
 */
import { createClient } from '@supabase/supabase-js'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'Faltan NEXT_PUBLIC_SUPABASE_URL o NEXT_PUBLIC_SUPABASE_ANON_KEY en .env.local'
  )
}

export const supabaseBrowser = createClient(supabaseUrl, supabaseAnonKey)
