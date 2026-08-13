-- ============================================================================
-- 0001_esquema_base.sql
-- Fase 1 — Esquema base del Sistema de Cobranza de Lotes (Portales del Bosque)
-- ----------------------------------------------------------------------------
-- ESTE ARCHIVO NO SE HA EJECUTADO. Es para revisión de Olvin antes de correr.
--
-- Fuente de verdad de columnas/tipos/FK: BLUEPRINT.md §4.
-- Reglas de seguridad (RLS + tenant_id, no borrar lo contable, etc.): CLAUDE.md.
--
-- Convenciones aplicadas (BLUEPRINT §4):
--   * Toda tabla con dato de tenant lleva `tenant_id`.
--   * Toda tabla financiera lleva anulado / anulado_por / fecha_anulacion /
--     motivo_anulacion (se ANULA, nunca se borra — regla #5 CLAUDE.md).
--   * Toda tabla lleva created_at / updated_at / created_by.
--
-- Notas de tipos:
--   * `id` = uuid con gen_random_uuid() (núcleo de Postgres 13+, no requiere
--     extensión). Supabase corre PG15.
--   * Montos en Lempiras: numeric(14,2) (exacto, sin errores de flotante).
--   * Fechas de calendario del negocio = `date`; marcas de tiempo = timestamptz
--     (se guardan en UTC, se muestran en huso de Honduras en la app — CLAUDE.md).
--
-- La migración va envuelta en una sola transacción (BEGIN/COMMIT): si algo
-- falla, NO queda a medias — o se crea todo, o no se crea nada.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- GUARDA PREVIA (implementa "verificar contra information_schema antes de crear")
-- ----------------------------------------------------------------------------
-- Antes de crear una sola tabla, revisamos information_schema. Si CUALQUIERA de
-- las 15 tablas objetivo ya existe en el esquema `public`, abortamos con un
-- error claro en vez de pisar o duplicar algo. Esto también protege contra
-- correr el archivo dos veces por error.
do $$
declare
  v_existentes text;
begin
  select string_agg(table_name, ', ' order by table_name)
    into v_existentes
  from information_schema.tables
  where table_schema = 'public'
    and table_name in (
      'tenants','clientes','lotes','lot_assignments','charge_types',
      'cargos_aplicados','cargo_vigencias','payments','payment_allocations',
      'saldo_periodos','recibos','notificaciones_mora','audit_logs',
      'import_batches','import_rows'
    );

  if v_existentes is not null then
    raise exception
      'Abortado: estas tablas ya existen en public y no se van a recrear: %',
      v_existentes;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- FUNCIONES AUXILIARES
-- ----------------------------------------------------------------------------

-- current_tenant_id(): devuelve el tenant al que pertenece el usuario logueado,
-- leído del JWT de Supabase Auth (app_metadata.tenant_id). Es el corazón del
-- "candado de base de datos" de RLS: las políticas de abajo comparan el
-- tenant_id de cada fila contra ESTE valor. El tenant_id se graba como claim en
-- app_metadata al aprovisionar cada usuario (se cablea en la Fase de roles).
-- Mientras no haya claim, devuelve NULL y las políticas no dejan ver nada — eso
-- es intencional: por defecto, cerrado.
create or replace function public.current_tenant_id()
returns uuid
language sql
stable
as $$
  select nullif(auth.jwt() -> 'app_metadata' ->> 'tenant_id', '')::uuid
$$;

-- set_updated_at(): mantiene updated_at = now() en cada UPDATE, sin depender de
-- que la app se acuerde de setearlo. Se engancha como trigger en cada tabla que
-- tiene updated_at.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ============================================================================
-- 1. tenants  (la organización dueña de los datos; hoy solo "Portales del Bosque")
-- ============================================================================
-- No lleva tenant_id: ESTA tabla ES el tenant. Es la raíz a la que apuntan
-- todas las demás.
create table public.tenants (
  id                uuid primary key default gen_random_uuid(),
  nombre            text not null,
  moneda            text not null default 'HNL',           -- solo Lempiras hoy (BLUEPRINT §2)
  tasa_interes_mora numeric(6,4),                           -- nullable/0 hoy; el motor de saldo SIEMPRE lo consulta (BLUEPRINT §2, §6)
  config_json       jsonb not null default '{}'::jsonb,     -- parámetros flexibles del tenant sin migrar esquema

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  -- created_by referencia al usuario de Supabase Auth que creó el registro.
  -- ON DELETE SET NULL: si se elimina esa cuenta, el tenant NO se borra ni se
  -- rompe; solo se pierde el rastro del autor.
  created_by        uuid references auth.users(id) on delete set null
);
comment on table public.tenants is 'Organización dueña de los datos (multitenant). Hoy: Portales del Bosque.';

-- ============================================================================
-- 2. clientes
-- ============================================================================
create table public.clientes (
  id             uuid primary key default gen_random_uuid(),
  -- tenant_id NOT NULL + FK a tenants: cada cliente pertenece a un tenant.
  -- ON DELETE RESTRICT: no se puede borrar un tenant que todavía tiene clientes
  -- (protege el histórico; nada contable se borra en cascada).
  tenant_id      uuid not null references public.tenants(id) on delete restrict,
  nombre_completo text not null,
  identidad      text,                                   -- cédula; identificador FUERTE para la migración (BLUEPRINT §4)
  telefono       text,
  whatsapp       text,
  direccion      text,
  estado         text not null default 'activo'
                   check (estado in ('activo','inactivo','archivado')),  -- el cliente no se borra, se desactiva (regla #5)
  notas          text,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null
);
-- La cédula debe ser única DENTRO de un tenant (no global: dos tenants podrían
-- tener la misma persona). Índice parcial: solo aplica cuando hay cédula, porque
-- algunos clientes migrados podrían no traerla.
create unique index uq_clientes_identidad
  on public.clientes (tenant_id, identidad)
  where identidad is not null;

-- ============================================================================
-- 3. lotes
-- ============================================================================
-- Un lote físico = un registro. El historial de dueños vive en lot_assignments,
-- NO se duplica el lote por cada dueño (BLUEPRINT §4).
create table public.lotes (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete restrict,  -- mismo candado que clientes
  proyecto       text,
  sector_manzana text,                                    -- BLUEPRINT lo escribe como "sector/manzana"
  numero_lote    text not null,                           -- ej. "A14"
  area           numeric(12,2),
  estado         text not null default 'disponible'
                   check (estado in ('disponible','asignado','pagado','inactivo','archivado')),  -- el lote no se borra, se desactiva
  notas          text,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null
);
-- El número de lote es único dentro del tenant (no puede haber dos "A14" en el
-- mismo tenant).
create unique index uq_lotes_numero
  on public.lotes (tenant_id, numero_lote);

-- ============================================================================
-- 4. lot_assignments  (la relación cliente↔lote a lo largo del tiempo)
-- ============================================================================
create table public.lot_assignments (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete restrict,
  -- cliente_id / lote_id: quién tiene qué lote. RESTRICT porque una asignación
  -- es un hecho contable: no se borra el cliente ni el lote si tienen historial.
  cliente_id        uuid not null references public.clientes(id) on delete restrict,
  lote_id           uuid not null references public.lotes(id)    on delete restrict,
  numero_asignacion int not null,                         -- 1,2,3... = el sufijo -1,-2 del Excel (BLUEPRINT §4)
  fecha_inicio      date not null,
  fecha_fin         date,                                 -- null = asignación abierta
  estado            text not null default 'activa'
                      check (estado in ('activa','completada','transferida','abandonada','cancelada')),
  tipo_plan         text not null
                      check (tipo_plan in ('financiado','contado')),
  costo_total       numeric(14,2) not null,
  prima             numeric(14,2) not null default 0,
  cuota_mensual     numeric(14,2),                        -- null si es de contado
  plazo_meses       int,                                  -- null si es de contado
  -- saldo_apertura: se hereda de la asignación anterior en una transferencia.
  -- Puede ser POSITIVO (deuda heredada) o NEGATIVO (excedente a favor) — BLUEPRINT §2.
  saldo_apertura    numeric(14,2) not null default 0,
  motivo_cierre     text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null,
  approved_by       uuid references auth.users(id) on delete set null,  -- quién aprobó (transferencias, etc.)

  -- Integridad: si hay fecha_fin, no puede ser anterior a la fecha_inicio.
  constraint ck_lot_assignments_rango
    check (fecha_fin is null or fecha_fin >= fecha_inicio)
);
-- Regla dura de BLUEPRINT §4: un lote NO puede tener dos asignaciones 'activa' a
-- la vez. Índice único parcial: solo permite UNA fila con estado 'activa' por
-- lote (las cerradas no cuentan).
create unique index uq_lot_assignments_una_activa
  on public.lot_assignments (lote_id)
  where estado = 'activa';
-- El correlativo -1, -2, ... es único por lote (mantiene reconocible el patrón
-- del Excel: A14-1, A14-2).
create unique index uq_lot_assignments_numero
  on public.lot_assignments (lote_id, numero_asignacion);

-- ============================================================================
-- 5. charge_types  (catálogo configurable de tipos de cargo, por tenant)
-- ============================================================================
-- Existe para NO hardcodear los tipos de cargo en el código (regla #10 CLAUDE.md).
create table public.charge_types (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete restrict,
  nombre            text not null,
  tipo_calculo      text not null
                      check (tipo_calculo in ('fijo','porcentaje','manual')),
  categoria_contable text,
  activo            boolean not null default true,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null
);
create unique index uq_charge_types_nombre
  on public.charge_types (tenant_id, nombre);

-- ============================================================================
-- 6. cargos_aplicados  (qué tipo de cargo aplica a una asignación)
-- ============================================================================
-- Guarda el HECHO "esta asignación tiene cargo de limpieza", sin monto ni fecha
-- — esos viven en cargo_vigencias, porque un mismo cargo se prende y apaga
-- varias veces con montos distintos (BLUEPRINT §4).
create table public.cargos_aplicados (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete restrict,
  -- FK a la asignación y al tipo de cargo. RESTRICT: no se borra la asignación
  -- ni el tipo de cargo mientras exista este vínculo.
  lot_assignment_id uuid not null references public.lot_assignments(id) on delete restrict,
  charge_type_id    uuid not null references public.charge_types(id)    on delete restrict,
  recurrente        boolean not null default true,
  notas             text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null
);
-- Un tipo de cargo se aplica UNA vez por asignación; su historial de prendido/
-- apagado vive en cargo_vigencias, no en filas repetidas aquí.
create unique index uq_cargos_aplicados_unico
  on public.cargos_aplicados (lot_assignment_id, charge_type_id);

-- ============================================================================
-- 7. cargo_vigencias  (cuándo estuvo activo un cargo y a qué monto)
-- ============================================================================
-- Un cargo se SUSPENDE cerrando su vigencia actual (poniendo fecha_fin), nunca
-- editando ni borrando la fila. Se REACTIVA creando una fila nueva (incluso con
-- otro monto). Así queda el período exacto en que sí se cobró (BLUEPRINT §4).
create table public.cargo_vigencias (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete restrict,
  -- RESTRICT: no se borra el cargo aplicado si tiene historial de vigencias.
  cargo_aplicado_id uuid not null references public.cargos_aplicados(id) on delete restrict,
  monto             numeric(14,2) not null,
  fecha_inicio      date not null,
  fecha_fin         date,                                 -- null = sigue vigente
  motivo            text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null,

  -- Integridad: si hay fecha_fin, no puede ser anterior al inicio de la vigencia.
  constraint ck_cargo_vigencias_rango
    check (fecha_fin is null or fecha_fin >= fecha_inicio)
);

-- ============================================================================
-- 8. payments  (el pago a NIVEL de cliente — TABLA FINANCIERA)
-- ============================================================================
-- monto_total da la trazabilidad del depósito: "el cliente pagó L.10,000 el
-- 15-jun", sin importar a cuántos lotes se reparta después (BLUEPRINT §2, §4).
create table public.payments (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete restrict,
  -- El pago es del cliente. RESTRICT: jamás se borra un cliente con pagos.
  cliente_id       uuid not null references public.clientes(id) on delete restrict,
  fecha_pago       date not null,                         -- fecha real del depósito (calendario del negocio)
  fecha_registro   timestamptz not null default now(),    -- cuándo se capturó en el sistema
  monto_total      numeric(14,2) not null check (monto_total > 0),
  metodo_pago      text not null,                         -- valor del catálogo de métodos (no se hardcodea en UI — regla #10)
  referencia       text,                                  -- referencia bancaria / "Número de referencia" (idempotencia de Fase 9)
  idempotency_key  text not null,                         -- obligatorio (regla #8): evita registrar el mismo pago dos veces
  numero_recibo    bigint,                                -- correlativo por tenant; UNO por payment (se asigna al registrar, Fase 4)
  origen           text not null default 'manual'
                     check (origen in ('manual','migrado')),
  estado           text not null default 'registrado'
                     check (estado in ('registrado','anulado')),

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid references auth.users(id) on delete set null,

  -- Campos de anulación (tabla financiera: se ANULA con trazabilidad, no se borra).
  anulado          boolean not null default false,
  anulado_por      uuid references auth.users(id) on delete set null,
  fecha_anulacion  timestamptz,
  motivo_anulacion text
);
-- Candado DURO de idempotencia (regla #8): la misma (tenant, idempotency_key) no
-- puede insertarse dos veces. Es la garantía a nivel base de datos, no solo app.
create unique index uq_payments_idempotency
  on public.payments (tenant_id, idempotency_key);
-- El correlativo de recibo es único por tenant cuando ya está asignado.
create unique index uq_payments_numero_recibo
  on public.payments (tenant_id, numero_recibo)
  where numero_recibo is not null;

-- ============================================================================
-- 9. payment_allocations  (reparto MANUAL del pago entre lotes del cliente)
-- ============================================================================
-- Un payment con 2 lotes = 2 filas aquí, con montos definidos a mano por el
-- cobrador (NUNCA calculados por el sistema — regla #9). BLUEPRINT §4.
create table public.payment_allocations (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete restrict,
  -- RESTRICT: no se borra un pago que ya tiene reparto; no se borra la asignación
  -- que recibió dinero.
  payment_id        uuid not null references public.payments(id)        on delete restrict,
  lot_assignment_id uuid not null references public.lot_assignments(id) on delete restrict,
  monto_aplicado    numeric(14,2) not null check (monto_aplicado > 0),

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null
);
-- Un pago reparte a lo sumo UNA línea por lote (no dos filas al mismo lote).
create unique index uq_payment_allocations_unico
  on public.payment_allocations (payment_id, lot_assignment_id);
-- NOTA IMPORTANTE: la regla "SUM(monto_aplicado) = payments.monto_total" es una
-- validación entre FILAS que NO se puede expresar como un CHECK de columna. Se
-- garantiza en la transacción de registro de pago (Fase 4), como validación dura
-- antes de confirmar (BLUEPRINT §4, regla #8).

-- ============================================================================
-- 10. saldo_periodos  (motor de saldo/mora, un registro por asignación por mes)
-- ============================================================================
create table public.saldo_periodos (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete restrict,
  lot_assignment_id uuid not null references public.lot_assignments(id) on delete restrict,
  periodo           date not null,                        -- el mes (se usa el día 1 del mes)
  cargo_periodo     numeric(14,2) not null default 0,     -- cuota + cargos vigentes ese mes
  pagado_periodo    numeric(14,2) not null default 0,
  saldo_acumulado   numeric(14,2) not null default 0,
  mora_acumulada    numeric(14,2) not null default 0,
  meses_mora        int not null default 0,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null
);
-- Un solo registro por asignación y mes.
create unique index uq_saldo_periodos_mes
  on public.saldo_periodos (lot_assignment_id, periodo);
-- NOTA: el "saldo_pendiente" del período que menciona el algoritmo FIFO
-- (BLUEPRINT §6) se deriva como (cargo_periodo - pagado_periodo). No es una
-- columna nueva porque §4 no la lista; el motor de la Fase 4 mantiene estos
-- valores.

-- ============================================================================
-- 11. recibos  (TABLA FINANCIERA — un recibo por payment)
-- ============================================================================
create table public.recibos (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete restrict,
  -- RESTRICT: el recibo cuelga del pago; no se borra el pago con recibo emitido.
  payment_id       uuid not null references public.payments(id) on delete restrict,
  numero_recibo    bigint not null,                       -- espeja payments.numero_recibo (el correlativo del tenant)
  pdf_url          text,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid references auth.users(id) on delete set null,

  -- Anulación (tabla financiera).
  anulado          boolean not null default false,
  anulado_por      uuid references auth.users(id) on delete set null,
  fecha_anulacion  timestamptz,
  motivo_anulacion text
);
-- UNO por payment (BLUEPRINT §4): un pago no puede tener dos recibos.
create unique index uq_recibos_payment
  on public.recibos (payment_id);
-- El correlativo de recibo es único por tenant.
create unique index uq_recibos_numero
  on public.recibos (tenant_id, numero_recibo);

-- ============================================================================
-- 12. notificaciones_mora  (el "escrito de mora")
-- ============================================================================
-- Requisito antes de poder cerrar una asignación como abandonada (BLUEPRINT §2).
create table public.notificaciones_mora (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete restrict,
  lot_assignment_id uuid not null references public.lot_assignments(id) on delete restrict,
  fecha_generado    timestamptz not null default now(),
  pdf_url           text,
  estado            text not null default 'borrador'
                      check (estado in ('borrador','enviada')),
  enviado_por       uuid references auth.users(id) on delete set null,
  fecha_envio       timestamptz,
  notas             text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null
);

-- ============================================================================
-- 13. audit_logs  (bitácora inmutable; un solo helper de escritura — regla #7)
-- ============================================================================
create table public.audit_logs (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete restrict,
  -- usuario_id: quién hizo la acción. SET NULL para conservar la bitácora aunque
  -- se elimine la cuenta.
  usuario_id     uuid references auth.users(id) on delete set null,
  accion         text not null,                           -- ej. 'anular_pago', 'crear_asignacion'
  entidad        text not null,                           -- nombre lógico de la entidad afectada
  -- entidad_id es POLIMÓRFICO (puede apuntar a un cliente, pago, lote...). Por
  -- eso NO lleva FK: no puede referenciar una sola tabla.
  entidad_id     uuid,
  valor_anterior jsonb,                                   -- estado antes del cambio
  valor_nuevo    jsonb,                                   -- estado después
  motivo         text,
  -- 'momento' = el campo que BLUEPRINT §4 llama `timestamp`. Se renombró porque
  -- TIMESTAMP es palabra reservada de Postgres y obligaría a citar el nombre en
  -- cada query. (Desviación menor, señalada para revisión.)
  momento        timestamptz not null default now(),
  ip             inet                                     -- tipo nativo de IP (valida el formato)
);
-- No lleva updated_at ni triggers: la bitácora es de solo-agregar; nunca se
-- edita ni se borra (reforzado abajo: RLS permite SELECT e INSERT, no UPDATE ni
-- DELETE).

-- ============================================================================
-- 14. import_batches  (un lote de importación de Excel)
-- ============================================================================
create table public.import_batches (
  id                  uuid primary key default gen_random_uuid(),  -- BLUEPRINT lo llama batch_id
  tenant_id           uuid not null references public.tenants(id) on delete restrict,
  tipo                text not null
                        check (tipo in ('clientes','lotes','pagos')),
  archivo_original_ref text,
  -- Ciclo sugerido: pendiente → conciliando → confirmado / revertido. No se pone
  -- CHECK porque BLUEPRINT §4 no fija la lista cerrada de estados del batch.
  estado              text not null default 'pendiente',
  filas_totales       int not null default 0,
  filas_ok            int not null default 0,
  filas_error         int not null default 0,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid references auth.users(id) on delete set null
);

-- ============================================================================
-- 15. import_rows  (cada fila cruda del Excel dentro de un batch)
-- ============================================================================
create table public.import_rows (
  id                uuid primary key default gen_random_uuid(),  -- BLUEPRINT lo llama row_id
  -- tenant_id NO está listado explícito en §4, pero se agrega para el candado
  -- RLS por tenant_id (regla #6), derivado del batch. (Adición menor, señalada.)
  tenant_id         uuid not null references public.tenants(id) on delete restrict,
  -- batch_id: la fila pertenece a un batch. CASCADE (a diferencia del resto):
  -- los datos de importación son de PREPARACIÓN, con rollback disponible mientras
  -- no se confirmen (BLUEPRINT §7); si se descarta el batch, sus filas se van con
  -- él. Todavía no son datos contables.
  batch_id          uuid not null references public.import_batches(id) on delete cascade,
  fila_excel_json   jsonb not null,                       -- la fila original tal cual (nunca se pierde el dato de origen)
  match_status      text not null default 'sin_match'
                      check (match_status in ('auto','manual','sin_match')),
  -- entidad_destino_id es POLIMÓRFICO (cliente, lote o pago según el tipo de
  -- batch). Por eso NO lleva FK.
  entidad_destino_id uuid,
  revisado_por      uuid references auth.users(id) on delete set null,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null
);

-- ============================================================================
-- TRIGGERS updated_at  (todas las tablas con updated_at; audit_logs se excluye)
-- ============================================================================
create trigger trg_tenants_updated_at            before update on public.tenants             for each row execute function public.set_updated_at();
create trigger trg_clientes_updated_at           before update on public.clientes            for each row execute function public.set_updated_at();
create trigger trg_lotes_updated_at              before update on public.lotes               for each row execute function public.set_updated_at();
create trigger trg_lot_assignments_updated_at    before update on public.lot_assignments     for each row execute function public.set_updated_at();
create trigger trg_charge_types_updated_at       before update on public.charge_types        for each row execute function public.set_updated_at();
create trigger trg_cargos_aplicados_updated_at   before update on public.cargos_aplicados    for each row execute function public.set_updated_at();
create trigger trg_cargo_vigencias_updated_at    before update on public.cargo_vigencias     for each row execute function public.set_updated_at();
create trigger trg_payments_updated_at           before update on public.payments            for each row execute function public.set_updated_at();
create trigger trg_payment_allocations_updated_at before update on public.payment_allocations for each row execute function public.set_updated_at();
create trigger trg_saldo_periodos_updated_at     before update on public.saldo_periodos      for each row execute function public.set_updated_at();
create trigger trg_recibos_updated_at            before update on public.recibos             for each row execute function public.set_updated_at();
create trigger trg_notificaciones_mora_updated_at before update on public.notificaciones_mora for each row execute function public.set_updated_at();
create trigger trg_import_batches_updated_at     before update on public.import_batches       for each row execute function public.set_updated_at();
create trigger trg_import_rows_updated_at        before update on public.import_rows          for each row execute function public.set_updated_at();

-- ============================================================================
-- RLS — Row Level Security  (candado de base de datos, regla #6)
-- ----------------------------------------------------------------------------
-- POR QUÉ: la app filtra por tenant_id en cada query, pero eso es UN solo
-- candado (si hay un bug en el código, se cae). RLS es el SEGUNDO candado, en la
-- base de datos misma: aunque alguien use la clave pública (anon) del navegador,
-- no puede leer ni escribir filas de otro tenant.
--
-- CÓMO: en cada tabla habilitamos RLS y creamos una política que solo deja
-- operar a usuarios AUTENTICADOS (rol `authenticated`) sobre filas cuyo
-- tenant_id coincide con current_tenant_id() (el tenant del JWT del usuario).
--   * USING  = qué filas puede VER/afectar.
--   * WITH CHECK = qué filas puede INSERTAR/dejar tras un UPDATE (no puede
--     "mover" una fila a otro tenant).
--
-- La clave anon (navegador) no es `authenticated` hasta que el usuario inicia
-- sesión → sin login, no ve nada. La clave service_role (usada solo en el
-- servidor, lib/supabase/server.ts) BYPASEA RLS por diseño; por eso el código
-- de servidor DEBE igual filtrar por tenant_id (candado doble, regla #6).
-- ============================================================================

-- tenants: caso especial, no tiene columna tenant_id (su propio id ES el tenant).
alter table public.tenants enable row level security;
create policy tenants_rls on public.tenants
  for all to authenticated
  using      (id = public.current_tenant_id())
  with check (id = public.current_tenant_id());

-- Macro conceptual para el resto: misma política "tenant_id = current_tenant_id()".
alter table public.clientes enable row level security;
create policy clientes_rls on public.clientes
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.lotes enable row level security;
create policy lotes_rls on public.lotes
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.lot_assignments enable row level security;
create policy lot_assignments_rls on public.lot_assignments
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.charge_types enable row level security;
create policy charge_types_rls on public.charge_types
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.cargos_aplicados enable row level security;
create policy cargos_aplicados_rls on public.cargos_aplicados
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.cargo_vigencias enable row level security;
create policy cargo_vigencias_rls on public.cargo_vigencias
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.payments enable row level security;
create policy payments_rls on public.payments
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.payment_allocations enable row level security;
create policy payment_allocations_rls on public.payment_allocations
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.saldo_periodos enable row level security;
create policy saldo_periodos_rls on public.saldo_periodos
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.recibos enable row level security;
create policy recibos_rls on public.recibos
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.notificaciones_mora enable row level security;
create policy notificaciones_mora_rls on public.notificaciones_mora
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

-- audit_logs: INMUTABLE. Se separan las políticas para permitir SELECT e INSERT
-- pero NO UPDATE ni DELETE (no hay política para esas dos → quedan prohibidas
-- para roles no-service). Refuerza "la bitácora no se altera".
alter table public.audit_logs enable row level security;
create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (tenant_id = public.current_tenant_id());
create policy audit_logs_insert on public.audit_logs
  for insert to authenticated
  with check (tenant_id = public.current_tenant_id());

alter table public.import_batches enable row level security;
create policy import_batches_rls on public.import_batches
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

alter table public.import_rows enable row level security;
create policy import_rows_rls on public.import_rows
  for all to authenticated
  using (tenant_id = public.current_tenant_id())
  with check (tenant_id = public.current_tenant_id());

commit;

-- ============================================================================
-- FIN 0001_esquema_base.sql
-- ============================================================================
