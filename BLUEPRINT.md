# BLUEPRINT — Sistema de Cobranza de Lotes (Portales del Bosque)

> Documento de especificación funcional y de datos. Se lee ANTES de tocar código.
> Complementa a CLAUDE.md (metodología) y DESIGN.md (pantallas/mockups).

---

## 1. Resumen ejecutivo

Sistema para reemplazar el control actual en Excel (estados de cuenta por cliente +
base de clientes + libro bancario) de venta de lotes a plazos de Portales del Bosque.
Multitenant desde el diseño de base de datos, pero con un solo tenant activo
(Portales del Bosque) por ahora — mismo patrón que se usó en ResidencialPay.

No cobra intereses hoy, pero el motor de saldo/mora se diseña parametrizado desde
el día uno para que activarlo en un tenant futuro sea un cambio de configuración,
no una reescritura del cálculo.

---

## 2. Supuestos y decisiones confirmadas con el dueño del negocio

- **Tenant único por ahora**: Portales del Bosque. Modelo de datos preparado para
  más tenants a futuro, pero sin selector de tenant expuesto en la UI todavía.
- **Moneda**: Lempiras (HNL) únicamente.
- **Intereses**: desactivados para este tenant. Campo `tasa_interes_mora` existe en
  configuración del tenant, default `NULL`/`0`. El cálculo de saldo SIEMPRE consulta
  ese campo, aunque hoy sea cero.
- **Cargos adicionales**: se aplican por lote (o por asignación, ver §4). Si un
  cliente tiene 2 lotes, el cargo se duplica porque existe en cada asignación,
  configurable de forma independiente.
- **Reparto de pagos entre múltiples lotes de un mismo cliente**: el pago se
  registra UNA vez a nivel de cliente — monto total y fecha — para que la
  trazabilidad del depósito quede clara ("el cliente pagó L.10,000 el
  15-jun"). El cobrador decide DESPUÉS, en el mismo flujo, cómo se reparte
  internamente ese total entre los lotes del cliente (`payment_allocations`).
  NUNCA reparto automático entre lotes. El sistema valida que la suma de las
  asignaciones sea igual al monto total antes de guardar. El recibo generado
  es UNO SOLO por el pago total, con el desglose por lote impreso adentro.
  **Dentro de cada lote**, una vez que le llegó su monto, ese dinero SÍ se
  aplica automático con lógica FIFO al período impago más antiguo primero —
  eso no es una decisión del cobrador, es cálculo del sistema (algoritmo
  completo en §6). Son dos capas distintas: reparto entre lotes = manual;
  aplicación dentro de un lote a través del tiempo = automático y FIFO.
- **Abandono de lote con saldo pendiente**: el saldo se conserva como deuda
  histórica visible (nunca se condona automáticamente). Requiere primero un
  "escrito de mora" antes de poder cerrar la asignación como abandonada.
- **Transferencia de lote**: cierra la asignación actual con su saldo final
  (positivo=deuda, cero, o negativo=excedente a favor) y ese saldo se hereda como
  saldo de apertura de la nueva asignación. Todo queda enlazado y auditado.
- **WhatsApp**: fase 1 = generar PDF + botón que abre WhatsApp (`wa.me`) con
  mensaje prellenado; el envío del adjunto es manual (Olvin ya tiene número y
  Business Manager propios, no se integra API oficial todavía). Fase 2 posible:
  API oficial si el volumen lo justifica.
- **Migración de banco (una sola vez, histórico)**: los ~4 clientes de
  `base clientes` sin match en el libro bancario NO se asumen como pagados en
  efectivo ni se descartan — pasan a una cola de revisión manual en la
  pantalla de conciliación antes de importar.
- **Importación recurrente del estado de cuenta bancario mensual (hacia
  adelante)**: además de la migración inicial de histórico, el banco entrega
  cada mes un archivo de movimientos (`.xls`) con número de referencia propio
  por transacción. Se reutiliza el mismo patrón de cola de revisión: nunca se
  crea un `payment` directo desde el archivo. Detalle completo en §7-bis.

---

## 3. Alcance MVP vs. Fase 2

### MVP (lo que se construye primero)
- Clientes, lotes, asignaciones con historial completo.
- Registro de pagos con idempotencia + atomicidad, reparto manual a lotes.
- Motor de saldo/mora (adaptado del ya construido en ResidencialPay).
- Cargos configurables (cuota, limpieza, ajustes), con fecha de vigencia propia.
- Recibos con numeración correlativa por tenant, PDF.
- Estado de cuenta por cliente/lote/asignación, export Excel + PDF.
- Escrito de mora: generación de PDF + botón WhatsApp.
- Migración guiada desde Excel (3 etapas, ver §7).
- Roles: Admin, Manager/Supervisor, Cobrador, Auditor (sin portal de cliente todavía).
- Audit log con helper único de escritura.

### Fase 2 (explícitamente pospuesto)
- 2FA, portal de cliente, envío WhatsApp vía API oficial, motor de reglas de
  penalización configurable, exposición real de multitenant en UI, reportes
  avanzados adicionales a los ya listados.

---

## 4. Modelo de datos (tablas clave)

Convención: toda tabla con dato de tenant lleva `tenant_id`; toda tabla financiera
lleva `anulado / anulado_por / fecha_anulacion / motivo_anulacion`; toda tabla
lleva `created_at / updated_at / created_by`.

### `tenants`
`id, nombre, moneda (HNL), tasa_interes_mora (nullable, default null), config_json`

### `clientes`
`id, tenant_id, nombre_completo, identidad (cédula), telefono, whatsapp,
direccion, estado (activo/inactivo/archivado), notas, created_at`
- Nunca se borra si tiene historial. Se desactiva.
- `identidad` es el identificador fuerte para migración (más confiable que nombre).

### `lotes`
`id, tenant_id, proyecto, sector/manzana, numero_lote (ej. "A14"), area,
estado (disponible/asignado/pagado/inactivo/archivado), notas`
- Un lote físico = un registro. El historial de dueños vive en `lot_assignments`,
  no se duplica el lote por cada dueño.

### `lot_assignments`
`id, tenant_id, cliente_id, lote_id, numero_asignacion (1,2,3... equivalente al
sufijo -1,-2 del Excel), fecha_inicio, fecha_fin (nullable),
estado (activa/completada/transferida/abandonada/cancelada),
tipo_plan (financiado/contado),
costo_total, prima, cuota_mensual (nullable si contado), plazo_meses (nullable),
saldo_apertura (hereda de asignación anterior si es transferencia; puede ser
  positivo=deuda heredada o negativo=excedente a favor),
motivo_cierre (nullable), created_by, approved_by (nullable)`
- Regla: un lote no puede tener dos asignaciones `activa` simultáneas.
- `numero_asignacion` es lo que en el Excel se ve como el sufijo `B07-1`, `B07-2`:
  se muestra en UI para que el patrón siga siendo reconocible para el negocio.

### `cargos_aplicados` (qué tipo de cargo aplica a una asignación)
`id, tenant_id, lot_assignment_id, charge_type_id, recurrente (bool), notas`
- Representa el hecho "esta asignación tiene cargo de limpieza", sin fecha ni
  monto — esos viven en `cargo_vigencias` porque un mismo cargo puede
  prenderse y apagarse varias veces con montos distintos cada vez.

### `cargo_vigencias` (historial de cuándo estuvo activo un cargo y a qué monto)
`id, tenant_id, cargo_aplicado_id, monto, fecha_inicio, fecha_fin (nullable =
sigue vigente), motivo, created_by, created_at`
- Un cargo se **suspende cerrando su vigencia actual** (`fecha_fin`), nunca
  editando o borrando la fila — así queda registrado el período exacto en que
  sí se cobró. Se **reactiva creando una nueva fila** de vigencia, incluso con
  un monto distinto si cambió la tarifa.
- Ej. real del Excel: limpieza de L.100 con `fecha_inicio` = jun-2024 aunque
  el contrato es de jul-2022 (no se cobró desde el inicio). Si más adelante se
  suspende la limpieza por 3 meses y luego se retoma a L.150, eso son DOS
  filas adicionales en esta tabla, no una edición de la original.
- El motor de saldo (§6), al calcular el cargo de un período, revisa qué
  `cargo_vigencias` cubren ese mes (`fecha_inicio ≤ mes ≤ fecha_fin` o
  `fecha_fin IS NULL`) y suma sus montos — nunca asume que un cargo aplicado
  está activo todo el tiempo.

### `charge_types` (catálogo configurable, por tenant)
`id, tenant_id, nombre, tipo_calculo (fijo/porcentaje/manual), categoria_contable,
activo`

### `payments`
`id, tenant_id, cliente_id, fecha_pago, fecha_registro, monto_total,
metodo_pago, referencia, idempotency_key, numero_recibo (correlativo por tenant,
UNO por payment sin importar cuántos lotes reciban parte del dinero),
origen (manual/migrado), estado (registrado/anulado), created_by,
anulado, anulado_por, fecha_anulacion, motivo_anulacion`
- `monto_total` es lo que da trazabilidad al nivel del cliente: "cliente pagó
  L.10,000 el 15-jun", independiente de a cuántos lotes se aplicó.

### `payment_allocations`
`id, tenant_id, payment_id, lot_assignment_id, monto_aplicado`
- Un `payment` con 2 lotes = 2 filas aquí, con montos definidos manualmente por
  el cobrador (nunca calculados automáticamente por el sistema).
- Regla de guardado: `SUM(payment_allocations.monto_aplicado) WHERE payment_id = X`
  debe ser exactamente igual a `payments.monto_total` — validación dura antes
  de confirmar, no advertencia opcional.

### `saldo_periodos` (motor de mora, adaptado de ResidencialPay)
`id, tenant_id, lot_assignment_id, periodo (mes), cargo_periodo, pagado_periodo,
saldo_acumulado, mora_acumulada, meses_mora`
- Reutiliza la lógica FIFO + mora ya construida y auditada en ResidencialPay.
  No se reinventa el algoritmo, se adapta el dominio.

### `recibos`
`id, tenant_id, payment_id, numero_recibo, pdf_url, anulado, anulado_por,
fecha_anulacion, motivo_anulacion`

### `notificaciones_mora`
`id, tenant_id, lot_assignment_id, fecha_generado, pdf_url, estado (borrador/
enviada), enviado_por, fecha_envio, notas`
- El "escrito de mora" antes de poder cerrar una asignación como abandonada.

### `import_batches` / `import_rows`
`batch_id, tenant_id, tipo (clientes/lotes/pagos), archivo_original_ref,
estado, filas_totales, filas_ok, filas_error, created_by`
`row_id, batch_id, fila_excel_json, match_status (auto/manual/sin_match),
entidad_destino_id (nullable), revisado_por (nullable)`

### `audit_logs`
`id, tenant_id, usuario_id, accion, entidad, entidad_id, valor_anterior,
valor_nuevo, motivo, timestamp, ip`
- Un solo helper de escritura en todo el código (regla no negociable, ver §5).

---

## 5. Reglas de negocio no negociables

(Heredadas de la auditoría de ResidencialPay — se listan cortas aquí, el
detalle completo con el "porqué" vive en el documento de principios que ya
compartiste; CLAUDE.md las referencia en cada fase.)

1. Lo contable no se borra, se anula con trazabilidad y correlativo intacto.
2. Clientes y lotes no se borran, se desactivan.
3. Todo insert de audit log va en su propio bloque, nunca dentro del mismo
   try/catch que la operación principal — falla ruidoso en dev, silencioso pero
   registrado en producción.
4. RLS + filtro explícito por `tenant_id` en cada query, doble candado.
5. El cobrador que registra un pago no lo anula él mismo (excepción documentada
   solo para Admin).
6. Antes de habilitar cualquier "corrección", verificar si ya existe un camino
   legítimo (transferencia de lote en vez de "borrar y crear cliente nuevo").
7. Al filtrar "excluir anulados" en cualquier reporte, verificar también el
   saldo de apertura heredado — no solo el período visible.
8. SQL de migración siempre revisado antes de correr; esquema real verificado
   con SELECT antes de escribir cualquier script de importación.

---

## 6. Motor de saldo y mora — algoritmo FIFO explícito

El pago se aplica siempre **al período impago más antiguo primero** (FIFO:
first in, first out). Regla de cálculo autosuficiente en este documento —
no depende de ningún sistema externo ni de otro proyecto.

**Paso a paso, por cada asignación (`lot_assignment`):**

1. Cada mes, en la fecha de corte, se genera un registro en `saldo_periodos`
   con `cargo_periodo` = suma de cuota + cargos vigentes ese mes (según
   `cargo_vigencias`, ver §4). Nace con `saldo_pendiente = cargo_periodo`.
2. Cuando llega dinero a esa asignación (un `monto_aplicado` de
   `payment_allocations`), se consume en este orden:
   - Se busca el período **más antiguo** con `saldo_pendiente > 0`.
   - Se le resta el monto disponible hasta cubrirlo completo (`saldo_pendiente
     = 0`) o hasta agotar el monto, lo que ocurra primero.
   - Si sobra dinero después de cubrir ese período, el sobrante pasa
     automáticamente al **siguiente período más antiguo** con saldo
     pendiente, y se repite el mismo paso.
   - Si el monto alcanza y sobra después de cubrir TODOS los períodos
     vencidos existentes, el excedente queda como crédito a favor del
     cliente, que se aplica automáticamente al primer `cargo_periodo` que se
     genere después (nunca se pierde ni se devuelve solo).
3. `mora_acumulada` de la asignación = suma de `saldo_pendiente` de todos los
   períodos cuya fecha de vencimiento ya pasó.
4. `meses_mora` = cantidad de períodos distintos con `saldo_pendiente > 0` y
   fecha ya vencida.

**Ejemplo con datos reales** (caso Jose Abdón, lote A14): cuota L.2,500/mes.
En oct-2022 no paga (queda `saldo_pendiente = 2,500` en ese período). En
dic-2022 paga L.5,000: primero cubre el período de oct-2022 pendiente
(L.2,500), y el resto (L.2,500) cubre dic-2022 — nunca se aplica el pago de
dic directamente a dic mientras oct siga impago. Esto es exactamente lo que
refleja la columna MORA del Excel actual (vuelve a 0 cuando el atraso se
cubre en orden).

Este algoritmo usa el campo `tasa_interes_mora` del tenant (§2) al calcular
`cargo_periodo` para el tenant futuro que sí cobre interés — hoy vale 0/NULL
para Portales del Bosque, así que el resultado es idéntico a "sin interés"
sin que el algoritmo cambie, solo el dato de configuración.

---

## 7. Migración desde Excel — 3 etapas

**Etapa 1 — Clientes, lotes y asignaciones** desde `base clientes`.
Cada fila = una asignación. El sufijo del lote (`B07-1`, `B07-2`) se traduce a
`numero_asignacion` correlativo por lote. Estado `ELIMINADO` del Excel se
traduce internamente a `abandonada` o `transferida` según corresponda —
sin perder el dato original en `import_rows.fila_excel_json`.

**Etapa 2 — Pagos históricos** desde `estado cta banco pagos`.
- Filtrar `ID ≠ "Otro"` (excluye ~453 filas de movimiento bancario puro:
  intereses del banco, comisiones, retiros — no son pagos de clientes).
- Cruzar por cédula + número de lote contra lo importado en Etapa 1.
- Todo lo que cruce automático con confianza alta pasa a revisión rápida.
- Todo lo que NO cruce (incluye los clientes sin historial bancario detectado)
  cae en cola de revisión manual — se decide caso por caso en pantalla, nunca
  se asume.

**Etapa 3 — Conciliación y confirmación**
Pantalla lado a lado: fila original del Excel ↔ destino propuesto en el
sistema. Nada se guarda en firme hasta que Olvin confirma el batch completo.
Import batch queda con `rollback` disponible mientras no se hayan registrado
operaciones nuevas sobre esos datos.

---

## 7-bis. Importación mensual recurrente del estado de cuenta bancario

A diferencia de §7 (migración de histórico, una sola vez), esta es una
herramienta operativa de uso mensual continuo, para el archivo `.xls` que el
banco entrega con los movimientos del mes (formato confirmado con archivo
real de julio 2026: columnas `Fecha, Descripción, Número de referencia,
N° Cheque, Débito, Crédito, Balance`).

**Hallazgo clave del archivo real** (no asumido, verificado): de los
movimientos tipo depósito (`Crédito > 0`), solo los que vienen como
`Transferencia entre Cuentas-NOMBRE-...` traen el nombre del cliente en la
descripción — porque el banco lo captura solo en transferencias entre
cuentas propias. Los depósitos en efectivo (`Deposito de Efectivo-`) y en
corresponsal (`Deposito en Corresponsal TENGO`) llegan **sin ningún dato del
cliente** — limitación del banco, no del sistema. En el archivo de prueba,
esto fue 2 de 11 depósitos identificables automáticamente y 9 sin identificar.

**Flujo:**

1. Subir el `.xls` mensual.
2. El sistema descarta automático las filas de ruido bancario conocido por
   palabra clave en `Descripción`: `Impuesto sobre Interes`, `Tasa de
   Seguridad Poblacional`, `Credito por Intereses`, `Retiro de Efectivo`, y
   cualquier fila con `Débito > 0` que no sea un ruido reconocido se marca
   aparte como "egreso, no es cobro" para revisión informativa — nunca se
   mete en la cola de pagos.
3. Depósitos (`Crédito > 0`) con nombre identificable en la descripción →
   propuesta de pago con cliente sugerido (fuzzy match contra
   `clientes.nombre_completo`), monto, fecha y `Número de referencia`
   prellenados.
4. Depósitos sin nombre identificable → propuesta de pago con monto, fecha y
   referencia prellenados, pero cliente vacío — se completa con un buscador
   manual, igual que hoy pero sin retranscribir el resto del dato.
5. **Idempotencia real**: `Número de referencia` del banco se guarda en
   `payments.referencia`. Si ese número ya existe en el sistema (archivo
   subido dos veces, meses traslapados), la fila se marca automático como
   duplicado y se excluye de la cola — nunca se crea un segundo pago.
6. Todo pasa por la misma pantalla de conciliación de §7 (reutilizada, no
   una pantalla nueva). Nada se convierte en `payment` real sin confirmación
   explícita de Olvin, fila por fila o en lote si ya revisó todas.
7. Una vez confirmado un pago, sigue el flujo normal ya definido: reparto
   manual a lote(s) si el cliente tiene más de uno (§2), luego aplicación
   FIFO automática dentro de cada lote (§6).

**Lo que esto SÍ resuelve**: elimina la retranscripción manual de fecha,
monto y referencia, y elimina el riesgo de contar el mismo depósito dos
veces.
**Lo que esto NO resuelve**: quién hizo un depósito en efectivo sin nombre
— ese dato no existe en el archivo del banco, así que identificar al
cliente sigue siendo una decisión humana, igual que hoy.

---

## 8. Roles (MVP)

1. **Admin** (Olvin): todo, incluye anular pagos y aprobar transferencias.
2. **Manager/Supervisor**: aprueba correcciones, gestiona asignaciones y
   escritos de mora.
3. **Cobrador**: registra pagos, genera recibos, ve estados de cuenta. No anula.
4. **Auditor**: solo lectura, incluye audit log completo.

---

## 9. Reportes mínimos MVP

Estado de cuenta por cliente/lote, clientes activos/inactivos, lotes
disponibles/asignados, pagos por rango de fecha, pagos por cobrador, mora
actual por asignación, historial de asignaciones por lote, reporte de
migración (batch), audit log.
