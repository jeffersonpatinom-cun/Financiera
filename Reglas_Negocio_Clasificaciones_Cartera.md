# Reglas de negocio — Clasificaciones de la Cartera CUN

**Universidad CUN — Analítica financiera**
Fecha del documento: 2026-08-28 (actualiza la versión del 2026-08-27)
Alcance: `Asignacion Q`, `Asesor_Unico`, `MARCA_ACADEMICA` (+ `MARCA_ACADEMICA_DETALLE`) y `CLASIFICACION_CARTERA`.

---

## 0. Mapa rápido

| Columna | Responde a | Dónde vive | Quién la calcula | Frecuencia |
|---|---|---|---|---|
| `Asignacion Q` | **¿Con qué urgencia se cobra?** | `Financiera.Cartera_Meta_Comercial_Historico` | `USP_Foto_Meta_Comercial_Mensual` | Mensual (día 1, 00:30) |
| `Asesor_Unico` | **¿Quién lo gestiona?** | `Financiera.Cartera_CUN_Asesor_Unico` | `Usp_Cartera_CUN_Asesor_Unico` | Manual hoy; job diario encadenado a `JOB_Cartera_Total` pendiente del DBA |
| `MARCA_ACADEMICA` | **¿En qué situación académica está el deudor?** | `Cartera_Total`, `Cartera_Gestion`, `Cartera_Meta_Comercial_Historico` | `SP_Cartera_Total` (PASO 3) | Diaria (06:00) |
| `CLASIFICACION_CARTERA` | **¿Es deuda vigente, vencida o refinanciada?** | `Cartera_Total`, `Cartera_Gestion` | `SP_Cartera_Total` (PASO 3) | Diaria (06:00) |

Las cuatro son **independientes entre sí y se combinan**: un mismo crédito puede ser
`Q1` + `PERIODO PERDIDO, PRIORIDAD ALTA` + `CARTERA` + asignado a un asesor concreto.
Esa combinación es la que define la cola de trabajo real del equipo de cobranza.

---

## 1. `Asignacion Q` — priorización por antigüedad del saldo

### Qué es
Un **cuartil de saldo acumulado**, no un cuartil de conteo. Reparte la meta comercial
del año en cuatro bloques de **igual valor monetario**, ordenados del crédito más
vencido al más reciente.

### Universo al que aplica
Solo entra a la meta comercial la cartera que cumple **todos** estos filtros
(`USP_Foto_Meta_Comercial_Mensual`, paso 4):

- `DOCUMENTO = 'NDB'`
- `NOMBRE_TIPO_CLIENTE = 'ESTUDIANTES'`
- `NOMBRE_CONCEPTO = '701-ND CARGOS FINANCIEROS A ESTUDIANTES'`
- `NOMBRE_CAUSA = '715-CUOTA CAPITAL CLTIENE'`
- `CORRIENTE = 0` (la cuota ya está vencida)
- `TOTAL > 24.000` (se excluyen saldos irrisorios)
- `PERIODO` del año en curso

### Cómo se calcula

1. Se ordenan **todos** los créditos del universo por `FECHA_VENCIMIENTO` ascendente
   (el más antiguo primero). Los créditos **sin fecha de vencimiento se empujan al
   final**. Los empates se rompen por `IDENTIFICACION` y `NUMERO_CREDITO` para que el
   resultado sea determinista.
2. Se calcula la **suma acumulada** del `TOTAL` en ese orden (`_RunTotal`) y el
   **gran total** de la meta (`_GrandTotal`).
3. Se corta por porcentaje acumulado:

| Cuartil | Regla | Lectura de negocio |
|---|---|---|
| **Q1** | acumulado ≤ 25 % | El 25 % del dinero **más vencido**. Máxima prioridad. |
| **Q2** | acumulado ≤ 50 % | Segundo bloque de antigüedad. |
| **Q3** | acumulado ≤ 75 % | Tercer bloque. |
| **Q4** | resto (> 75 %) | El 25 % **más reciente** + todo lo que no tiene fecha de vencimiento. |

Salvaguarda: si `_GrandTotal` es `NULL` o `0`, todo cae en `Q1` (evita división por cero).

### Cómo se ve hoy

| Q | Créditos | Saldo |
|---|---|---|
| Q1 | 9.002 | $3.242 MM |
| Q2 | 9.680 | $3.241 MM |
| Q3 | 9.620 | $3.242 MM |
| Q4 | **37.154** | $10.634 MM |

**Q1–Q3 tienen saldos casi idénticos por construcción** — así se diseñó. La asimetría
está en Q4: concentra 4 veces más créditos porque ahí caen las cuotas de menor valor
unitario y todas las de vencimiento nulo.

### Trampas
- **`Asignacion Q` NO es "estado de la deuda"**: un Q4 puede estar muy vencido si su
  cuota es pequeña. La antigüedad individual se lee en los buckets `GR1A30`…`GR360MAS`.
- **Se recalcula completo cada mes**, sobre el universo vivo. Un crédito puede pasar
  de Q3 a Q1 sin que su situación cambie, simplemente porque otros salieron de la meta.
- **Los cuartiles son globales, no por asesor ni por seccional.** Comparar "% de Q1
  gestionado" entre asesores solo tiene sentido si primero se normaliza por su cartera.

---

## 2. `Asesor_Unico` — asignación única de responsable

### Qué es
Un estudiante puede tener **varias filas en `ZOHO.CRM.Cartera_CUN`** (una por
crédito/registro), cada una con propietario y modificador distintos. `Asesor_Unico`
colapsa eso a **un solo responsable por número de identificación**, replicado a todas
las filas de ese estudiante.

### Escalera de prioridad

Se evalúa fila por fila y gana la de **menor prioridad numérica**:

| Prioridad | Fuente del nombre | Condición |
|---|---|---|
| **0** | `Hecho_por` de la última tipificación | que no sea `CUN DIGITAL` ni `PENAGOS` |
| **1** | `Nombre_completo` del usuario que modificó (`Modificado_por` → `Zoho.crm.usuarios`) | que no sea `CUN DIGITAL` ni `PENAGOS` |
| **2** | `Propietario_de_Cartera_CUN_Name` | caso normal: el dueño en CRM |
| **3** | literal **`'Reasignar en CRM'`** | el propietario es `CUN DIGITAL` o `PENAGOS` |
| **4** | literal **`'Sin asignar'`** | modificador **y** propietario son ambos `CUN DIGITAL` |

Si hay empate de prioridad, gana la fila con `Hora_de_modificación` más reciente.

**El principio de fondo:** *quien tipificó de verdad pesa más que quien figura como dueño.*
`CUN DIGITAL` y `PENAGOS` son cuentas de sistema, no personas: se descartan como
candidatos y disparan los dos literales de excepción.

### "Última tipificación": cómo se determina
De `ZOHO.CRM.Historico_tipificacion_contact`, una fila por `Cartera_CUN` (el `Id` del
registro), ordenada por `COALESCE(Hora_de_modificación, Hora_de_creación)` descendente.
Se descartan 1.878 filas huérfanas con `Cartera_CUN` nulo.

> Historial: antes se ordenaba por `Hora_de_la_última_actividad`, poblada solo en el
> 6,2 % de las filas — el TOP 1 devolvía una fila **arbitraria** en el 94 % de los casos.
> Corregido el 2026-08-25.

### Cómo se ve hoy (305.332 filas)

- **24 valores distintos**: 22 asesores reales + los 2 literales.
- **`Reasignar en CRM`: 86.189 filas (28 %)** — bandeja de reasignación pendiente.
- **`Sin asignar`: 4.152 filas (1,4 %)**.

### Trampas
- **`Reasignar en CRM` y `Sin asignar` NO son asesores, son estados.** Toda medida que
  cuente asesores o reparta cartera debe excluirlos, o el 29 % de la base se atribuye a
  "personas" que no existen.
- **La llave es la identificación, no el crédito.** Si un estudiante tiene dos créditos
  gestionados por asesores distintos, `Asesor_Unico` conserva solo uno. El detalle por
  crédito sigue en `Propietario_de_Cartera_CUN_Name`.
- **`Asesor_Unico` NO sirve para medir gestión.** Ver la sección 2.1.

### 2.1 `GESTION_*` — quién gestionó de verdad (2026-09-03)

`Asesor_Unico` está diseñado para **nunca quedar vacío**: baja la escalera hasta encontrar
algo. Solo la **prioridad 0** es evidencia de gestión. La 1 es quien tocó el registro en el
CRM y la 2 es simplemente el dueño asignado — ninguno de los dos tipificó.

Por eso el filtro que se venía usando para contar gestiones —
`Asesor_Unico NOT LIKE '%asignar%'`, o su equivalente `NOT IN ('Reasignar en CRM','Sin asignar')` —
**es incorrecto**: solo descarta los dos literales (prioridades 3 y 4) y deja pasar toda la 1
y la 2 como si hubieran gestionado.

> **Medido el 2026-09-03:** el filtro viejo daba **62.573 cédulas** (229.902 filas) cuando
> las gestionadas de verdad eran **30.757**. Sobreestimaba en **103 %** — más del doble.

Las columnas `GESTION_*` salen **únicamente** del histórico de tipificación:

| Columna | Qué es |
|---|---|
| `GESTION_ASESOR` | Asesor de la última gestión humana de esa cédula. `NULL` si nadie la gestionó. |
| `GESTION_MARCA` | `bit`. **Este es el filtro correcto: `WHERE GESTION_MARCA = 1`.** |
| `GESTION_FECHA_PRIMERA` | `datetime` de la primera gestión. |
| `GESTION_FECHA_ULTIMA` | `datetime` de la última gestión. |
| `GESTION_PAGO_POST_MARCA` | `bit`. Hay gestión **y** `Fecha_de_pago >= GESTION_FECHA_PRIMERA`. |

Reglas de construcción:

- **Grano: por cédula**, igual que `Asesor_Unico`. Es la lógica de cobro — una cédula
  pertenece a un asesor sin importar cuántas cuotas tenga; si tipificó una cuota, gestionó a
  la persona y los pagos de cualquiera de sus cuotas le son atribuibles.
- **Los bots no cuentan.** `CUN DIGITAL` y `PENAGOS` son el **54,3 %** del histórico, pero
  filtrarlos solo deja sin gestión a **29 cédulas**: casi nunca son el único gestor.
- **El filtro de bot va antes del `ROW_NUMBER`.** Si el último toque de un crédito lo hizo el
  bot pero antes hubo una tipificación humana, la gestión real existe. Por eso no se reutiliza
  `#Tipificacion_Ultima`, que toma `rn = 1` sobre todas las filas.

**Los dos campos responden preguntas distintas y no son intercambiables:**

| | Responde | ¿Puede ser NULL? |
|---|---|---|
| `Asesor_Unico` | ¿De quién es esta cartera? (base asignada, reparto, cuartiles) | No, nunca |
| `GESTION_ASESOR` | ¿Quién gestionó? (gestiones, efectividad, pagos) | Sí, si nadie gestionó |

Uso aguas abajo:

```sql
WHERE GESTION_MARCA = 1                      -- universo de gestión real
-- Personas gestionadas -> DISTINCTCOUNT(Número_de_identificación)
-- Gestiones del mes    -> GESTION_FECHA_ULTIMA dentro de la ventana
-- Pagos atribuibles    -> WHERE GESTION_PAGO_POST_MARCA = 1
```

**Trampa:** `Hora_modificacion_tipif` sigue existiendo pero **no** es la fecha de gestión de
`GESTION_ASESOR` — está al grano del crédito, viene `varchar` sin parsear e incluye bots. Para
fechas de gestión se usan las `GESTION_FECHA_*`.

---

## 3. `MARCA_ACADEMICA` — situación académica del deudor

Es la columna que **el tablero de recuperación usa para segmentar la gestión**. Se
calcula en dos capas: una escalera académica base y un refinamiento por riesgo crediticio.

### 3.1 Escalera base (`MARCA_BASE`) — se evalúa en orden, la primera que aplica gana

| # | Condición | Marca |
|---|---|---|
| 0 | `NOMBRE_TIPO_CLIENTE <> 'ESTUDIANTES'` | **CARTERA EMPRESARIAL** |
| 1 | Periodo con estado `ACTIVO` | **PERIODO EN CURSO** |
| 2 | Periodo con estado `PERIODO NO HA INICIADO` | **PERIODO NO HA INICIADO** |
| 3 | `PROMEDIO < 1,55` | **SIN REGISTRO DE CLASE** |
| 4 | `PROMEDIO < 3,0` | **PERIODO PERDIDO, PRIORIDAD ALTA** |
| 5 | `PROMEDIO >= 3,0` | **GESTIONABLE** |
| 6 | `ESTADO_ALUMNO` contiene "graduad" o "egresad" | **GESTIONABLE** |
| 7 | Último acceso a Moodle en los últimos **90 días** | **PERIODO EN CURSO** |
| 8 | (todo lo demás) | **SIN REGISTRO DE CLASE** |

**El orden importa y no es negociable:**
- El **paso 0 va primero** porque un NIT no tiene notas, ni plataforma, ni periodo
  académico; aplicarle la lectura académica produce marcas sin sentido.
- Los **pasos 1–2 mandan sobre las notas**: mientras el periodo esté abierto no se
  puede juzgar el rendimiento, todavía no hay nota definitiva.
- Los pasos 6–8 solo se alcanzan cuando **el promedio es NULL** (el estudiante no está
  en la fuente académica). Ahí el rastro de Moodle es la única evidencia de actividad.

**Umbrales — significado de negocio:**
- **`< 1,55`** ≈ el estudiante ni siquiera se presentó. No es un problema académico, es
  ausencia total: la marca es *SIN REGISTRO DE CLASE*, no *PERIODO PERDIDO*.
- **`< 3,0`** = por debajo de la nota aprobatoria de la CUN → periodo perdido.
- **`>= 3,0`** = aprobó. Es un deudor que sigue vinculado y con trayectoria: *GESTIONABLE*.

**Fuente del promedio:** `PRO_ACUMULADO` de Oracle (SINU), vía OPENQUERY, **cruzado
solo por identificación** — es un acumulado de carrera, no un promedio por periodo.

### 3.2 Refinamiento por riesgo crediticio

De `Financiera.Financiaciones_CTAYUDA_V2` se trae `RES_PERFIL_RIESGO` (buró),
deduplicado por documento+periodo quedándose con el **peor** perfil y el **menor**
score — deliberadamente conservador.

> **Riesgo adverso** = `'Riesgo Alto'` + `'Riesgo Regular'` (score < 670). Ese corte no
> es arbitrario: es la frontera de la propia escala del buró entre Regular (≤ 668) y
> Bueno (≥ 670).

**Única regla de escalamiento:**

> `GESTIONABLE` + riesgo adverso → **`PERIODO PERDIDO, PRIORIDAD ALTA`**

Es decir: *aprobó académicamente, pero el buró advierte* → se prioriza el cobro igual.
Ninguna otra marca se altera.

### 3.3 `MARCA_ACADEMICA_DETALLE` — subcategoría operativa

**No sustituye a `MARCA_ACADEMICA`** (el tablero sigue leyendo esa). Ordena la cola de
trabajo del asesor *dentro* de cada marca:

| Marca base | Detalle si riesgo adverso | Detalle normal |
|---|---|---|
| CARTERA EMPRESARIAL | — | `CARTERA EMPRESARIAL - <tipo de cliente>` |
| PERIODO NO HA INICIADO | — | `PERIODO NO HA INICIADO` |
| PERIODO EN CURSO | `PERIODO EN CURSO - RIESGO CREDITICIO` | `PERIODO EN CURSO` |
| PERIODO PERDIDO, PRIORIDAD ALTA | `PERIODO PERDIDO + RIESGO CREDITICIO` | `PERIODO PERDIDO` |
| GESTIONABLE | `RIESGO CREDITICIO ADVERSO` | `GESTIONABLE` |
| SIN REGISTRO DE CLASE | *con* acceso a Moodle → `SIN REGISTRO DE CLASE - CON CONEXION` | *sin* rastro → `SIN REGISTRO DE CLASE - SIN CONTACTO` |

Ese último par es el más accionable del set: **con conexión** = el estudiante existe y
está en línea, es recuperable; **sin contacto** = candidato a castigo o a gestión
externa.

> Ojo con la asimetría: `GESTIONABLE` + riesgo adverso **cambia de marca** (sube a
> PERIODO PERDIDO) y su detalle es `RIESGO CREDITICIO ADVERSO`. Por eso el detalle
> `RIESGO CREDITICIO ADVERSO` (20.718 filas) nunca aparece bajo la marca `GESTIONABLE`.

### 3.4 Cómo se ve hoy (`Cartera_Gestion`, 259.818 filas)

| MARCA_ACADEMICA | Filas | Saldo |
|---|---|---|
| PERIODO EN CURSO | 98.171 | $26.126 MM |
| SIN REGISTRO DE CLASE | 52.032 | $12.614 MM |
| PERIODO PERDIDO, PRIORIDAD ALTA | 41.954 | $10.818 MM |
| GESTIONABLE | 39.664 | $8.047 MM |
| PERIODO NO HA INICIADO | 18.758 | $5.676 MM |
| CARTERA EMPRESARIAL | 9.239 | $4.822 MM |

Detalle: `PERIODO EN CURSO` 85.125 · `SIN REGISTRO - CON CONEXION` 40.131 ·
`GESTIONABLE` 39.664 · `RIESGO CREDITICIO ADVERSO` 20.718 · `PERIODO NO HA INICIADO`
18.758 · `PERIODO EN CURSO - RIESGO CREDITICIO` 13.046 · `PERIODO PERDIDO` 13.034 ·
`SIN REGISTRO - SIN CONTACTO` 11.901 · `CARTERA EMPRESARIAL - COMERCIAL` 9.234 ·
`PERIODO PERDIDO + RIESGO CREDITICIO` 8.202 · `CARTERA EMPRESARIAL - COLABORADORES` 5.

### Trampas
- **La marca nunca es NULL.** La escalera siempre cae en alguna rama (`ELSE` final).
  Un "sin dato" se disfraza de `SIN REGISTRO DE CLASE`, no de vacío.
- **Es una foto del día de la corrida**, no un histórico. Los pasos 7 (Moodle 90 días)
  y 1–2 (estado del periodo) dependen de `GETDATE()`: la misma fila puede cambiar de
  marca mañana sin que nada del estudiante cambie.
- **La versión en `Cartera_Meta_Comercial_Historico` es idéntica salvo un detalle**: allí
  la rama `CARTERA EMPRESARIAL` se omite a propósito, porque el origen ya filtra
  `NOMBRE_TIPO_CLIENTE = 'ESTUDIANTES'` y sería código muerto.

---

## 4. `CLASIFICACION_CARTERA` — vigente, vencida y refinanciada

### Qué es
La lectura *contable* de la obligación, no la académica. Nace del estado del periodo
académico colapsado a dos valores, y desde el **2026-08-28** admite un tercero que ya
no depende del periodo sino del deudor completo.

| Valor | Regla | Lectura |
|---|---|---|
| **CUENTAS POR COBRAR** | `ESTADO IN ('ACTIVO', 'PERIODO NO HA INICIADO')` | El periodo está vigente o aún no arranca (`fec_fin >= hoy`). La deuda es corriente. |
| **CARTERA** | todo lo demás, incluido `ESTADO` nulo | El periodo académico ya cerró (`fec_fin < hoy`). Es cartera vencida. |
| **CXC REFINANCIADO** | el deudor tiene obligaciones en **ambas** categorías anteriores | Arrastra deuda de un periodo cerrado y además debe del vigente. Tratamiento de cobranza distinto. |

### `CXC REFINANCIADO` — la excepción que manda sobre las otras dos (2026-08-28)

Se evalúa **por estudiante, no por obligación**: si un deudor tiene al menos una
obligación `CARTERA` y al menos una `CUENTAS POR COBRAR`, **todas** sus obligaciones
—incluidas las del periodo cerrado— se reetiquetan `CXC REFINANCIADO`.

Cartera evaluó dos alcances y eligió el amplio:

| Alcance | Obligaciones | Valor |
|---|---|---|
| Solo las filas `CUENTAS POR COBRAR` del deudor | 8.256 | $2.263,6 MM |
| **Todas las filas del deudor** ← elegido | **22.062** | **$5.874,4 MM** |

**Lo que este cambio arregla.** Antes los buckets se solapaban a nivel de cliente:
47.368 (`CARTERA`) + 39.965 (`CXC`) = 87.333, contra 82.585 clientes reales — los 4.748
del caso se contaban **dos veces**. Cualquier tablero que sumara clientes por
clasificación inflaba el universo en 5,7 %. Con el tercer valor los tres son
mutuamente excluyentes y suman exactamente 82.585.

> ⚠️ **Lo que este cambio rompe, a propósito.** `CLASIFICACION_CARTERA` **deja de ser
> función únicamente del PERIODO**. Antes se cumplía —y estaba verificado— que 0 pares
> `IDENTIFICACION + PERIODO` tenían dos clasificaciones y que 0 periodos tenían dos.
> Ahora la etiqueta de una fila **depende de la cartera completa de su dueño**: dos
> obligaciones del mismo periodo pueden quedar distinto si sus deudores tienen carteras
> distintas. Toda lógica que asuma "una clasificación por periodo" queda inválida.

Implementación: `MIN(...) OVER (PARTITION BY IDENTIFICACION) <> MAX(...) OVER (...)`.
`COUNT(DISTINCT)` no se admite como función de ventana en SQL Server; como los valores
base son solo dos y `'CARTERA' < 'CUENTAS POR COBRAR'` alfabéticamente, `MIN` y `MAX`
difieren si y solo si el deudor tiene ambas.

### Por qué se deriva del mismo `ESTADO` y no del calendario
Deliberado: `CLASIFICACION_CARTERA` y `MARCA_ACADEMICA` beben de la **misma** columna
`C.ESTADO`. Así **no pueden contradecirse nunca** — es imposible que un crédito quede
marcado `PERIODO EN CURSO` y a la vez clasificado como `CARTERA`.

### Decisiones explícitas de Cartera (2026-08-26)
- **`fec_fin = hoy` cuenta como vigente** → `CUENTAS POR COBRAR`.
- **Periodo ausente del calendario (`ESTADO` NULL) → `CARTERA`.** Son 25 códigos de
  periodo / 818 obligaciones. La decisión es conservadora: si no se puede probar que
  está vigente, se trata como vencida.

### El estado del periodo (`C.ESTADO`)
Viene de `Dbo.Periodos_Calendario`, colapsado a **una fila por `cod_periodo`** con
`MIN(fec_inicio)` / `MAX(fec_fin)`:

- `fec_inicio > hoy` → `PERIODO NO HA INICIADO`
- `fec_fin >= hoy` → `ACTIVO`
- si no → `NO ACTIVO`

> **Advertencia estructural:** la llave real de `Periodos_Calendario` es
> `cod_periodo + descripcion_metod`, y **24 códigos tienen `fec_fin` distinta según la
> modalidad**. El rango envolvente MIN/MAX que se usa aquí **no corresponde a ninguna
> modalidad concreta**: por decisión de Cartera, el periodo está vigente desde que abre
> la primera modalidad hasta que cierra la última. Es intencional y favorece al
> estudiante, pero conviene saberlo al conciliar contra Registro Académico.

### Distribución medida (corrida del 2026-08-28 06:00)

Sin la regla de refinanciados — así quedó la primera corrida que pobló la columna:

| Clasificación | Obligaciones | Clientes | Valor |
|---|---|---|---|
| CARTERA | 142.259 | 47.368 | $35.631,4 MM |
| CUENTAS POR COBRAR | 117.555 | 39.965 | $32.474,4 MM |

Con `CXC REFINANCIADO` aplicado sobre esos mismos datos:

| Clasificación | Obligaciones | Clientes | Valor |
|---|---|---|---|
| CARTERA | 128.453 | 42.620 | $32.020,5 MM |
| CUENTAS POR COBRAR | 109.299 | 35.217 | $30.210,8 MM |
| **CXC REFINANCIADO** | **22.062** | **4.748** | **$5.874,4 MM** |

Los clientes ahora suman 82.585 = el universo exacto de la cartera.

> **Estado al 2026-08-28:** la columna quedó poblada al 100 % (0 NULL sobre 259.814
> filas) en la corrida de las 06:00, con **dos** valores. El tercero
> (`CXC REFINANCIADO`) está desarrollado y compilado pero **aún no desplegado**; aparece
> en la primera corrida posterior al despliegue de
> `alter_sp_cartera_total_cxc_refinanciado.sql`.

---

## 5. Cómo se combinan — lectura conjunta

Un mismo crédito lleva las cuatro marcas y cada una responde una pregunta distinta:

| Columna | Pregunta | Decisión que habilita |
|---|---|---|
| `CLASIFICACION_CARTERA` | ¿es deuda vencida, corriente o refinanciada? | si entra o no a cobranza, y **con qué tratamiento** |
| `MARCA_ACADEMICA` | ¿el deudor sigue vivo académicamente? | **qué** discurso usar |
| `Asignacion Q` | ¿cuánto pesa y qué tan antiguo es? | **en qué orden** llamar |
| `Asesor_Unico` | ¿de quién es? | **quién** llama |

**Cola de trabajo de máxima prioridad**, por ejemplo:

    CLASIFICACION_CARTERA     = 'CARTERA'
    AND MARCA_ACADEMICA_DETALLE = 'PERIODO PERDIDO + RIESGO CREDITICIO'
    AND [Asignacion Q]          = 'Q1'
    AND Asesor_Unico NOT IN ('Reasignar en CRM', 'Sin asignar')

> ⚠️ Ojo con esta cola tras el cambio del 28-ago: `= 'CARTERA'` **ya no incluye** a los
> 4.748 deudores refinanciados, que salieron a `CXC REFINANCIADO`. Si la intención es
> "toda la deuda vencida", el filtro debe ser
> `CLASIFICACION_CARTERA IN ('CARTERA', 'CXC REFINANCIADO')`. Si la intención es
> "vencida con tratamiento ordinario", déjelo como está — pero que sea una decisión,
> no un descuido.

**Cola de saneamiento de CRM** (no es cobranza, es calidad de datos):

    Asesor_Unico IN ('Reasignar en CRM', 'Sin asignar')   -- 90.341 filas hoy

---

## 6. Resumen de trampas

| # | Trampa | Impacto |
|---|---|---|
| 1 | `Reasignar en CRM` / `Sin asignar` contados como asesores | 29 % de la cartera atribuida a personas inexistentes |
| 2 | `Asignacion Q` leído como antigüedad individual | Q4 concentra cuotas pequeñas que sí están muy vencidas |
| 3 | `Asignacion Q` comparado entre asesores sin normalizar | Los cuartiles son globales, no por asesor |
| 4 | `MARCA_ACADEMICA` tratada como histórico | Es una foto del día; depende de `GETDATE()` |
| 5 | `SIN REGISTRO DE CLASE` leído como "mal estudiante" | Es sobre todo *ausencia de dato*; dos casos muy distintos según el detalle |
| 6 | `RIESGO CREDITICIO ADVERSO` buscado bajo `GESTIONABLE` | Esa combinación no existe: la marca ya subió a PERIODO PERDIDO |
| 7 | Sumar **clientes** por `CLASIFICACION_CARTERA` antes del 28-ago | Los buckets se solapaban: 87.333 vs 82.585 reales, 4.748 contados dos veces. Resuelto con `CXC REFINANCIADO` |
| 8 | `MARCA_ACADEMICA` de un estudiante con 2 créditos en periodos distintos | El promedio es acumulado (solo por identificación); el estado del periodo sí es por periodo |
| 9 | Medir **gestión** filtrando `Asesor_Unico` (`NOT LIKE '%asignar%'`) | Sobreestima **103 %**: 62.573 cédulas contra 30.757 reales. Se cuelan las prioridades 1 y 2, que nunca tipificaron. Usar `GESTION_MARCA = 1` (§2.1) |
| 9 | Filtrar `CLASIFICACION_CARTERA = 'CARTERA'` para "toda la deuda vencida" | Desde el 28-ago deja fuera a los 4.748 refinanciados ($5.874,4 MM). Use `IN ('CARTERA','CXC REFINANCIADO')` |
| 10 | Asumir que `CLASIFICACION_CARTERA` es función del periodo | Ya no lo es: `CXC REFINANCIADO` depende de la cartera completa del deudor. Dos filas del mismo periodo pueden diferir |

---

## 7. Referencias de código

| Regla | Archivo | Líneas aprox. |
|---|---|---|
| `Asignacion Q` | `alter_usp_foto_meta_refresco_total.sql` | 178-196 (universo), 284-289 (cuartiles) |
| `Asesor_Unico` | `alter_usp_cartera_cun_asesor_unico_hora_modificacion.sql` | 108-131 (tipificación), 135-193 (escalera) |
| `MARCA_ACADEMICA` base | `alter_sp_cartera_total_clasificacion.sql` | 663-687 (CROSS APPLY `MB`) |
| `MARCA_ACADEMICA` refinamiento | `alter_sp_cartera_total_clasificacion.sql` | 502-523 (CTE `CTAYUDA_RIESGO`), 552-557 |
| `MARCA_ACADEMICA_DETALLE` | `alter_sp_cartera_total_clasificacion.sql` | 561-591 |
| `CLASIFICACION_CARTERA` base | `alter_sp_cartera_total_clasificacion.sql` | 605-608 (regla), 629-653 (estado del periodo) |
| `CXC REFINANCIADO` | `aplicar_cxc_refinanciado.py` → `alter_sp_cartera_total_cxc_refinanciado.sql` | bloque `CASE ... OVER (PARTITION BY A.IDENTIFICACION)` del PASO 3 |
