# -*- coding: utf-8 -*-
"""
Cierra la brecha entre Usp_Cartera_CUN_Asesor_Unico y la consulta viva de Power BI.

QUE AGREGA (12 columnas)
------------------------
De Cartera_Gestion (ct), que el SP ya tiene unida y solo faltaba proyectar:
    CLASIFICACION_CARTERA, CICLO, MODALIDAD, RES_PERFIL_RIESGO, RES_SCORE,
    RECAUDO_PAGOS_NOMBRE_CAJA, RECAUDO_PAGOS_NOMBRE_FRANQUICIA, AUD_FECHA_PROCESAMIENTO
De Cartera_Destiempo_ZOHO (d):
    MARCA_CARGA_DESTIEMPO
De DBO.Periodos_Calendario (p), JOIN NUEVO:
    METODOLOGIA_PERIODO, FECHA_INICIO, FECHA_FIN

Van al FINAL del SELECT a proposito. La tabla se crea con SELECT INTO, asi que insertar
columnas en medio le cambia el orden posicional a todo consumidor que no lea por nombre.

EL JOIN NUEVO
-------------
    LEFT JOIN DBO.Periodos_Calendario p
           ON p.cod_periodo = c.PERIODO AND p.descripcion_metod = ct.MODALIDAD

La llave es cod_periodo + descripcion_metod, no solo el periodo: esa pareja es unica en la
tabla (759/759) y solo por cod_periodo habria fan-out. Depende de ct.MODALIDAD, por eso el
JOIN va DESPUES del de Cartera_Gestion.

BUG QUE SE CORRIGE DE PASO
--------------------------
El subquery de Cartera_Destiempo_ZOHO hacia MAX(FECHA_REAL_CARGA_NDB) sobre un varchar(10)
con formato dd/MM/yyyy, asi que ordenaba como TEXTO: '31/07/2026' > '09/08/2026'. Medido:
en 7 NUMERO_CREDITO el MAX lexical devuelve una fecha distinta de la correcta. Se pasa a
MAX(TRY_CONVERT(date, ..., 103)) y se reformatea a dd/MM/yyyy para no cambiarle el tipo a
la columna. Es la misma forma que ya usaba la consulta de Power BI.

ORDEN RESPECTO DEL OTRO DESPLIEGUE
----------------------------------
CLASIFICACION_CARTERA se proyecta tal cual viene de Cartera_Gestion. Sus valores solo
incluyen 'CXC REFINANCIADO' despues de que SP_Cartera_Total corra con
alter_sp_cartera_total_cxc_refinanciado.sql. Este SP compila y corre igual antes o despues;
solo cambia el contenido.

Uso:
    .venv/Scripts/python.exe aplicar_columnas_faltantes_asesor_unico.py <entrada.sql> <salida.sql>
"""
import io
import sys

# --- 1) columnas nuevas al final del SELECT --------------------------------------------
SEL_VIEJO = """            a.Asesor_Unico
        INTO Financiera.Cartera_CUN_Asesor_Unico"""

SEL_NUEVO = """            a.Asesor_Unico,
            -- ── Columnas agregadas 2026-08-28 para igualar la consulta viva de Power BI.
            --    Van al final: la tabla se crea con SELECT INTO y meter columnas en medio
            --    le mueve el orden posicional a los consumidores.
            ct.CLASIFICACION_CARTERA,
            ct.CICLO,
            ct.MODALIDAD,
            ct.RES_PERFIL_RIESGO,
            ct.RES_SCORE,
            ct.RECAUDO_PAGOS_NOMBRE_CAJA,
            ct.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
            ct.AUD_FECHA_PROCESAMIENTO,
            d.MARCA_CARGA_DESTIEMPO,
            p.descripcion_metod      AS METODOLOGIA_PERIODO,
            p.fec_inicio             AS FECHA_INICIO,
            p.fec_fin                AS FECHA_FIN
        INTO Financiera.Cartera_CUN_Asesor_Unico"""

# --- 2) destiempo: agregar la marca y corregir el MAX lexical ---------------------------
DEST_VIEJO = """            SELECT NUMERO_CREDITO, MAX(FECHA_REAL_CARGA_NDB) AS FECHA_REAL_CARGA_NDB
            FROM CUN_REPOSITORIO.Financiera.Cartera_Destiempo_ZOHO
            GROUP BY NUMERO_CREDITO"""

DEST_NUEVO = """            /* MAX sobre la FECHA, no sobre el texto. FECHA_REAL_CARGA_NDB es
               varchar(10) dd/MM/yyyy, asi que el MAX lexical daba '31/07' > '09/08':
               en 7 creditos devolvia una fecha distinta de la correcta (medido
               2026-08-28). Se reconvierte a dd/MM/yyyy para no cambiarle el tipo. */
            SELECT NUMERO_CREDITO,
                   CONVERT(varchar(10), MAX(TRY_CONVERT(date, FECHA_REAL_CARGA_NDB, 103)), 103)
                       AS FECHA_REAL_CARGA_NDB,
                   CONVERT(bit, MAX(CONVERT(tinyint, MARCA_CARGA_DESTIEMPO)))
                       AS MARCA_CARGA_DESTIEMPO
            FROM CUN_REPOSITORIO.Financiera.Cartera_Destiempo_ZOHO
            GROUP BY NUMERO_CREDITO"""

# --- 3) JOIN nuevo a Periodos_Calendario ------------------------------------------------
JOIN_VIEJO = """        LEFT JOIN #Tipificacion_Ultima                                       e ON e.cartera_id = CONVERT(varchar(30), c.Id)
        WHERE c.[Número_de_identificación] IS NOT NULL"""

JOIN_NUEVO = """        LEFT JOIN #Tipificacion_Ultima                                       e ON e.cartera_id = CONVERT(varchar(30), c.Id)
        /* Llave COMPLETA periodo + metodologia: la pareja (cod_periodo,
           descripcion_metod) es unica (759/759). Solo por cod_periodo habria
           fan-out. Depende de ct.MODALIDAD, por eso va despues de Cartera_Gestion. */
        LEFT JOIN DBO.Periodos_Calendario                                    p ON p.cod_periodo       = c.PERIODO
                                                                             AND p.descripcion_metod = ct.MODALIDAD
        WHERE c.[Número_de_identificación] IS NOT NULL"""


def reemplazar(texto, viejo, nuevo, etiqueta, esperadas=1):
    n = texto.count(viejo)
    if n != esperadas:
        sys.exit('ABORTA [%s]: se esperaban %d ocurrencias, se encontraron %d.'
                 % (etiqueta, esperadas, n))
    print('  [%s] %d ocurrencia(s) reemplazada(s).' % (etiqueta, n))
    return texto.replace(viejo, nuevo)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    entrada, salida = sys.argv[1], sys.argv[2]

    with io.open(entrada, encoding='utf-8') as fh:
        sql = fh.read()

    original = len(sql)
    sql = reemplazar(sql, SEL_VIEJO,  SEL_NUEVO,  '12 columnas nuevas')
    sql = reemplazar(sql, DEST_VIEJO, DEST_NUEVO, 'destiempo: marca + MAX por fecha')
    sql = reemplazar(sql, JOIN_VIEJO, JOIN_NUEVO, 'JOIN Periodos_Calendario')

    with io.open(salida, 'w', encoding='utf-8') as fh:
        fh.write(sql)

    print('Escrito %s (%d chars, +%d).' % (salida, len(sql), len(sql) - original))


if __name__ == '__main__':
    main()
