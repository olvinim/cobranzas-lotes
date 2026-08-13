import 'server-only'

/**
 * Cliente Supabase de SERVIDOR con `service_role` key.
 *
 * ⚠️ SOLO SERVIDOR. `import 'server-only'` hace que el build falle si este
 * módulo se importa desde un componente cliente — la `service_role` key
 * NUNCA debe llegar al navegador.
 *
 * La `service_role` key BYPASEA RLS. Por eso, aunque RLS es la primera
 * línea de defensa, cada query hecha con este cliente DEBE incluir el
 * filtro explícito por `tenant_id` (candado doble, regla #6 de CLAUDE.md).
 * Usar este cliente solo para operaciones de servidor que lo justifiquen
 * (migraciones, jobs, endpoints administrativos), no como atajo para
 * saltarse RLS en operaciones normales.
 */
import { createClient } from '@supabase/supabase-js'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!supabaseUrl || !serviceRoleKey) {
  throw new Error(
    'Faltan NEXT_PUBLIC_SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY en .env.local'
  )
}

export const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
})
