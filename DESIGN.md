# DESIGN — Pantallas y flujos (mockup antes que código)

> Ninguna pantalla se codifica en firme hasta que el mockup fue aprobado.
> Orden de construcción de mockups = orden de esta lista.

---

## Principios UX

- Lenguaje del negocio, no de programador: "Lote", "Cliente", "Cuota", "Mora" —
  nunca "assignment_id" visible en pantalla.
- Todo estado se muestra con badge de color (activo/verde, mora/rojo,
  transferido/gris, etc.).
- Ninguna acción irreversible sin modal de confirmación explícito.
- El número de asignación (`-1`, `-2`) se muestra como "Historial de este lote"
  con un link, no como un dato críptico suelto.
- Reparto manual de pago entre lotes: primero se captura el pago a nivel de
  cliente (monto total, fecha, referencia — esto es lo que queda como
  trazabilidad del depósito). En un segundo paso del mismo flujo, el cobrador
  ve los lotes del cliente con su saldo pendiente al lado y escribe el monto
  a aplicar a cada uno. El sistema muestra en vivo "repartido: L.X de L.10,000"
  y no deja guardar hasta que cuadre exacto.
- Cargos (limpieza u otros) se ven como una línea de tiempo por asignación:
  activo desde [fecha] — suspendido desde [fecha] — reactivado desde [fecha]
  a L.[monto]. Nunca una casilla simple de "sí/no".

---

## Pantallas prioritarias (orden de mockup)

1. **Dashboard** — resumen: lotes activos/disponibles, clientes en mora, pagos
   del mes, alertas (asignaciones sin cargo de limpieza configurado, etc.)

2. **Ficha de cliente** — datos + tabs: Lotes actuales, Historial, Pagos,
   Notificaciones de mora enviadas.

3. **Ficha de lote** — datos del lote + línea de tiempo de asignaciones
   (dueño actual arriba, historial completo abajo con motivo de cierre de
   cada una — este es el reemplazo directo del patrón `-1`, `-2` del Excel).

4. **Registrar pago** — dos pasos: (a) captura el pago del cliente (monto
   total, fecha, método, referencia) — esto es lo que se guarda como el
   "pago" en sí; (b) si el cliente tiene 2+ lotes, reparto manual mostrando
   saldo pendiente de cada lote al lado y contador "repartido: L.X de
   L.total" que bloquea el guardado hasta cuadrar exacto. Si tiene 1 lote,
   el reparto se salta y aplica directo. Valida idempotencia (mismo
   monto+cliente+fecha+referencia ya existente → advertencia antes de
   duplicar).

5. **Recibo** — un recibo por pago (no uno por lote), con el desglose por
   lote impreso adentro si hubo reparto. Vista previa + botón exportar PDF +
   botón WhatsApp.

6. **Estado de cuenta** (cliente o lote específico) — reproduce el layout que
   ya usas en Excel (fecha, descripción, cargo, pago, saldo, mora) pero
   generado, no tecleado. Export Excel + PDF.

7. **Transferir/cerrar asignación** — flujo guiado: motivo (abandono
   voluntario / mora / transferencia) → si aplica, requiere escrito de mora
   ya generado antes de permitir cerrar por mora → calcula saldo final →
   si es transferencia, permite crear la nueva asignación heredando ese
   saldo en el mismo flujo.

8. **Escrito de mora** — selector de plantilla, vista previa PDF, botón
   WhatsApp con mensaje prellenado, queda registrado en el historial de la
   asignación con fecha y estado.

9. **Centro de importación** — 3 pasos visuales (subir → conciliar →
   confirmar), con la pantalla de conciliación lado a lado descrita en
   BLUEPRINT §7 como pieza central.

10. **Configuración** — tipos de cargo, plantillas de recibo/mora, catálogo
    de métodos de pago, datos del tenant. Desde la ficha de lote/asignación
    (no aquí) se suspende o reactiva un cargo puntual con su fecha y monto —
    eso es una acción operativa diaria, no configuración global.

11. **Reportes** — lista con filtros (fecha, cliente, lote, estado).

12. **Audit log** — solo lectura, filtros por entidad/usuario/fecha.

---

## Flujos principales a validar en mockup antes de codear

- Alta de cliente con 1 y con 2 lotes (dos mockups distintos, no asumir 1).
- Registrar pago con reparto manual entre 2 lotes.
- Cerrar asignación por abandono → generar escrito de mora → transferir a
  nuevo cliente con saldo heredado.
- Importar batch de prueba con al menos un caso de "sin match" para validar
  que la cola de revisión manual se entiende sin explicación.
