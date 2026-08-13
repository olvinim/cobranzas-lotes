# CLAUDE.md — Sistema de Cobranza de Lotes (Portales del Bosque)

Este archivo es la instrucción operativa para Claude Code en este proyecto.
Lee primero BLUEPRINT.md (qué se construye) y DESIGN.md (pantallas), en ese
orden, antes de escribir código en cualquier sesión nueva.

> **Este proyecto es completamente independiente de ResidencialPay.**
> Claude Code no tiene acceso al código, esquema, ni historial de ese otro
> proyecto — son bases de datos y repositorios separados. Cualquier mención
> a "lecciones de ResidencialPay" en este documento ya está traducida a
> reglas explícitas y autosuficientes aquí mismo; no se debe asumir,
> inferir, ni buscar nada de un proyecto externo que no está en este
> directorio.

Olvin no es programador. Trabaja con metodología vibe coding: Claude genera
prompts/mockups/specs → Claude Code ejecuta → Olvin reporta resultados de
vuelta. Disciplina estricta de una tarea por prompt, sin avanzar de fase sin
checklist confirmado.

---

## Stack

Next.js 14 + Supabase + Vercel + Claude Code. n8n para automatizaciones si
aplica más adelante. Mismo stack que ResidencialPay por preferencia de Olvin,
pero proyecto, repositorio, base de datos Supabase y despliegue en Vercel
completamente separados — sin nada compartido entre ambos.

**Sin Prisma ni otro ORM.** Cliente de base de datos: `supabase-js` directo,
con tipos generados vía `supabase gen types typescript` desde el esquema
real. Migraciones: archivos SQL versionados con el CLI de Supabase,
revisados antes de correr (regla #2 de arriba) — una sola fuente de verdad
del esquema, no dos sistemas de migración en paralelo.

---

## Reglas no negociables (resumen operativo — detalle en BLUEPRINT.md §5)

1. **Mockup primero, código después.** Ninguna pantalla nueva se codifica sin
   mockup aprobado por Olvin.
2. **SQL siempre revisado antes de correr.** Verificar el esquema real con
   SELECT antes de escribir cualquier migración — nunca asumir estructura
   desde el código.
3. **Diagnóstico separado de implementación.** Antes de tocar algo sensible:
   preguntar cómo está hoy, esperar respuesta, diseñar, después codificar.
4. **Una cosa a la vez.** Si una tarea chica revela un problema más grande,
   se reporta y se para — no se sigue implementando sin aprobación explícita.
5. **Lo contable no se borra, se anula con trazabilidad.** Clientes y lotes no
   se borran, se desactivan.
6. **RLS + filtro explícito por `tenant_id`** en cada query, siempre doble.
7. **Audit log con un solo helper de escritura**, insert en su propio bloque
   (nunca dentro del try/catch de la operación principal).
8. **Idempotencia y atomicidad en pagos** — `idempotency_key` obligatorio,
   transacción de base de datos para pago + saldo + recibo + audit log juntos.
9. **Reparto de pago entre lotes es manual**, nunca automático (confirmado
   con el negocio — ver BLUEPRINT.md §2).
10. **No hardcodear** tipos de cargo, estados de lote/cliente/asignación,
    métodos de pago, ni plantillas de mensajes — todo vive en configuración.
11. **Cambio visual y cambio de lógica/dinero, en commits separados siempre**,
    aunque toquen el mismo archivo.
12. **Verificar cero referencias antes de borrar código**, y borrarlo en su
    propio commit, nunca mezclado con un cambio funcional.

---

## Fases (no avanzar sin checklist confirmado por Olvin)

### Fase 1 — Setup y esquema base
- Proyecto Supabase nuevo (separado de ResidencialPay).
- Tablas de BLUEPRINT.md §4: `tenants`, `clientes`, `lotes`,
  `lot_assignments`, `charge_types`, `cargos_aplicados`, `cargo_vigencias`,
  `payments`, `payment_allocations`, `saldo_periodos`, `recibos`,
  `notificaciones_mora`, `audit_logs`, `import_batches`, `import_rows`.
- RLS básico por `tenant_id` en cada tabla.
- **Checklist de salida**: esquema revisado por Olvin, un SELECT de prueba por
  tabla confirmando estructura real antes de seguir.

### Fase 2 — Mockups (DESIGN.md, pantallas 1-8)
- Mockups de las pantallas núcleo: dashboard, ficha cliente, ficha lote,
  registrar pago (con reparto manual), recibo, estado de cuenta, transferir/
  cerrar asignación, escrito de mora.
- **Checklist de salida**: cada mockup aprobado explícitamente por Olvin,
  incluyendo el flujo de reparto de pago con 2 lotes.

### Fase 3 — CRUD núcleo (clientes, lotes, asignaciones)
- Alta/edición/desactivación de clientes y lotes.
- Crear asignación, cerrar asignación (abandono/transferencia/completada).
- **Checklist de salida**: probado con datos de prueba, no datos reales
  todavía.

### Fase 4 — Motor de pagos y saldo
- Registrar pago (monto total + fecha a nivel cliente) con idempotencia +
  atomicidad, luego reparto manual a `payment_allocations` con validación
  dura de que la suma cuadre exacto contra el total.
- Cargos con historial de vigencia (`cargo_vigencias`): probar explícitamente
  suspender un cargo activo y reactivarlo con otro monto, y confirmar que
  los meses suspendidos NO generan cargo en `saldo_periodos`.
- Motor de saldo/mora: algoritmo FIFO explícito, escrito completo en
  BLUEPRINT.md §6 (no requiere ni asume nada de otro proyecto).
- Generación de recibo único por pago (no por lote), con desglose interno.
- **Checklist de salida**: caso de prueba más seguro primero (pago que no
  mueve mora), después caso real con mora, comparando saldos "antes/después"
  al centavo. Incluir un caso de prueba con cargo suspendido a mitad de
  período para confirmar que el cálculo mensual no lo cuenta esos meses.

### Fase 5 — Migración desde Excel
- Importador Etapa 1 (clientes/lotes/asignaciones).
- Importador Etapa 2 (pagos, filtrando `ID ≠ "Otro"`, cruce por cédula+lote).
- Pantalla de conciliación (Etapa 3) con cola de revisión manual.
- **Checklist de salida**: batch de prueba con al menos un caso "sin match"
  validado manualmente antes de correr el batch real completo. Capturar
  saldos "antes" del archivo Excel real para comparar después.

### Fase 6 — Estados de cuenta, exportación y escritos de mora
- Estado de cuenta por cliente/lote, export Excel + PDF.
- Escrito de mora: plantilla, PDF, botón WhatsApp (`wa.me`).
- **Checklist de salida**: PDF revisado visualmente contra el formato actual
  de Excel que Olvin ya usa, para que el negocio reconozca el documento.

### Fase 7 — Reportes y roles
- Reportes de BLUEPRINT.md §9.
- Roles: Admin, Manager, Cobrador, Auditor con RLS + UI espejando la misma
  fuente de verdad de permisos.
- **Checklist de salida**: probar que un Cobrador NO puede anular un pago.

### Fase 8 — Migración de datos reales y cierre
- Correr migración real con el Excel de producción.
- Validación de saldos finales al centavo contra el Excel actual.
- **Checklist de salida**: aprobación explícita de Olvin sobre los saldos
  migrados antes de considerar el sistema fuente de verdad.

### Fase 9 — Importación mensual recurrente de estado de cuenta bancario
- Parser del `.xls` mensual del banco (BLUEPRINT.md §7-bis), filtro de ruido
  bancario por palabra clave, match automático solo cuando el nombre está
  presente en la descripción, idempotencia por `Número de referencia`.
- Reutiliza la pantalla de conciliación de Fase 5, no se construye una nueva.
- **Checklist de salida**: probar con el archivo real de julio 2026 (o el mes
  disponible más reciente), confirmar que el ruido bancario se excluye
  correcto, que los 2 depósitos con nombre identificable proponen el cliente
  correcto, y que subir el mismo archivo dos veces no duplica ningún pago.

---

## Convenciones

- Nombres de tabla y campo en español, snake_case (mantiene el vocabulario
  del negocio — igual que ResidencialPay).
- Toda fecha se guarda en UTC, se muestra en huso horario de Honduras con un
  helper central de fechas — nunca `toLocaleDateString` sin huso explícito.
- Todo commit de cambio financiero/lógica llega acompañado de captura de
  pantalla de saldos antes/después cuando aplica a datos reales.
