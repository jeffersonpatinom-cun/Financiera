---
name: generar-ticket-gestion
description: Redactar un ticket de gestion para el Formulario de requerimientos de analitica de la CUN. Usar cuando pidan generar/crear/redactar un ticket, registrar la gestion realizada, documentar un requerimiento, o pasar un trabajo tecnico al formulario de analitica. Produce maximo 100 palabras, tono profesional, sin detalle tecnico.
---

# Ticket de gestión

Destino: **Formulario de requerimientos de analítica** (Zoho Forms). Lo lee un
coordinador de área, no un ingeniero.

La regla que define este ticket: **describir qué se hizo y para qué sirve, sin
cómo está construido.** El "qué" sí lleva su categoría —se creó un procedimiento
almacenado, un script, un ajuste al tablero— pero ahí se detiene. Nada de nombres
de objetos, columnas, tipos de dato ni códigos de error.

**Máximo 100 palabras.** Es un tope duro, y se cuenta mal a ojo: usar el validador.

## Validar antes de entregar

```bash
.venv/Scripts/python.exe .claude/skills/generar-ticket-gestion/validar.py borrador.txt
```

También por stdin, y con nombres de negocio adicionales permitidos:

```bash
echo "Se ajusto el tablero Recaudo_Diario para incorporar la nueva clasificacion de gestion aprobada por la Coordinacion de Cartera, de modo que el equipo de asesores pueda priorizar su trabajo diario segun el nivel de riesgo real de cada deudor y no unicamente por el monto de la deuda pendiente." | .venv/Scripts/python.exe .claude/skills/generar-ticket-gestion/validar.py - --permitir Recaudo_Diario
```

```
Palabras: 49 / 100

OK: dentro del limite, sin jerga tecnica y con accion explicita.
```

Sale con código 1 si no pasa. Revisa tres cosas: el tope de palabras, la jerga
técnica, y que haya un verbo de acción explícito.

## Estructura

Tres bloques cortos, en este orden:

1. **Qué se hizo y sobre qué** — una frase. Incluye la categoría del trabajo
   (procedimiento almacenado, script, ajuste al tablero, documento) y quién lo
   aprobó, si aplica.
2. **En qué cambia la operación** — el antes y el después, en términos de lo que
   el área va a ver o poder hacer. Es el bloque que justifica el ticket.
3. **Impacto o resultado** — una cifra concreta y los adjuntos.

## Campos del formulario

| Campo | Qué poner |
|---|---|
| Correo solicitante | El institucional de quien ejecuta |
| Dirigido a | El coordinador que aprobó o solicitó |
| Categoría | Desarrollo / Ajuste de proceso de datos |
| Subcategoría | Según el trabajo: procedimiento almacenado, script, informe, tablero |
| Vicerrectoría | Financiera |
| Área que solicita | La que pidió el trabajo (Cartera, Comercial…) |
| Descripción | Los tres bloques de arriba |
| Carga de archivos | El documento de soporte, si existe |

Categoría, Subcategoría, Vicerrectoría y Área son listas desplegables. Si la
opción sugerida no existe tal cual, pedir las opciones disponibles antes de
inventar una.

## Ejemplos verificados

Ambos pasan el validador. Sirven de molde.

**Ajuste de lógica de negocio** — 96 palabras:

> Ajuste de la lógica que clasifica la cartera y define el tipo de cobro de cada
> deudor en el tablero Gestion_Cobranza. Aprobado por la Coordinación de Cartera.
>
> Tres cambios: se separa la cartera empresarial en categoría propia, ya que 41
> clientes se clasificaban con criterios académicos que no les aplican; se prioriza
> por riesgo crediticio real y no por tener el dato; y se ajusta el corte de
> aprobación académica. Se agregó una subcategoría que ordena la cola de trabajo
> del asesor.
>
> Impacto: 11.810 obligaciones cambian de categoría. Se adjunta el documento con
> el detalle.

**Actualización de un proceso** — 84 palabras:

> Se actualizó la información de cartera que consulta el equipo de asesores, para
> que incluya la nueva clasificación de gestión aprobada por la Coordinación de
> Cartera.
>
> Antes el reporte mostraba únicamente la categoría general del deudor. Ahora
> también trae la subcategoría, que distingue por ejemplo entre quien perdió el
> periodo y quien además presenta riesgo crediticio, de modo que el asesor puede
> ordenar su cola de trabajo por prioridad real.
>
> Se procesó la carga completa: 302.586 registros actualizados en tres minutos,
> sin novedades.

## Cómo traducir lo técnico

Lo que hiciste → lo que va en el ticket:

| En el trabajo | En el ticket |
|---|---|
| Se modificó `SP_Cartera_Total` | "se ajustó el proceso que arma la cartera diaria" |
| Se agregó la columna `MARCA_ACADEMICA_DETALLE` | "el reporte ahora trae la subcategoría de gestión" |
| Se amplió el filtro a `Riesgo Regular` | "se prioriza por riesgo crediticio real" |
| Bootstrap para evitar el error 207 | omitir: es un detalle de implementación |
| Se desplegó y commiteó | omitir: se asume |
| 258.841 filas | "258.841 registros" — o mejor, la cifra de personas |

Las cifras sí van, y son lo que hace creíble el ticket. Preferir la que el área
entiende: clientes o personas antes que filas.

## Gotchas

- **El validador marca `Gestion_Cobranza` como código si no está en la lista.**
  Los nombres de tablero son vocabulario de negocio y deben quedarse. Ya están
  permitidos `Gestion_Cobranza`, `Meta_Comercial` y `Flujo_Caja`; para uno nuevo,
  pasar `--permitir Nombre_Del_Tablero`.

- **Aquí se escribe sin tildes** en buena parte de los borradores, así que el
  detector de verbos acepta las dos formas ("ajusto" y "ajustó"). Si agregas un
  verbo nuevo a `ACCION` en `validar.py`, cubre ambas.

- **Menos de 35 palabras también falla.** Un ticket de dos líneas casi siempre
  omitió el "para qué" o el impacto, que es justo lo que el coordinador necesita.

- **No pegar el ticket con el conteo dentro.** El "(96 palabras)" es para tu
  control, no parte del texto que va al formulario.

## Troubleshooting

| Síntoma | Causa | Arreglo |
|---|---|---|
| `N termino(s) tecnico(s) por reemplazar` | Se coló jerga | El validador imprime cada término con su reemplazo sugerido |
| Marca un nombre de tablero legítimo | No está en la lista de permitidos | `--permitir Nombre` |
| `No se detecta un verbo de accion` | El ticket describe un estado, no una acción | Empezar con "Se creó/ajustó/actualizó…" |
| `Se pasa por N palabras` | Sobra contexto | Recortar el bloque 2; el 1 y el 3 son los que no se negocian |
