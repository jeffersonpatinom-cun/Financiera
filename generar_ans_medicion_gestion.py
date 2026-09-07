# -*- coding: utf-8 -*-
"""ANS de medicion de gestion y recaudo por asesor de cobranza.

Formaliza las reglas de negocio corregidas el 2026-09-03 tras la fe de erratas
del cierre de agosto. Sigue el formato institucional PRC-FOR-010 v2.0
("Firmas acuerdo de nivel de servicio"), el mismo del ANS de Meta de Cobranza.

Por que existe: hasta agosto no habia una definicion escrita de que cuenta como
gestion de un asesor. Cada informe la resolvia por su cuenta con Asesor_Unico, y
eso publico cifras infladas 2,7x. Este ANS fija la definicion.

La identidad visual (colores, tipografias, sombreado de celdas) sale del skill
informes-cartera-word; el "chrome" del formulario ANS -- encabezado con logo, pie
de Elaboro/Reviso/Aprobo y bloque de firmas -- se arma aqui porque es propio de
este formato y no del informe ejecutivo.

LOGO: el formulario original lleva el logo CUN en la celda superior izquierda.
No hay archivo de logo en el repo, asi que se deja el texto de reemplazo. Para
insertarlo, poner la ruta en LOGO y volver a generar.

Uso:  .venv/Scripts/python.exe generar_ans_medicion_gestion.py
"""
import os
import sys

sys.path.insert(0, ".claude/skills/informes-cartera-word")

from docx import Document                                       # noqa: E402
from docx.enum.table import WD_ALIGN_VERTICAL                    # noqa: E402
from docx.enum.text import WD_ALIGN_PARAGRAPH                    # noqa: E402
from docx.shared import Cm, Pt, RGBColor                         # noqa: E402
from estilo_cun import (DocumentoCUN, GRIS_INST,                 # noqa: E402
                        TEXTO, TIT, CUERPO)

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SALIDA = "ANS_Medicion_Gestion_Pagos_Asesores.docx"
LOGO = "logo_cun.png"           # extraido del docx que el coordinador diligencio a mano
FECHA = "07/09/2026"

VERDE_CUN = RGBColor(0x5A, 0xA7, 0x00)      # titulos de seccion del formulario
HEX_CAB = "F2F2F2"
AZUL_SQL = RGBColor(0x1F, 0x49, 0x7D)

fuente = DocumentoCUN.fuente
shade = DocumentoCUN.shade

doc = Document()
normal = doc.styles["Normal"]
normal.font.name = CUERPO
normal.font.size = Pt(9)
normal.font.color.rgb = TEXTO

for s in doc.sections:
    s.top_margin, s.bottom_margin = Cm(1.2), Cm(1.2)
    s.left_margin, s.right_margin = Cm(2.0), Cm(2.0)


def _celda(cell, texto, bold=False, size=8, color=TEXTO, fam=CUERPO,
           align=WD_ALIGN_PARAGRAPH.LEFT):
    cell.text = ""
    p = cell.paragraphs[0]
    p.alignment = align
    p.paragraph_format.space_before = Pt(1)
    p.paragraph_format.space_after = Pt(1)
    fuente(p.add_run(texto), fam, size, bold=bold, color=color)
    return p


def _etiqueta_valor(cell, etiqueta, valor):
    """Celda tipo 'Proceso: Gestion de Apoyo Documental', etiqueta en negrita."""
    cell.text = ""
    p = cell.paragraphs[0]
    p.paragraph_format.space_before = Pt(1)
    p.paragraph_format.space_after = Pt(1)
    fuente(p.add_run(etiqueta), CUERPO, 8, bold=True)
    fuente(p.add_run(valor), CUERPO, 8)


def encabezado():
    """Tabla de cabecera del formulario, repetida en todas las paginas."""
    enc = doc.sections[0].header
    enc.is_linked_to_previous = False
    enc.paragraphs[0].text = ""

    t = enc.add_table(rows=4, cols=3, width=Cm(17.0))
    t.style = "Table Grid"
    anchos = (Cm(3.2), Cm(6.3), Cm(7.5))
    for fila in t.rows:
        for j, w in enumerate(anchos):
            fila.cells[j].width = w

    # Celda del logo: se fusionan las 4 filas de la primera columna.
    logo = t.cell(0, 0).merge(t.cell(3, 0))
    logo.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
    if LOGO and os.path.exists(LOGO):
        logo.text = ""
        logo.paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.CENTER
        logo.paragraphs[0].add_run().add_picture(LOGO, width=Cm(2.6))
    else:
        _celda(logo, "[ logo CUN ]", size=7.5, color=GRIS_INST,
               align=WD_ALIGN_PARAGRAPH.CENTER)

    titulo = t.cell(0, 1).merge(t.cell(3, 1))
    titulo.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
    _celda(titulo, "Firmas acuerdo de nivel de servicio (ANS)", bold=True,
           size=11, fam=TIT, align=WD_ALIGN_PARAGRAPH.CENTER)

    for i, (et, val) in enumerate([
            ("Proceso: ", "Gestión de Apoyo Documental"),
            ("Área: ", "Dirección De Planeación y Gestión"),
            ("Código: ", "PRC-FOR-010"),
            ("Versión: ", "2.0")]):
        _etiqueta_valor(t.cell(i, 2), et, val)


def pie():
    p_ = doc.sections[0].footer
    p_.is_linked_to_previous = False
    p_.paragraphs[0].text = ""
    t = p_.add_table(rows=1, cols=3, width=Cm(17.0))
    t.style = "Table Grid"
    for j, (txt, w) in enumerate([
            ("Elaboró: Especialista de Procesos", Cm(5.0)),
            ("Revisó: Dirección de Planeación y Gestión", Cm(6.5)),
            ("Aprobó: Director de Planeación y Gestión", Cm(5.5))]):
        t.rows[0].cells[j].width = w
        _celda(t.rows[0].cells[j], txt, size=7.5)


def h_seccion(texto, before=12):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(before)
    p.paragraph_format.space_after = Pt(5)
    fuente(p.add_run(texto), TIT, 10.5, bold=True, color=VERDE_CUN)


def par(texto, size=9, before=0, after=5, bold=False, italic=False,
        color=TEXTO, fam=CUERPO):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(before)
    p.paragraph_format.space_after = Pt(after)
    p.paragraph_format.line_spacing = 1.12
    fuente(p.add_run(texto), fam, size, bold=bold, italic=italic, color=color)
    return p


def rotulo(etiqueta, texto, before=6):
    """Parrafo con etiqueta en negrita, como '- Nombre del servicio: ...'."""
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(before)
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.12
    fuente(p.add_run(etiqueta), CUERPO, 9, bold=True)
    fuente(p.add_run(texto), CUERPO, 9)


def bullet(texto, negrita_hasta=None, nivel=0):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(0.8 + 0.5 * nivel)
    p.paragraph_format.space_before = Pt(2)
    p.paragraph_format.space_after = Pt(3)
    p.paragraph_format.line_spacing = 1.1
    fuente(p.add_run("•   "), CUERPO, 9, color=VERDE_CUN, bold=True)
    if negrita_hasta:
        fuente(p.add_run(negrita_hasta), CUERPO, 9, bold=True)
    fuente(p.add_run(texto), CUERPO, 9)


def numerado(n, titulo, texto):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(0.8)
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(3)
    p.paragraph_format.line_spacing = 1.12
    fuente(p.add_run("%d.  " % n), CUERPO, 9, bold=True)
    fuente(p.add_run(titulo), CUERPO, 9, bold=True)
    fuente(p.add_run(texto), CUERPO, 9)


def codigo(lineas):
    """Bloque de SQL, en azul y monoespaciado como en el ANS original."""
    for i, ln in enumerate(lineas):
        p = doc.add_paragraph()
        p.paragraph_format.left_indent = Cm(0.8)
        p.paragraph_format.space_before = Pt(4 if i == 0 else 0)
        p.paragraph_format.space_after = Pt(4 if i == len(lineas) - 1 else 0)
        p.paragraph_format.line_spacing = 1.0
        fuente(p.add_run(ln), "Consolas", 8, color=AZUL_SQL)


def _no_partir(t):
    """Impide que Word corte una fila a la mitad y repite el encabezado.

    Sin esto, la tabla de tiempos dejaba una fila huerfana en la pagina
    siguiente, debajo del encabezado del formulario.
    """
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    for i, fila in enumerate(t.rows):
        trPr = fila._tr.get_or_add_trPr()
        cant = OxmlElement("w:cantSplit")
        trPr.append(cant)
        if i == 0:
            th = OxmlElement("w:tblHeader")
            trPr.append(th)


def tabla(headers, filas, anchos, size=8):
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = "Table Grid"
    for j, h in enumerate(headers):
        c = t.rows[0].cells[j]
        c.width = Cm(anchos[j])
        shade(c, HEX_CAB)
        _celda(c, h, bold=True, size=size)
    for fila in filas:
        cells = t.add_row().cells
        for j, v in enumerate(fila):
            cells[j].width = Cm(anchos[j])
            _celda(cells[j], v, size=size)
    _no_partir(t)
    return t


# ══════════════════════════════════════════════════════════ documento
encabezado()
pie()

par(FECHA, size=9, after=8)

# ---- Cliente / Proveedor
tabla(["Cliente", "Proveedor"],
      [["Vicerrectoría Financiera\nCoordinación Financiera\n"
        "Coordinador de Recaudo y Permanencia",
        "Vicerrectoría de Servicios Digitales\nCoordinación de Analítica\n"
        "Aura Rosa Henao Santana"]],
      anchos=[8.5, 8.5], size=8.5)

h_seccion("Objetivo del ANS")
par("Establecer las reglas de negocio, los términos y las condiciones bajo los cuales el área "
    "proveedora (Coordinación de Analítica Financiera — Ingeniería de Desarrollo Financiero) "
    "calcula, publica y comunica mensualmente la medición de la gestión de cobranza y del "
    "recaudo atribuible a cada asesor, para que el área cliente (Dirección Financiera — Gestión "
    "de Cartera) realice el seguimiento del equipo y como referencia para la liquidación "
    "del período con una definición única, verificable y reproducible.")
par("Este acuerdo complementa el ANS de «Meta mensual de cartera estudiantil vencida»: aquel "
    "define QUÉ cartera se debe gestionar; este define CÓMO se mide la gestión ejecutada sobre "
    "ella y qué recaudo se le atribuye a cada asesor.")
rotulo("Alcance de los entregables: ",
       "el informe mensual en Word y la base en Excel son MATERIAL DE REFERENCIA. Entregan una medición homogénea, verificable y auditable de la gestión "
       "ejecutada y del recaudo atribuible, para que el Coordinador de Recaudo y Permanencia la "
       "tome como insumo base y adelante el proceso que corresponda conforme a las reglas de "
       "liquidación de comisiones definidas por el área encargada. Analítica Financiera no calcula "
       "comisiones, no define sus reglas ni emite concepto sobre su aplicación.")

# ══════════════════════════════════════════ 1
h_seccion("1. Servicio o Entregable")
rotulo("- Nombre del servicio o producto entregable: ",
       "Medición mensual de gestión de cobranza y recaudo atribuible por asesor — "
       "CUN_REPOSITORIO")
par("Entregables específicos:", bold=True, before=6, after=3)

numerado(1, "Columnas de medición en la tabla materializada → ",
         "Analítica Financiera expone en [Financiera].[Cartera_CUN_Asesor_Unico], actualizada "
         "por job diario, las columnas GESTION_ASESOR, GESTION_MARCA, GESTION_FECHA_PRIMERA, "
         "GESTION_FECHA_ULTIMA y GESTION_PAGO_POST_MARCA. Son la fuente única para cualquier "
         "indicador de gestión, tablero o informe.")
numerado(2, "Informe ejecutivo de cierre mensual → ",
         "documento Word con el cumplimiento de la meta, la gestión del equipo en agregado, el "
         "recaudo atribuible, el ritmo de la gestión y el plan de acción del mes siguiente. Es material "
         "de referencia para el seguimiento del equipo, no un acto de liquidación.")
numerado(3, "Base de gestión por asesor → ",
         "archivo Excel con el detalle nominal por asesor (gestiones, personas gestionadas, "
         "pagos atribuibles y valor). Constituye el insumo base sobre el cual el área encargada "
         "aplica sus reglas de liquidación de comisiones; no incluye cálculo de comisión alguno. "
         "Contiene datos "
         "personales de estudiantes y de empleados, por lo que se entrega por canal interno y "
         "no se publica en repositorios ni se versiona en control de código.")

rotulo("- Descripción del servicio o producto:", "")
par("Analítica Financiera determina, para cada estudiante, si fue efectivamente gestionado por "
    "un asesor y qué pagos son atribuibles a esa gestión. La gestión se lee del histórico de "
    "tipificación del CRM ([ZOHO].[CRM].[Historico_tipificacion_contact]), que es la única "
    "fuente que registra QUIÉN ejecutó cada movimiento, y se materializa en la tabla de cartera "
    "para consumo de tableros e informes.")

rotulo("- Regla SQL de gestión efectiva (quién gestionó):", "")
codigo([
    "FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e",
    "JOIN ZOHO.CRM.Cartera_CUN c",
    "     ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)",
    "WHERE e.Hecho_por IS NOT NULL",
    "  AND UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%'  -- cuenta de sistema, no es asesor",
    "  AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'      -- cuenta de coordinación",
    "-- Equivalente sobre la tabla materializada:  WHERE GESTION_MARCA = 1",
])

rotulo("- Regla SQL de recaudo atribuible (qué pago cuenta):", "")
codigo([
    "FROM [Financiera].[Cartera_CUN_Asesor_Unico]",
    "WHERE GESTION_PAGO_POST_MARCA = 1   -- persona gestionada Y pago posterior",
    "  AND TRY_CONVERT(date, Fecha_de_pago, 103) BETWEEN @inicio AND @fin",
    "-- La marca exige que el pago sea posterior a GESTION_FECHA_PRIMERA.",
])

# ══════════════════════════════════════════ 2
h_seccion("2. Características del Servicio o Entregable")
par("El área proveedora se compromete a aplicar las siguientes reglas de negocio, sin excepción "
    "y de forma idéntica en todos los informes y tableros:", after=4)

bullet("una gestión es una tipificación registrada en el histórico del CRM por una persona. El "
       "asesor es el campo Hecho_por de esa tipificación.", "Definición de gestión: ")
bullet("las tipificaciones de las cuentas de sistema CUN DIGITAL y PENAGOS no son gestión de "
       "asesor y se excluyen. Representan el 54,3% del histórico; en agosto de 2026 fueron "
       "42.768 de las 65.709 tipificaciones del mes.",
       "Exclusión de cuentas automáticas: ")
bullet("el campo Asesor_Unico NO se usa para medir gestión. Está diseñado para nunca quedar "
       "vacío: cuando nadie ha tipificado, cae al usuario que modificó el registro o al "
       "propietario asignado de la cartera, de modo que atribuye trabajo a asesores que jamás "
       "gestionaron. Su uso correcto es responder de quién es la cartera: asignación, reparto, "
       "cuartiles y cartera sin responsable.", "Prohibición expresa: ")
bullet("la gestión se resuelve por número de identificación del estudiante, no por obligación. "
       "Una cédula pertenece a un asesor sin importar cuántas cuotas tenga, en coherencia con la "
       "lógica de cobro vigente.", "Grano de medición: ")
bullet("un pago se atribuye a la gestión cuando la persona fue efectivamente gestionada y la "
       "fecha del pago es igual o posterior a la de la PRIMERA gestión sobre ella. Se mide "
       "contra la primera y no contra la última porque el 22,3% de los pagos ocurre antes del "
       "último contacto registrado: el asesor vuelve a tipificar después de cobrar, para dejar "
       "constancia.", "Atribución de pago: ")
bullet("las cifras de pago corresponden a lo que los asesores registran en el CRM y se rotulan "
       "siempre como «registrado en CRM» o «atribuible a la gestión». No equivalen al recaudo "
       "institucional de caja, que se contabiliza por otra vía.",
       "Naturaleza del dato de pago: ")
bullet("el informe ejecutivo reporta el equipo en agregado y no nombra asesores. El detalle "
       "nominal se entrega únicamente en la base de trabajo del coordinador, por solicitud "
       "expresa y por canal interno, por tratarse de evaluación de personal.",
       "Confidencialidad del detalle nominal: ")
bullet("los entregables son material de referencia. Analítica Financiera mide y publica la "
       "gestión ejecutada y el recaudo atribuible con una definición única; la liquidación de "
       "comisiones la realiza el área encargada aplicando sus propias reglas sobre esa base. "
       "Este ANS no define, no calcula ni valida comisiones, y ninguna cifra aquí publicada "
       "constituye por sí misma una liquidación.",
       "Separación de responsabilidades: ")
bullet("cualquier cambio en estas definiciones se documenta en las reglas de negocio y se "
       "comunica a la contraparte antes de publicar cifras bajo el criterio nuevo. Un cambio de "
       "criterio que altere una cifra ya entregada obliga a emitir fe de erratas.",
       "Trazabilidad de los cambios: ")

# ══════════════════════════════════════════ 3
# La tabla de tiempos no cabe en el resto de la pagina 2 y Word la parte.
doc.add_page_break()
h_seccion("3. Tiempos de Entrega", before=6)
par("Las partes acuerdan los siguientes plazos:", after=5)
tabla(["Actividad", "Responsable", "Plazo / Condición"],
      [["Actualización de las columnas de medición", "Analítica Financiera",
        "Diaria, por job automático. La medición del mes queda en firme el primer día "
        "calendario del mes siguiente."],
       ["Entrega del informe ejecutivo de cierre", "Analítica Financiera",
        "3.er día hábil de cada mes. Se notifica por correo a oscar_penagos@cun.edu.co con el "
        "informe y la base de gestión adjuntos."],
       ["Entrega de la base nominal para liquidación", "Analítica Financiera",
        "Junto con el informe ejecutivo, por canal interno."],
       ["Observaciones o solicitud de ajuste", "Coordinador de Recaudo y Permanencia",
        "Dos (2) días hábiles después de recibir el informe. Pasado ese plazo las cifras se "
        "consideran aceptadas para liquidación."],
       ["Emisión de fe de erratas, si aplica", "Analítica Financiera",
        "Dentro de los dos (2) días hábiles siguientes a la detección del error, indicando "
        "cifra publicada, cifra corregida y causa."]],
      anchos=[4.8, 3.6, 8.6])

par("", after=3)
rotulo("Correo de notificación de Analítica Financiera: ", "jefferson_patinom@cun.edu.co")
rotulo("Fuente de datos: ", "[Financiera].[Cartera_CUN_Asesor_Unico] y "
       "[ZOHO].[CRM].[Historico_tipificacion_contact], en CUN_REPOSITORIO.", before=2)

# ══════════════════════════════════════════ 4
h_seccion("4. Limitaciones declaradas")
par("El área proveedora deja constancia de lo que la medición NO puede establecer con la "
    "información disponible a la fecha de este acuerdo:", after=4)

bullet("la tabla del CRM es una fotografía del día y se reconstruye en cada corrida. Lo "
       "tipificado en un mes y sobrescrito después no es recuperable desde ella; por eso la "
       "gestión se lee del histórico, que sí conserva cada movimiento.",
       "Fotografía diaria: ")
bullet("la campaña de mensajes preventivos se mide por los campos Plantilla y Población, que "
       "describen la automatización configurada en Zoho, no un acuse del proveedor. No es "
       "posible establecer si el mensaje se envió, en qué fecha, si fue entregado ni si fue "
       "leído, porque esa información la devuelve la API de WhatsApp Meta y aún no está "
       "integrada. Mientras no lo esté, las cifras de la campaña se reportan como techo de "
       "impacto potencial por coincidencia y no como recaudo demostrado, y no son comparables "
       "de igual a igual con la gestión de los asesores.", "Campaña de mensajes: ")
bullet("sin fecha de envío no se puede exigir a la campaña la misma regla de anterioridad que "
       "se aplica a los asesores, por lo que su atribución es estrictamente más débil.",
       "Ausencia de fecha de envío: ")
bullet("la efectividad relaciona gestión con pago registrado, pero no establece causalidad: no "
       "hay asignación aleatoria ni grupo de control construido para ese fin.",
       "Alcance de la efectividad: ")

par("", after=4)
par("NOTA: En caso de requerir un cambio al ANS se debe notificar a su contraparte y la "
    "Dirección de Planeación.", bold=True, size=8.5, before=6)

# ══════════════════════════════════════════ firmas
doc.add_page_break()
t = doc.add_table(rows=1, cols=2)
t.style = "Table Grid"
for j, area in enumerate(["Área Solicitante", "Área Proveedora"]):
    c = t.rows[0].cells[j]
    c.width = Cm(8.5)
    c.text = ""
    _celda(c, area, bold=True, size=9)
    for campo in ("Firma:", "Nombre:", "Fecha:"):
        p = c.add_paragraph()
        p.paragraph_format.space_before = Pt(10)
        p.paragraph_format.space_after = Pt(2)
        fuente(p.add_run(campo + "  "), CUERPO, 9)
        fuente(p.add_run("_" * 30), CUERPO, 9, color=GRIS_INST)

doc.save(SALIDA)
print("OK -> %s" % SALIDA)
