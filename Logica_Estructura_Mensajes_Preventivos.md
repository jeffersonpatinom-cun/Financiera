# Logica de Segmentacion y Comunicaciones Preventivas (CRM Zoho / WhatsApp / SMS)

Este documento explica la **lógica de negocio, nomenclatura y estructura de datos** definida en el documento de plantillas de cobro preventivo. Sirve como guía fundamental para el desarrollo del **Informe de Gestión**, permitiendo interpretar correctamente los reportes, métricas y automatizaciones del CRM.

---

## 1. Nomenclatura Estándar de Plantillas (Código Unificado)

Para la automatización e identificación en la base de datos y CRM, cada plantilla sigue una convención estricta:

$$\text{Código} = [\text{CANAL}]\_ [\text{POBLACIÓN}]\_ [\text{MOMENTO}]$$

* **Ejemplos:**
  * `WA_P1_PRE`: WhatsApp a Población Nuevo (P1), enviado 3 días antes del vencimiento.
  * `SMS_P3_M08`: SMS a Población Pagos Parciales (P3), enviado 8 días después del vencimiento.

---

## 2. Dimensiones de Clasificación de Datos

### A. Población / Segmentación (Variable `P`)
Determina el perfil del estudiante y la propuesta de valor/alerta en el mensaje:

| Código | Condición / Filtro en CRM | Descripción del Perfil | Enfoque de la Comunicación |
| :--- | :--- | :--- | :--- |
| **P1** | Campo `NUEVO` = "NUEVO" | Estudiantes nuevos con novedad de inicio / credenciales no activas | Aclarar que el pago se asocia al convenio *CLtiente Finance SAS / CTAYUDA*. |
| **P2** | Campo `ANTIGUO` = "ANTIGUO" | Estudiantes de reingreso o que pasan a segundo semestre | Continuidad académica y avance en ciclo propedéutico. |
| **P3** | Esquema de Pagos Parciales | Estudiantes bajo modalidad de cuotas parciales | Prevención de morosidad y evasión de reportes negativos en centrales de riesgo. |

---

### B. Momentos de Envío (Variable `M`)
Matriz temporal de disparo (*triggers*) según la fecha de vencimiento de la cuota:

| Código | Momento de Disparo | Tipo de Alerta |
| :--- | :--- | :--- |
| **PRE** | 3 días **antes** del vencimiento | Recordatorio preventivo / Cobro oportuno |
| **M01** | 1 día **después** del vencimiento | Alerta inicial de mora |
| **M03** | 3 días **después** del vencimiento | Seguimiento intermedio / Prevención de riesgos |
| **M08** | 8 días **después** del vencimiento | Recordatorio final / Cierre de gestión preventiva |

---

### C. Canales de Comunicación

* **WhatsApp (`WA`):** 
  * Permite mensajes de mayor extensión.
  * Incluye variables dinámicas: `[FechaVencimiento]` y `[FechaEnvio]`.
  * Redirección directa al canal de soporte de Cartera: `https://wa.me/573160260144` o PBX `6013078180 Opción 3`.
* **SMS (`SMS`):**
  * Mensajes comprimidos (límite estricto de **140 caracteres**).
  * Usa formato de fecha corta: `DD/MM`.
  * Enlace directo comprimido a WhatsApp para gestión inmediata.

---

## 3. Matriz Completa de Plantillas y Variables

| Canal | Código | Texto / Plantilla | Enlace / Canal Atendido |
| :--- | :--- | :--- | :--- |
| **WA** | `WA_P1_PRE` | Hola 👋 Te recordamos que tu saldo se vence el día [FechaVencimiento]... | wa.me/573160260144 |
| **WA** | `WA_P1_M01` | Identificamos que tu pago con fecha de vencimiento [FechaVencimiento] aún se encuentra pendiente. Enviado el [FechaEnvio]... | wa.me/573160260144 |
| **WA** | `WA_P1_M03` | Te informamos que tu pago con fecha de vencimiento [FechaVencimiento] continúa pendiente... | wa.me/573160260144 |
| **WA** | `WA_P1_M08` | Tu pago con fecha de vencimiento [FechaVencimiento] continúa pendiente a la fecha... | wa.me/573160260144 |
| **SMS** | `SMS_P1_PRE` | CUN: tu saldo vence DD/MM. El pago se asociara a tu novedad en convenio CLtiente Finance SAS... | wa.me/573160260144 |
| **SMS** | `SMS_P1_M01` | CUN: tu pago DD/MM sigue pendiente. Al pagar, se aplicara a tu novedad de CLtiene Finance SAS... | wa.me/573160260144 |
| **SMS** | `SMS_P1_M03` | CUN: tu pago DD/MM sigue pendiente. Al regularizarlo, se asociará a tu novedad del convenio... | wa.me/573160260144 |
| **SMS** | `SMS_P1_M08` | CUN: tu pago DD/MM continua pendiente. Evita retrasos y regulariza tu proceso... | wa.me/573160260144 |
| **WA** | `WA_P2_PRE` | Hola 👋 Te recordamos que tu saldo se vence el día [FechaVencimiento]. Te invitamos a realizar tu pago oportuno para continuar con tu 2° semestre... | wa.me/573160260144 |
| **WA** | `WA_P2_M01` | Identificamos que tu pago con fecha de vencimiento [FechaVencimiento] aún se encuentra pendiente... | wa.me/573160260144 |
| **WA** | `WA_P2_M03` | Te informamos que tu pago con fecha de vencimiento [FechaVencimiento] continúa pendiente... | wa.me/573160260144 |
| **WA** | `WA_P2_M08` | Tu pago con fecha de vencimiento [FechaVencimiento] continúa pendiente a la fecha... | wa.me/573160260144 |
| **SMS** | `SMS_P2_PRE` | CUN: tu saldo vence DD/MM. Continua tu 2° semestre y tu ciclo propedeutico con pago oportuno... | wa.me/573160260144 |
| **SMS** | `SMS_P2_M01` | CUN: tu pago DD/MM esta pendiente. Continúa tu 2° semestre sin contratiempos... | wa.me/573160260144 |
| **SMS** | `SMS_P2_M03` | CUN: tu cuota DD/MM sigue pendiente. Da continuidad a tu ciclo propedeutico... | wa.me/573160260144 |
| **SMS** | `SMS_P2_M08` | CUN: tu pago DD/MM continua pendiente. Regularizalo para avanzar en tu proceso academico... | wa.me/573160260144 |
| **WA** | `WA_P3_PRE` | Hola 👋 Te recordamos que tu saldo se vence el día [FechaVencimiento]. Como ya conoces tu esquema de pago parcial... | wa.me/573160260144 |
| **WA** | `WA_P3_M01` | Identificamos que tu pago con fecha de vencimiento [FechaVencimiento] aún se encuentra pendiente... | wa.me/573160260144 |
| **WA** | `WA_P3_M03` | Te informamos que tu pago con fecha de vencimiento [FechaVencimiento] continúa pendiente. Evita reportes en centrales... | wa.me/573160260144 |
| **WA** | `WA_P3_M08` | Tu pago con fecha de vencimiento [FechaVencimiento] continúa pendiente a la fecha... | wa.me/573160260144 |
| **SMS** | `SMS_P3_PRE` | CUN: tu cuota vence DD/MM. Da continuidad a tus pagos parciales... | wa.me/573160260144 |
| **SMS** | `SMS_P3_M01` | CUN: tu pago DD/MM esta pendiente. Continua tus pagos parciales y evita reportes negativos... | wa.me/573160260144 |
| **SMS** | `SMS_P3_M03` | CUN: tu cuota DD/MM sigue pendiente. Regularizala y evita afectaciones en tu historial... | wa.me/573160260144 |
| **SMS** | `SMS_P3_M08` | CUN: tu pago DD/MM continua pendiente. Evita reportes negativos y ponte al dia... | wa.me/573160260144 |

---

## 4. Utilidad Estratégica para el Informe de Gestión

Al redactar o analizar los indicadores del **Informe de Gestión**, esta estructura permite analizar:

1. **Efectividad por Canal:** Comparar la tasa de conversión / pago generado por impactos via `WA_*` vs. `SMS_*`.
2. **Efectividad por Momento:** Analizar el % de recaudo en etapa preventiva (`PRE`) frente a etapas de mora temprana (`M01`, `M03`) y mora tardía (`M08`).
3. **Comportamiento por Segmento:** Evaluar el nivel de riesgo y respuesta entre estudiantes Nuevos (`P1`), Antiguos (`P2`) y Financiados/Pagos Parciales (`P3`).
4. **Disparador de Tareas Telefónicas:** La nomenclatura técnica permite activar gestiones telefónicas automatizadas diferenciadas cuando el mensaje no logra la conversión en `M03` o `M08`.
