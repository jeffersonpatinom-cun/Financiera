"""Informe ejecutivo del cierre de agosto 2026 — VERSION CORREGIDA (v2).

Destinatario: Óscar Penagos, Coordinacion de Recaudo y Cartera.
Bloques: fe de erratas, cumplimiento de la meta, gestion del equipo, recaudo
atribuible, liquidacion por asesor y plan de accion de septiembre.

POR QUE HAY UNA v2. La v1 (entregada el 2026-09-02) midio gestion y recaudo
filtrando la columna Asesor_Unico. Ese campo esta disenado para NUNCA quedar
vacio: cuando nadie tipifico, cae al usuario que modifico el registro o al
propietario de la cartera. Consecuencia: 42.768 tipificaciones del bot CUN
DIGITAL se contaron como gestion de asesores humanos. Ver seccion 1.

Fuente de los datos: analisis_cierre_agosto_2026.sql (bloques 2 y 3 reescritos)
  [Financiera].[Cartera_Meta_Comercial_Historico] + Snapshot_Mensual (bloque 1)
  [ZOHO].[CRM].[Historico_tipificacion_contact]                     (gestion)
  [Financiera].[Cartera_CUN_Asesor_Unico], columnas GESTION_*       (recaudo)

Reglas de calculo vigentes (2026-09-03):
  * Gestion  = una fila por tipificacion del historico, sin bots (CUN DIGITAL /
    PENAGOS), con el asesor tomado de Hecho_por. NO Asesor_Unico.
  * Pago     = GESTION_PAGO_POST_MARCA = 1: persona gestionada y pago posterior
    a la PRIMERA gestion.
  * Asignacion (cartera sin responsable) = Asesor_Unico. Ahi si es el correcto.
  * Q y marca de la meta SIEMPRE del snapshot 202609 (cierre de agosto).
  * El ranking va CON NOMBRE por peticion expresa de la Coordinacion, para la
    liquidacion de agosto. El resto del informe reporta el equipo en agregado.

Estilo: Lineamientos_Visuales_y_Comunicacion_CUN_Word.md
"""
import sys

sys.path.insert(0, ".claude/skills/informes-cartera-word")
from estilo_cun import (DocumentoCUN, AZUL_INST,                  # noqa: E402
                        TURQUESA, TIT)

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SALIDA = "Informe_Ejecutivo_Cierre_Agosto_2026.docx"

D = DocumentoCUN()
doc = D.doc
par, h1, vineta, tabla = D.par, D.h1, D.vineta, D.tabla
callout, kpi_row, nota = D.callout, D.kpi_row, D.nota

# ================================================================== HOJA 1
D.portada("Cierre de Cartera — Agosto 2026",
          [("Dirigido a: ", "Óscar Penagos — Coordinación de Recaudo y Cartera"),
           ("Periodo: ", "agosto de 2026"),
           ("Versión: ", "2 — corrige y reemplaza la del 2 de septiembre"),
           ("Elaboró: ", "Analítica financiera CUN")])

callout(
    "Fe de erratas",
    ["Esta versión corrige las cifras de gestión y recaudo que entregamos el 2 de "
     "septiembre. El error es nuestro y lo detectamos revisando cómo se atribuye el "
     "trabajo a cada asesor: la columna que usábamos para identificar al responsable "
     "nunca queda vacía, de modo que cuando la tipificación la hacía el robot del CRM, "
     "el sistema se la acreditaba igual a una persona.",
     "Las cifras de cumplimiento de la meta —sección 2— no cambian: no dependían de "
     "esa columna. Sí cambian gestión, recaudo y la liquidación por asesor."],
    hexc_borde="C8102E",
)

h1("1.  Qué se corrigió y por qué")

tabla(
    ["Cifra", "Publicado 2 sep", "Corregido", "Naturaleza"],
    [["Gestiones de agosto", "61.767", "22.941", "Error de cálculo"],
     ["Asesores activos", "18", "14", "Error de cálculo"],
     ["Personas gestionadas", "18.716", "18.483", "Sin cambio relevante"],
     ["Pagos registrados", "19.002", "9.281", "Cambio de criterio"],
     ["Valor recaudado ($ MM)", "5.483,9", "2.408,8", "Cambio de criterio"],
     ["Efectividad", "32,1%", "18,1%", "Cambio de criterio"]],
    anchos=[6.2, 3.0, 2.8, 4.2],
    alinear_der=[1, 2],
)
par("", after=3)

vineta("de las 61.767 gestiones reportadas, 42.768 las ejecutó el robot CUN DIGITAL, "
       "no un asesor. El informe se las atribuía a personas porque el campo que "
       "identifica al responsable, al no encontrar quién tipificó, cae al dueño "
       "asignado de la cartera. Las gestiones humanas reales fueron 22.941.",
       "Error de cálculo: ")
vineta("el recaudo ya no cuenta cualquier pago de cartera asignada. Ahora exige que la "
       "persona haya sido gestionada y que el pago sea posterior a la primera gestión. "
       "De los $5.483,9 millones publicados, $1.849,5 eran de personas que nadie "
       "gestionó y $1.292,4 correspondían a pagos anteriores a que el asesor tocara el "
       "caso. La cifra defendible es $2.408,8 millones.",
       "Cambio de criterio: ")
vineta("bajo el criterio anterior siguen siendo 5.974 personas y 32,3% de efectividad, "
       "prácticamente lo publicado. La caída a 18,1% no es un desplome del equipo: es "
       "el efecto de exigir que el pago venga después de la gestión.",
       "Lo que NO empeoró: ")

h1("2.  Cumplimiento de la meta")
kpi_row([("9.289", "OBLIGACIONES CUMPLIDAS"),
         ("6.248", "ESTUDIANTES"),
         ("$2.769", "MILLONES LIBERADOS"),
         ("18,5%", "CUMPLIMIENTO")])

par("Estas cifras no cambian respecto de la versión anterior. La meta de agosto se "
    "cerró el 1 de septiembre y una obligación se considera cumplida cuando desaparece "
    "por completo de la cartera vigente.", before=6, after=4)

tabla(
    ["Concepto", "Obligaciones", "Estudiantes", "Saldo ($ MM)", "% total"],
    [["Universo con que arrancó agosto", "50.146", "20.748", "15.198,0", "100,0%"],
     ["Salieron por pago o normalización", "9.289", "6.248", "2.769,5", "18,5%"],
     ["Continúan en la meta de septiembre", "40.857", "15.005", "12.428,5", "81,5%"]],
    anchos=[7.0, 2.5, 2.4, 2.5, 2.0],
    alinear_der=[1, 2, 3, 4],
)

# ================================================================== HOJA 2
D.salto_pagina()

h1("3.  Cumplimiento por cuartil y perfil académico")
par("Los cuartiles se leen de la fotografía del cierre de agosto, no de la cartera de "
    "hoy: el proceso mensual recalcula la asignación Q en cada corrida y compararla "
    "contra la actual mezclaría dos criterios distintos.", after=4)
tabla(
    ["Cuartil", "Obligaciones", "Saldo ($ MM)", "Salieron", "% cumpl."],
    [["Q1 — mayor antigüedad", "7.007", "2.436,7", "515", "7,4%"],
     ["Q2", "7.565", "2.460,9", "725", "9,6%"],
     ["Q3", "6.955", "2.257,8", "777", "11,2%"],
     ["Q4 — vencimiento reciente", "28.619", "8.042,5", "7.272", "25,4%"]],
    anchos=[5.6, 2.7, 2.7, 2.4, 3.0],
    alinear_der=[1, 2, 3, 4],
)
par("", after=3)
tabla(
    ["Marca académica", "Obligaciones", "Saldo ($ MM)", "Salieron", "% cumpl."],
    [["Sin registro de clase", "14.959", "4.355,0", "476", "3,2%"],
     ["Gestionable", "14.349", "5.217,1", "3.613", "25,2%"],
     ["Periodo en curso", "10.496", "2.489,2", "2.757", "26,3%"],
     ["Periodo perdido, prioridad alta", "5.955", "1.908,4", "562", "9,4%"],
     ["Periodo no ha iniciado", "3.980", "1.106,3", "1.804", "45,3%"]],
    anchos=[5.6, 2.7, 2.7, 2.4, 3.0],
    alinear_der=[1, 2, 3, 4],
)
par("", after=3)
vineta("el cumplimiento cae de forma sostenida con la antigüedad —25,4% en Q4 contra "
       "7,4% en Q1— y «sin registro de clase» concentra $4.355,0 millones con apenas "
       "3,2%. Es el grupo más grande de la meta y el que menos responde.",
       "Lectura principal: ")

h1("4.  Gestión del equipo de asesores")
kpi_row([("22.941", "GESTIONES REALES"),
         ("18.483", "PERSONAS GESTIONADAS"),
         ("14", "ASESORES ACTIVOS"),
         ("1.638", "GESTIONES PROMEDIO")])

par("Contabilizamos como gestión cada tipificación registrada en el histórico del CRM "
    "dentro del mes, excluyendo las cuentas de sistema. Una fila es una gestión, no una "
    "obligación: es el conteo que permite comparar el esfuerzo entre asesores.",
    before=6, after=4)

tabla(
    ["Tipificación aplicada", "Gestiones", "Personas", "% gestión"],
    [["Seguimiento al compromiso de pago", "10.266", "10.030", "44,8%"],
     ["No contesta", "5.974", "5.793", "26,0%"],
     ["Genera acuerdo de pago verbal", "2.994", "2.914", "13,1%"],
     ["Ya realizó el pago por acuerdo", "1.234", "1.197", "5,4%"],
     ["Ya realizó el pago", "1.044", "1.023", "4,6%"],
     ["Envío de correo tras llamada", "676", "667", "3,0%"],
     ["No hay acuerdo de pago", "480", "466", "2,1%"]],
    anchos=[7.6, 2.6, 2.4, 3.8],
    alinear_der=[1, 2, 3],
)
par("", after=3)
vineta("con el conteo corregido la carga va de 986 a 3.388 gestiones por asesor, con un "
       "promedio de 1.638. El asesor más activo concentra el 14,8% del total, muy lejos "
       "del 17,7% que reportamos antes: el equipo está bastante más parejo de lo que "
       "sugería la versión anterior.", "Dispersión del esfuerzo: ")
vineta("una de cada cuatro gestiones (26,0%) termina en «no contesta». Es el mayor punto "
       "de fuga y apunta a calidad del dato de contacto, no a falta de trabajo.",
       "Contactabilidad efectiva: ")

# ================================================================== HOJA 3
D.salto_pagina()

h1("5.  Recaudo atribuible a la gestión")
kpi_row([("9.281", "PAGOS ATRIBUIBLES"),
         ("5.767", "ESTUDIANTES"),
         ("$2.408", "MILLONES"),
         ("$259.537", "TICKET PROMEDIO")])

par("Un pago se atribuye a la gestión cuando la persona fue efectivamente gestionada y "
    "el pago es posterior a la primera gestión sobre ella. Las cifras son lo que los "
    "asesores registraron en el CRM, no el recaudo institucional de caja.",
    before=6, after=4)

par("Conciliación con lo publicado el 2 de septiembre", size=10, bold=True,
    color=AZUL_INST, fuente=TIT, after=3)
tabla(
    ["Concepto", "Pagos", "Estudiantes", "Valor ($ MM)"],
    [["Publicado el 2 de septiembre", "19.002", "11.804", "5.483,9"],
     ["(–) De personas que nadie gestionó", "5.158", "2.963", "1.849,5"],
     ["(–) Pago anterior a la primera gestión", "4.855", "3.519", "1.292,4"],
     ["(=) Atribuible a la gestión del equipo", "9.281", "5.767", "2.408,8"]],
    anchos=[7.4, 2.6, 2.7, 2.8],
    alinear_der=[1, 2, 3],
)
par("", after=3)

par("Recaudo atribuible por periodo académico", size=10, bold=True,
    color=AZUL_INST, fuente=TIT, after=3)
tabla(
    ["Periodo", "Pagos", "Estudiantes", "Valor ($ MM)", "% valor"],
    [["26V02", "2.057", "1.096", "447,7", "18,6%"],
     ["26V03", "1.790", "1.341", "334,1", "13,9%"],
     ["26ES3", "954", "729", "276,4", "11,5%"],
     ["26ES2", "510", "270", "218,7", "9,1%"],
     ["26V04", "831", "637", "201,9", "8,4%"],
     ["Resto de periodos", "3.139", "—", "930,0", "38,5%"]],
    anchos=[3.6, 2.6, 2.9, 2.9, 2.4],
    alinear_der=[1, 2, 3, 4],
)
par("", after=3)
vineta("el rango de 300 a 600 mil pesos aporta $1.127,2 millones, el 46,8% del valor con "
       "el 30% de los pagos. Es la cuota típica del crédito CLTIENE y donde rinde más el "
       "esfuerzo de contacto.", "Concentración del valor: ")

# ================================================================== HOJA 4
# La tabla de liquidacion tiene 19 filas: necesita pagina propia o Word la parte.
D.salto_pagina()

h1("6.  Liquidación por asesor — agosto 2026")
par("Incluimos el detalle nominal por solicitud expresa de la Coordinación, para efectos "
    "de liquidación. Los cuatro asesores con cero gestiones en agosto registran pagos "
    "atribuibles porque la gestión que los originó ocurrió en un mes anterior.",
    after=4)

tabla(
    ["Asesor", "Gestiones", "Personas", "Pagos", "$ MM", "Efect."],
    [["Angie Estefanía Ortiz Ocampo", "3.388", "3.040", "1.006", "265,3", "21,9%"],
     ["Evelyn Julieth Ruiz Mondragón", "1.711", "1.464", "936", "224,7", "39,1%"],
     ["Daniel Steven Cifuentes Mahecha", "2.139", "1.616", "732", "183,3", "27,0%"],
     ["Gizzel Tatiana Rincón Rodríguez", "1.562", "1.350", "700", "177,9", "32,4%"],
     ["Danna Lorena Macías Lozano", "1.618", "1.401", "648", "177,7", "30,6%"],
     ["Yenifer Andrea Salazar Aguirre", "1.229", "841", "595", "171,9", "45,0%"],
     ["Nicolás Pérez Manzanares", "1.510", "1.378", "638", "161,4", "32,2%"],
     ["Carol Alexandra Nieto Bello", "2.120", "1.668", "674", "161,3", "23,9%"],
     ["Ana del Pilar Ávila Murillo", "1.561", "1.254", "594", "149,8", "27,2%"],
     ["Laura Eliana Rivera Díaz", "1.410", "1.164", "620", "147,4", "28,0%"],
     ["María Fernanda Nieto Jiménez", "1.130", "986", "564", "143,7", "39,7%"],
     ["Ginna Magaly Herrera Varela", "1.503", "1.393", "525", "139,8", "23,7%"],
     ["Yaqueline López Casas", "1.074", "962", "465", "124,9", "25,0%"],
     ["Laidy Alejandra Romero Estupiñán", "986", "790", "333", "120,5", "25,1%"],
     ["Ingrid Viviana Lara Pinzón", "0", "0", "111", "21,6", "—"],
     ["Cristian Alexander Sanabria M.", "0", "0", "67", "19,0", "—"],
     ["Delia Fernanda Muñoz Montoya", "0", "0", "54", "13,0", "—"],
     ["Daniel Esteban Ascencio Luna", "0", "0", "19", "5,3", "—"],
     ["TOTAL EQUIPO", "22.941", "18.483", "9.281", "2.408,8", "18,1%"]],
    anchos=[6.2, 2.2, 2.0, 1.9, 2.1, 2.0],
    alinear_der=[1, 2, 3, 4, 5],
)
par("", after=3)
vineta("la efectividad no sigue al volumen. Yenifer Salazar convierte el 45,0% con 1.229 "
       "gestiones, mientras que quien más gestiona convierte el 21,9%. Vale la pena "
       "revisar qué hace distinto el primer grupo antes de pedir más volumen al segundo.",
       "Volumen no es resultado: ")

# ================================================================== HOJA 5
D.salto_pagina()

h1("7.  Campaña de mensajes preventivos (WhatsApp)")
kpi_row([("16.539", "IMPACTOS SIN ASESOR"),
         ("3.073", "PERSONAS CON PAGO"),
         ("$791", "MILLONES (TECHO)"),
         ("0", "MENSAJES SMS")])

par("Además de la gestión telefónica, la Coordinación opera una automatización de envío "
    "de mensajes configurada en Zoho. Aislamos los registros que tienen plantilla "
    "asignada y que ningún asesor gestionó, para que ningún pago se cuente dos veces "
    "entre los dos frentes.", before=6, after=4)

callout(
    "Lo que estas cifras NO prueban",
    ["Los campos «Plantilla» y «Población» describen la automatización configurada, no un "
     "acuse del proveedor. Hoy no podemos establecer si el mensaje salió, en qué fecha, "
     "si fue entregado ni si fue leído: esa información la devuelve la API de WhatsApp "
     "Meta, que aún no está integrada.",
     "Sin fecha de envío tampoco podemos exigir que el pago sea posterior al mensaje, "
     "que es la regla que sí aplicamos a la gestión de los asesores. Por eso los $791,9 "
     "millones son un techo de impacto potencial por coincidencia, no recaudo demostrado, "
     "y no deben compararse de igual a igual contra los $2.408,8 millones del equipo."],
    hexc_borde="C8102E",
)

tabla(
    ["Plantilla", "Segmento", "Momento", "Impactos", "Personas", "$ MM"],
    [["WA_P1_M03", "Nuevos", "3 días después", "3.756", "3.719", "80,0"],
     ["WA_P1_M08", "Nuevos", "8 días después", "2.707", "2.597", "39,7"],
     ["WA_P2_M08", "Antiguos", "8 días después", "2.633", "2.456", "69,9"],
     ["WA_P2_M03", "Antiguos", "3 días después", "2.586", "2.562", "66,7"],
     ["WA_P1_PRE", "Nuevos", "3 días antes", "1.815", "1.781", "168,0"],
     ["WA_P2_PRE", "Antiguos", "3 días antes", "1.449", "1.430", "193,1"],
     ["WA_P1_M01", "Nuevos", "1 día después", "913", "902", "86,1"],
     ["WA_P2_M01", "Antiguos", "1 día después", "680", "673", "88,4"]],
    anchos=[3.4, 2.8, 3.4, 2.4, 2.4, 2.0],
    alinear_der=[3, 4, 5],
)
par("", after=3)

vineta("de las 12 plantillas SMS que define el diseño de la campaña no se registró "
       "ninguna: el 100% de los impactos es WhatsApp. Y del segmento P3 —pagos "
       "parciales— tampoco hay registro; solo operan P1 y P2. O el canal y el segmento "
       "no se activaron, o no se están marcando en el CRM.",
       "Media campaña no aparece: ")
vineta("es tentador concluir que el mensaje preventivo convierte mejor que el de mora, "
       "porque PRE y M01 muestran 42% contra 9% de M03 y M08. No lo reportamos como "
       "hallazgo: esa diferencia se explica por la composición de cada grupo. El campo "
       "de pago solo está diligenciado en las obligaciones que ya salieron de la cartera "
       "activa (92,3% contra 0,1%), y la proporción de esas obligaciones cae justo en ese "
       "orden —M01 98%, PRE 48%, M03 22%, M08 18%—. Lo que se ve es la mezcla, no el "
       "momento del disparo.", "Por qué no decimos que el preventivo rinde más: ")
vineta("comparando dentro de población equivalente, quien tenía plantilla asignada pagó "
       "en 57,1% contra 38,3% de quien no la tenía. La diferencia de 18,8 puntos es "
       "sugerente y justifica sostener la campaña, pero no es causal: la plantilla no se "
       "asigna al azar. Para afirmar causalidad hace falta la fecha de envío.",
       "Lo único comparable hoy: ")

# ================================================================== HOJA 6
# Con salto explicito. Sin el, la seccion 8 arranca en el hueco que deja la tabla
# de liquidacion y Word parte la tabla de semanas por la mitad: el encabezado y la
# fila de gestiones quedan en una pagina y las de pagos y valor en la siguiente.
D.salto_pagina()

h1("8.  Ritmo de la gestión: cuándo se trabaja y cuándo se paga")
kpi_row([("7 días", "MEDIANA CONTACTO → PAGO"),
         ("30,0%", "PAGA EN LOS 3 PRIMEROS DÍAS"),
         ("33,5%", "GESTIÓN EN LA ÚLTIMA SEMANA"),
         ("19,7%", "CONVERSIÓN DEL ACUERDO VERBAL")])

par("Cruzamos la fecha de cada gestión contra la fecha del pago que la sigue. Es el "
    "análisis que faltaba para saber si el esfuerzo está bien colocado en el calendario.",
    before=6, after=4)

tabla(
    ["Tiempo entre el contacto y el pago", "Pagos", "$ MM", "% pagos"],
    [["Mismo día", "742", "221,9", "8,0%"],
     ["1 a 3 días", "2.042", "570,8", "22,0%"],
     ["4 a 7 días", "835", "201,5", "9,0%"],
     ["8 a 15 días", "1.511", "366,0", "16,3%"],
     ["Más de 15 días", "2.078", "500,4", "22,4%"],
     ["Pago anterior al último contacto", "2.073", "548,1", "22,3%"]],
    anchos=[7.4, 2.6, 2.7, 2.8],
    alinear_der=[1, 2, 3],
)
par("", after=3)

par("Distribución del esfuerzo y del resultado dentro del mes", size=10, bold=True,
    color=AZUL_INST, fuente=TIT, after=3)
tabla(
    ["Semana", "1 ago", "3–8 ago", "10–15 ago", "17–22 ago", "24–29 ago", "31 ago"],
    [["Gestiones", "243", "3.574", "4.391", "5.106", "7.690", "1.937"],
     ["Pagos", "161", "2.378", "1.216", "2.449", "2.675", "402"],
     ["Valor ($ MM)", "43,2", "622,8", "329,7", "638,3", "685,3", "89,5"]],
    anchos=[3.0, 2.2, 2.4, 2.6, 2.6, 2.6, 2.2],
    alinear_der=[1, 2, 3, 4, 5, 6],
)
par("", after=3)

vineta("la mediana entre el contacto y el pago es de 7 días, y el 30,0% paga dentro de "
       "los tres primeros. Pero el 33,5% de la gestión del mes se ejecuta en la última "
       "semana: con una mediana de 7 días, buena parte de ese esfuerzo cobra en "
       "septiembre y no alcanza a contarse en el cierre de agosto. Adelantar carga a la "
       "primera quincena no cuesta un peso más y mejora el resultado del mes.",
       "El esfuerzo llega tarde: ")
vineta("«ya realizó el pago» convierte al 61,6%, pero eso no mide gestión: el asesor "
       "aplica esa tipificación porque el pago ya ocurrió. La tipificación que sí "
       "anticipa resultado es «genera acuerdo de pago verbal», con 19,7% de conversión "
       "contra 13,6% del seguimiento simple —una vez y media más—. Ese es el "
       "comportamiento que conviene reforzar en el equipo.",
       "Ojo con la tipificación espejo: ")
vineta("el 22,3% de los pagos ocurre antes del último contacto registrado: el asesor "
       "vuelve a tipificar después de cobrar, para dejar constancia. Es correcto como "
       "práctica, pero obliga a medir la atribución contra la PRIMERA gestión y no "
       "contra la última, que es exactamente el criterio que adoptamos.",
       "Por qué medimos contra la primera gestión: ")

# ================================================================== HOJA 5
D.salto_pagina()

h1("9.  Plan de acción — septiembre 2026")

par("Siete frentes, ordenados por impacto sobre el saldo y por qué tan rápido se "
    "pueden ejecutar. Los cuatro primeros no dependen de terceros.", after=4)

tabla(
    ["#", "Acción", "Meta de septiembre", "Responsable"],
    [["1", "Asignar la cartera de la meta sin responsable",
      "4.034 estudiantes, $1.302,9 MM", "Coordinación"],
     ["2", "Adelantar la carga de gestión a la primera quincena",
      "50% del esfuerzo antes del día 15", "Coordinación"],
     ["3", "Depurar dato de contacto de los «no contesta»",
      "Bajar del 26,0% al 20%", "Coordinación + Analítica"],
     ["4", "Reforzar el cierre de acuerdo de pago verbal",
      "Subir del 19,7% al 25% de conversión", "Coordinación"],
     ["5", "Estrategia distinta para «sin registro de clase»",
      "Subir del 3,2% al 8% de cumplimiento", "Coordinación + Bienestar"],
     ["6", "Nivelar la carga entre los 14 asesores activos",
      "Rango máximo de 2:1 (hoy 3,4:1)", "Coordinación"],
     ["7", "Integrar la API de WhatsApp Meta",
      "Medir envío, entrega y lectura", "Tecnología + Analítica"]],
    anchos=[1.2, 6.4, 5.2, 3.6],
)
par("", after=4)

vineta("82.208 registros de 28.014 personas están marcados «reasignar en CRM» o «sin "
       "asignar», y ninguno registra una sola gestión humana. Cruzados contra la meta "
       "vigente son 4.034 estudiantes con $1.302,9 millones. Mientras no tengan dueño no "
       "entran en ningún indicador ni en ninguna llamada. Es la acción de mayor impacto y "
       "la más rápida: es una decisión de asignación, no un desarrollo.",
       "1. Cartera sin responsable: ")
vineta("un tercio de la gestión se ejecuta en la última semana y la mediana de cobro es "
       "de 7 días, así que ese esfuerzo cobra en septiembre. Es la acción de mejor "
       "relación resultado/costo: no exige más gestiones, sino las mismas antes.",
       "2. Adelantar la carga: ")
vineta("el acuerdo verbal convierte al 19,7% contra 13,6% del seguimiento simple. No "
       "pedimos más llamadas sino que más terminen en un compromiso concreto de fecha y "
       "monto —y sobre población contactable: hoy el 26,0% de la gestión muere en «no "
       "contesta».", "3 y 4. Calidad del contacto: ")
vineta("sin los datos que devuelve la API de WhatsApp Meta no podemos saber si los "
       "mensajes salen, llegan o se leen, y por tanto no podemos medir el retorno de la "
       "campaña ni decidir en qué momento conviene disparar. Es la única acción del plan "
       "que desbloquea una medición, no un resultado.",
       "7. Integrar la API de WhatsApp: ")

h1("10.  Observaciones de la Analítica")
vineta("las cifras de gestión de esta versión salen del histórico de tipificación, que "
       "sí conserva cada movimiento. La versión anterior las tomaba de la foto diaria del "
       "CRM, que se reconstruye en cada corrida. El cambio hace las cifras reproducibles "
       "mes a mes.", "Base de medición: ")
vineta("el robot CUN DIGITAL generó 43.556 tipificaciones en agosto, casi el doble que "
       "todo el equipo humano. No es un problema en sí, pero cualquier indicador que no "
       "lo separe explícitamente queda distorsionado. Ya está separado en el tablero. "
       "Siguen sin diligenciar medio de pago, tipo de cartera y regional en más del 89% "
       "de los registros, lo que impide analizar el recaudo por canal.",
       "Calidad del dato: ")

callout(
    "Recomendación",
    ["Asignar los 4.034 estudiantes de la meta que hoy no tienen responsable ($1.302,9 "
     "millones) antes del cierre de septiembre. Es la única acción del plan que no "
     "depende de terceros y libera cartera que hoy nadie está llamando.",
     "Para la liquidación de agosto, usar la tabla de la sección 6 y no las cifras del "
     "informe anterior: la diferencia por asesor es material."],
    hexc_borde="00859B",
)

par("", after=2)
nota("Fuentes: [Financiera].[Cartera_Meta_Comercial_Historico] y su snapshot de cierre, "
     "[ZOHO].[CRM].[Historico_tipificacion_contact] y [Financiera].[Cartera_CUN_Asesor_"
     "Unico]. Extracción del 3 de septiembre de 2026. Cifras en millones de pesos "
     "colombianos. El detalle por estudiante está en Base_Gestion_Asesores_Agosto_2026.xlsx.")

D.guardar(SALIDA)
print(f"OK -> {SALIDA}")
