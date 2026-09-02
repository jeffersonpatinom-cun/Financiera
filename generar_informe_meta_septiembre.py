"""Informe ejecutivo (2 hojas) de la Meta Comercial de septiembre 2026.

Destinatario: Coordinacion de Recaudo y Cartera.
Fuente de los datos: corrida del JOB_USP_Foto_Meta_Comercial_Mensual del
2026-09-01 07:40 sobre [Financiera].[Cartera_Meta_Comercial_Historico],
validada con analisis_meta_septiembre_2026.sql.

Estilo: Lineamientos_Visuales_y_Comunicacion_CUN_Word.md
"""
import sys

sys.path.insert(0, ".claude/skills/informes-cartera-word")
from docx.shared import Pt                                       # noqa: E402
from estilo_cun import (DocumentoCUN, AZUL_MARINO, AZUL_INST,    # noqa: E402
                        TURQUESA, TEXTO, TIT, CUERPO)

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SALIDA = "Informe_Ejecutivo_Meta_Comercial_Septiembre_2026.docx"

# La identidad visual CUN vive en el skill informes-cartera-word; aqui solo va el
# contenido. Los nombres cortos se rebindean para no reescribir cada llamada.
D = DocumentoCUN()
doc = D.doc
_fuente = D.fuente
par, h1, vineta, tabla = D.par, D.h1, D.vineta, D.tabla
callout, kpi_row, nota, linea_acento = D.callout, D.kpi_row, D.nota, D.linea_acento

# ------------------------------------------------------------------ HOJA 1
par("INFORME EJECUTIVO", size=9.5, bold=True, color=TURQUESA, fuente=TIT, after=1)
par("Meta Comercial de Cartera — Septiembre 2026", size=19, bold=True,
    color=AZUL_MARINO, fuente=TIT, after=2)
linea_acento(after=6)

p = doc.add_paragraph()
p.paragraph_format.space_after = Pt(8)
_fuente(p.add_run("Dirigido a: "), CUERPO, 9, bold=True, color=AZUL_INST)
_fuente(p.add_run("Óscar Penagos — Coordinación de Recaudo y Cartera     "),
        CUERPO, 9, color=TEXTO)
_fuente(p.add_run("Corte: "), CUERPO, 9, bold=True, color=AZUL_INST)
_fuente(p.add_run("1 de septiembre de 2026     "), CUERPO, 9, color=TEXTO)
_fuente(p.add_run("Elaboró: "), CUERPO, 9, bold=True, color=AZUL_INST)
_fuente(p.add_run("Analítica financiera CUN"), CUERPO, 9, color=TEXTO)

callout(
    "Conclusión",
    ["La meta de septiembre quedó conformada por 56.269 obligaciones de 24.474 estudiantes, "
     "por $16.527,3 millones. La generación automática se ejecutó sin novedades y los "
     "controles de integridad cuadran en su totalidad. Tres cuartas partes del saldo (74,3%) "
     "corresponde a cartera que ya venía en gestión y el 49% de las obligaciones lleva los "
     "cuatro meses del ciclo sin salir: ese es el núcleo del esfuerzo de recuperación."],
)

h1("1.  Resultado de la generación automática")
par("Ejecutamos el proceso programado el 1 de septiembre a las 07:40, con una duración de "
    "8 minutos 58 segundos y finalización correcta. Antes de refrescar la meta se tomó la foto "
    "mensual de respaldo de 65.456 registros, de modo que el estado con el que cerró agosto "
    "queda preservado para comparaciones posteriores.", after=4)
vineta("15.405 obligaciones nuevas más 40.864 acumuladas equivalen exactamente a las 56.269 "
       "marcadas en septiembre; el histórico no presenta créditos duplicados sobre 80.861 "
       "registros, ni marcas de mes ausentes o repetidas.", "Controles de integridad: ")

h1("2.  Tamaño de la meta")
kpi_row([("56.269", "OBLIGACIONES"),
         ("24.474", "ESTUDIANTES"),
         ("$16.527", "MILLONES"),
         ("$293.720", "TICKET PROMEDIO")])
par("Cada estudiante concentra en promedio 2,30 cuotas en mora: un solo contacto efectivo "
    "resuelve más de dos registros de la meta.", before=5, after=4)

h1("3.  Composición y movimiento del mes")
tabla(
    ["Concepto", "Obligaciones", "Estudiantes", "Saldo ($ MM)", "% saldo"],
    [["Cartera de arrastre (ya venía en la meta)", "40.864", "15.007", "12.274,6", "74,3%"],
     ["Ingresos nuevos de septiembre", "15.405", "15.324", "4.252,7", "25,7%"],
     ["Total meta septiembre", "56.269", "24.474", "16.527,3", "100,0%"]],
    anchos=[7.4, 2.5, 2.4, 2.5, 1.6],
    alinear_der=[1, 2, 3, 4],
)
par("", after=2)
vineta("9.289 obligaciones de 6.248 estudiantes, por $2.769,5 millones, salieron de la meta "
       "entre agosto y septiembre por pago o normalización.", "Salidas del mes: ")
vineta("27.619 obligaciones ($8.808,3 millones, el 49,1% del total) permanecen en la meta "
       "desde junio sin haber salido ningún mes.", "Permanencia crítica: ")
vineta("al 2 de septiembre ya salieron 1.793 obligaciones de 1.473 estudiantes "
       "por $479,7 millones.", "Avance temprano: ")

par("Periodos académicos con mayor participación", size=10, bold=True, color=AZUL_INST,
    fuente=TIT, after=3, before=8)
tabla(
    ["Periodo", "26V02", "26V01", "26V03", "26V04", "26ES3", "2026C", "Resto"],
    [["Obligaciones", "11.792", "11.474", "9.145", "6.307", "3.343", "2.918", "11.290"],
     ["Saldo ($ MM)", "3.052,2", "3.135,6", "1.893,5", "1.470,6", "982,1", "1.042,1", "4.951,2"]],
    anchos=[2.8, 1.9, 1.9, 1.9, 1.9, 1.9, 1.9, 1.9],
    alinear_der=[1, 2, 3, 4, 5, 6, 7],
)

# ------------------------------------------------------------------ HOJA 2
doc.add_page_break()

h1("4.  Priorización de la gestión")
par("La meta se reparte en cuatro cuartiles por saldo acumulado y antigüedad de vencimiento: "
    "Q1 agrupa lo más vencido y Q4 lo más reciente. Cada cuartil concentra exactamente el 25% "
    "del saldo, de modo que las cuatro cargas de trabajo son equivalentes.", after=4)

tabla(
    ["Cuartil", "Obligaciones", "Saldo ($ MM)", "% saldo", "Lectura de gestión"],
    [["Q1", "12.471", "4.131,4", "25,0%", "Mayor antigüedad — prioridad de contacto"],
     ["Q2", "13.653", "4.132,1", "25,0%", "Mora consolidada"],
     ["Q3", "15.231", "4.131,9", "25,0%", "Mora intermedia"],
     ["Q4", "14.914", "4.131,8", "25,0%", "Vencimiento reciente — mayor recuperabilidad"]],
    anchos=[1.7, 2.4, 2.4, 1.6, 8.3],
    alinear_der=[1, 2, 3],
)

par("Clasificación académica del deudor", size=10, bold=True, color=AZUL_INST,
    fuente=TIT, after=3, before=7)
tabla(
    ["Marca académica", "Obligaciones", "Estudiantes", "Saldo ($ MM)", "% saldo"],
    [["Periodo en curso", "24.955", "15.125", "6.529,0", "39,5%"],
     ["Sin registro de clase", "13.059", "3.497", "3.696,6", "22,4%"],
     ["Gestionable", "10.195", "3.396", "3.533,0", "21,4%"],
     ["Periodo perdido, prioridad alta", "7.949", "2.432", "2.729,5", "16,5%"],
     ["Periodo no ha iniciado", "111", "108", "39,1", "0,2%"]],
    anchos=[7.4, 2.5, 2.4, 2.5, 1.6],
    alinear_der=[1, 2, 3, 4],
)
nota("7.535 obligaciones por $2.511,2 millones suman perfil crediticio adverso y deben "
     "escalarse dentro de su marca.")

h1("5.  Antigüedad de la mora y concentración")
tabla(
    ["Rango de mora", "1–30", "31–60", "61–90", "91–120", "121–150", "151–360"],
    [["Obligaciones", "15.432", "8.811", "9.531", "8.695", "6.949", "6.846"],
     ["% del saldo", "25,8%", "13,6%", "16,8%", "16,3%", "13,3%", "14,2%"]],
    anchos=[3.4, 2.2, 2.2, 2.2, 2.2, 2.2, 2.2],
    alinear_der=[1, 2, 3, 4, 5, 6],
)
vineta("solo 5 obligaciones superan los 360 días. La meta es cartera joven y por tanto "
       "recuperable; el esfuerzo debe concentrarse antes de que los tramos de 121 a 360 "
       "días sigan creciendo.", "Sin cola larga: ")
vineta("el 99,4% de los deudores figura como estudiante activo: es población vigente, no "
       "desertores. La contactabilidad es completa en correo, con apenas 9 registros sin "
       "celular y 24 sin WhatsApp sobre 56.269.", "Población y contacto: ")

h1("6.  Observaciones de la Analítica para la Coordinación")
vineta("30,4% de las obligaciones (5.009 estudiantes, $3.696,6 millones) registra promedio "
       "acumulado inferior a 1,55 y queda como «sin registro de clase». Son matriculados sin "
       "calificación; sugerimos validarlo con Registro y Control antes de definir el guion de "
       "cobro de ese grupo.", "Calidad del dato académico: ")
vineta("el 85,7% de las obligaciones tiene promedio acumulado; el resto se prioriza por "
       "calendario y conexión a plataforma.", "Cobertura académica: ")
vineta("la foto de respaldo de agosto se tomó el día 27 y no el día 1, por lo que ese primer "
       "punto no es comparable con el de septiembre; desde este mes la serie queda homogénea.",
       "Serie histórica: ")

par("", after=2)
callout(
    "Recomendación",
    ["Priorizar el cruce entre Q1 y la marca «periodo perdido, prioridad alta» con perfil "
     "crediticio adverso: es el segmento donde coinciden mayor antigüedad, deterioro "
     "académico y deterioro crediticio, abordando la gestión por estudiante y no por "
     "obligación."],
    hexc_borde="00859B",
)

par("", after=2)
nota("Fuente: [Financiera].[Cartera_Meta_Comercial_Historico], extracción del 2 de "
     "septiembre de 2026. Cifras en millones de pesos colombianos.")

D.guardar(SALIDA)
print(f"OK -> {SALIDA}")
