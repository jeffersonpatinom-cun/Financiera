---
name: informes-cartera-word
description: Producir los informes ejecutivos en Word de cartera CUN con identidad visual institucional -- el informe mensual de la Meta Comercial y el informe de cierre de mes (cumplimiento, gestion de asesores y recaudo). Usar cuando pidan un informe ejecutivo de cartera, el informe de la meta de un mes, el informe de recaudo o de gestion de asesores, actualizar uno existente para otro mes, o cuando haya que respetar el tope de paginas y los lineamientos visuales CUN.
---

# Informes ejecutivos de cartera en Word

Dos informes, mismo motor. Van dirigidos a la **Coordinación de Recaudo y Cartera**
(Óscar Penagos), no a un ingeniero: se leen en cinco minutos y cada cifra tiene que
sostenerse sola.

| Informe | Cuándo | Tope | Fuente |
|---|---|---|---|
| **Meta Comercial** del mes | El día 1, tras correr `JOB_USP_Foto_Meta_Comercial_Mensual` | 2 hojas | `Cartera_Meta_Comercial_Historico` |
| **Cierre de mes** (cumplimiento + gestión + recaudo) | Cuando ya cerró el mes anterior | 3 hojas | + `Cartera_CUN_Asesor_Unico` y el snapshot |

Referencias vivas, no plantillas muertas: `generar_informe_meta_septiembre.py` y
`generar_informe_agosto.py` en la raíz del repo. Para un mes nuevo se copia el que
corresponda y se cambian las cifras.

## El ciclo

```
reglas de calculo  ->  .sql de respaldo  ->  generador .py  ->  verificar paginas  ->  entregar  ->  commit
```

**1. Confirmar las reglas antes de contar.** Están abajo, en "Reglas que ya se
acordaron". No son negociables por conveniencia: cada una nació de un número que
resultó falso. Si el usuario pide una regla nueva, verificar el volumen que produce
en los tres meses vecinos antes de aceptarla — una serie incoherente delata que la
columna mide otra cosa.

**2. Escribir el `.sql` de respaldo primero**, con varios `SELECT` que el driver
tabula como result sets. Sirve para dos cosas: sacar las cifras, y que el
coordinador pueda reproducirlas sin pedirlas.

```bash
.venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py query @analisis_cierre_agosto_2026.sql --limite 14
```

**3. El generador solo pone contenido.** La identidad visual está en
`estilo_cun.py` de este skill. Nunca recopiar los helpers a un archivo nuevo.

```python
import sys
sys.path.insert(0, ".claude/skills/informes-cartera-word")
from docx.shared import Pt
from estilo_cun import DocumentoCUN, AZUL_MARINO, AZUL_INST, TURQUESA, TEXTO, TIT, CUERPO

D = DocumentoCUN()
doc = D.doc
_fuente = D.fuente
par, h1, vineta, tabla = D.par, D.h1, D.vineta, D.tabla
callout, kpi_row, nota, linea_acento = D.callout, D.kpi_row, D.nota, D.linea_acento

D.portada("Cierre de Cartera — Agosto 2026",
          [("Dirigido a: ", "Óscar Penagos — Coordinación de Recaudo y Cartera"),
           ("Periodo: ", "agosto de 2026"),
           ("Elaboró: ", "Analítica financiera CUN")])
callout("Conclusión", ["..."])
h1("1.  Cumplimiento de la meta")
kpi_row([("9.289", "OBLIGACIONES CUMPLIDAS"), ("18,5%", "CUMPLIMIENTO")])
tabla(["Concepto", "Obligaciones"], [["Universo", "50.146"]],
      anchos=[7.0, 2.5], alinear_der=[1])
D.salto_pagina()
D.guardar("Informe_Ejecutivo_Cierre_Agosto_2026.docx")
```

**4. Verificar el tope.** El número de páginas no se estima a ojo: solo Word sabe
dónde parte. Sale con código 1 si excede.

```bash
.venv/Scripts/python.exe .claude/skills/informes-cartera-word/verificar_paginas.py \
    Informe_Ejecutivo_Cierre_Agosto_2026.docx --max 3
```

```
PAGINAS: 3   (tope 3)
Rasterizado: _preview_p1.png, _preview_p2.png, _preview_p3.png
```

**Hay que mirar los PNG uno por uno.** El conteo no detecta una tabla partida a la
mitad, un título huérfano al pie ni un encabezado que se envolvió a dos líneas.

**5. Limpiar los previews** — no se comitean:

```bash
.venv/Scripts/python.exe .claude/skills/informes-cartera-word/verificar_paginas.py \
    Informe_Ejecutivo_Cierre_Agosto_2026.docx --limpiar
```

**6. Commit** del `.sql`, el `.py` y el `.docx`. El `.docx` sí se versiona: es
agregado, sin datos personales. Una **base** con nombres, correos o teléfonos no
—va en `.gitignore` y se entrega por canal interno.

## Reglas que ya se acordaron

Cada una corrige un número que salió mal. Reintroducir cualquiera de estas es
volver a publicar una cifra falsa.

**Q y marca académica salen del snapshot, nunca de la tabla viva.** El paso 5a de
`USP_Foto_Meta_Comercial_Mensual` recalcula `Asignacion Q` y `MARCA_ACADEMICA` en
cada corrida. Leerlas de la tabla viva al medir un mes cerrado mezcla la Q nueva de
los créditos que siguen con la vieja de los que salieron, y produce un falso 99,7%
de cumplimiento en Q4 contra 4,0% en Q1. Lo correcto es
`Cartera_Meta_Comercial_Snapshot_Mensual` con `ANIO_MES_SNAPSHOT` del **mes
siguiente** al que se reporta, que es la foto previa al refresco. La cifra real es
25,4% en Q4 contra 7,4% en Q1. `analisis_cierre_agosto_2026.sql` deja la versión
incorrecta como bloque de control etiquetado `NO USAR`.

**El saldo del universo también sale del snapshot.** La tabla viva ya refrescó el
saldo de los que siguen, así que subestima con qué saldo se trabajó realmente el
mes ($15.042,0 MM contra los $15.198,0 MM correctos en agosto).

**Gestión se mide con `Hora_modificacion_tipif`, no con `Hora_de_modificación`.**
La segunda cae en agosto para el 93% de la base por una actualización masiva —1.538
registros en julio contra 210.789 en agosto—: mide carga de sistema, no trabajo de
asesor. La primera da una serie coherente: 17.351 / 61.767 / 4.238.

**El universo de asesores excluye `'Reasignar en CRM'` y `'Sin asignar'`** de la
columna `Asesor_Unico`. Son 84.179 de 311.640 registros; sin el filtro toda métrica
de gestión queda inflada un 27%. Ese apartado es hallazgo por derecho propio, pero
se reporta cruzado contra la meta: ver la regla siguiente.

**Pago = `Fecha_de_pago` en el mes, sumando `Valor_pagado`.**

**La cartera sin responsable se cruza contra la meta.** Los registros con
`Asesor_Unico` en `'Reasignar en CRM'` o `'Sin asignar'` son 84.179 de 28.619
personas, pero la mayoria es cartera fuera de meta que no le corresponde
reasignar a Cartera. La cifra que se reporta es la interseccion con los
estudiantes de la meta vigente: 16.272 registros de 4.249 personas, $1.383,8
millones, el 8,4% del saldo de la meta.

**El cumplimiento se mide por salida completa de la obligación, no por reducción de
saldo.** El refresco total de saldos entró en operación el 2026-09-01; antes de esa
fecha `BASELINE_20260826` y los snapshots `202608` y `202609` tienen saldo idéntico,
así que el abono parcial de agosto no es medible. Decirlo en el informe.

## Trampas de datos

**Dinero del CRM viene como `'CO$ 351,576.50'`.** Sin sanear, toda suma da **0 en
silencio**:

```sql
TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(REPLACE(col,'CO$',''),',',''),' ',''))
```

**Fechas en `dd/MM/yyyy`** → `TRY_CONVERT(..., 103)`. Ordenar el varchar como texto
pone `"31/07"` después de `"09/08"`.

**Comprobar la cobertura de una dimensión antes de tabularla.** En los pagos de
agosto, `Medio_de_pago` estaba vacío en el 94%, `Tipo_de_cartera` en el 100% y
`Regional` en el 89%. Una tabla que es toda "(sin registro)" no es un hallazgo, es
ruido: se descarta la dimensión y se menciona el hueco en las observaciones.

**Una fila es una obligación, no una persona.** Para dimensionar campañas,
`COUNT(DISTINCT IDENTIFICACION)`.

**`Cartera_CUN_Asesor_Unico` es foto del día, no histórico.** Se reconstruye entera
en cada corrida. Lo tipificado en un mes y sobrescrito después ya no se ve: las
cifras de gestión son un piso, no un techo. Declararlo.

## Redacción

Sigue `Lineamientos_Visuales_y_Comunicacion_CUN_Word.md`: primera persona del
plural ("Ejecutamos", "Comparamos"), tono cercano pero profesional, todo
fundamentado en el dato.

- **Rotular el dinero por lo que es.** Si sale del CRM es *"registrado en CRM"*,
  nunca *"recaudado"* a secas: en agosto el CRM registró $5.483,9 MM y la caja real
  de esa población fue $9.307,4 MM.
- **No nombrar asesores** salvo que lo pidan explícitamente. Por defecto, agregados
  del equipo: un ranking nominal en un documento que circula es una evaluación de
  personal.
- Cada viñeta abre con su etiqueta en negrita (`vineta(texto, "Etiqueta: ")`).
- Las observaciones de la Analítica van al final y son honestas: qué no se pudo
  medir y por qué.

## Estructura que funciona

Portada compacta + callout de conclusión, luego secciones numeradas. Cada sección:
`h1` → `kpi_row` (máximo 4 cifras) → párrafo de contexto → tabla → viñetas de
lectura. Cerrar con callout de recomendación y `nota()` de fuente.

Para el salto de página, `D.salto_pagina()` explícito. Si el bloque siguiente no
cabe, **recortar contenido**, nunca bajar el tamaño de fuente: los lineamientos
fijan 10 pt de cuerpo y 8,5 pt de tabla como mínimos legibles.

## Gotchas

- **Word reescribe el `.docx` con solo abrirlo.** Si el usuario lo tiene abierto
  para revisarlo, `git status` lo marca modificado aunque el contenido no cambie.
  No hay que regenerarlo: `git restore <archivo.docx>` cuando lo cierre. Verificar
  con `Get-Process WINWORD` quién lo tiene tomado antes de tocar nada, y **nunca**
  matar un Word con ventana: es la sesión del usuario.
- **El ancho de columna es una sugerencia.** Word reajusta por su cuenta y un
  encabezado largo se parte en dos líneas aunque le sobre espacio. La solución que
  funciona es acortar el texto: `"% del total"` → `"% total"`.
- **Montserrat y Open Sans puede que no estén instaladas.** Word sustituye y el
  documento se ve bien igual; no es un error que haya que perseguir.
- **`PermissionError: [Errno 13]`** al generar: el `.docx` está abierto en Word.
- **Verificar las cifras derivadas.** Las que se calculan a mano para el texto
  —porcentajes, restos, sumas de dos categorías— hay que confirmarlas contra la
  base antes de imprimirlas. Sumar dos `COUNT(DISTINCT)` no da el distinct de la
  unión: en agosto eso daba 2.109 personas donde eran 2.103.
