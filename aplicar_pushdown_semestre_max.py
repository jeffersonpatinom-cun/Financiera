# -*- coding: utf-8 -*-
"""
Optimizacion: baja el filtro de semestre maximo a Oracle, para no transferir 1,1M de filas
que el ROW_NUMBER de SQL Server iba a descartar igual.

Por que es EXACTO y no una aproximacion
---------------------------------------
El desempate de #PROM es  semestre DESC -> fec_inicio DESC -> PRO_ACUMULADO DESC.
Como `semestre` es la PRIMERA clave, una fila que no este en el semestre maximo del
estudiante no puede ganar nunca. Filtrarlas en Oracle no descarta candidatos posibles:
descarta filas que el ranking ya iba a ignorar. El resultado final es identico.

El desempate por fec_inicio se queda en SQL Server porque Periodos_Calendario es una
tabla de SQL Server; no se puede bajar a Oracle.

NUM_NIV_CURSA es NUMBER(3,0) en Oracle (verificado), asi que su max() es numerico igual
que el TRY_CAST(... AS INT) de SQL Server. No hay desalineacion lexical ('9' > '10').

Guarda del NULL
---------------
max() ignora NULLs: un estudiante con TODOS sus semestres en NULL tendria max_sem = NULL
y "semestre = max_sem" seria falso para todas sus filas -> desapareceria del resultado.
Hoy no existe ninguno (medido: 0), pero la guarda `or (semestre is null and max_sem is null)`
queda puesta porque es gratis y protege si manana entra un registro sin nivel.

Medicion (2026-08-26, mismo servidor, corridas consecutivas)
------------------------------------------------------------
    ACTUAL     1.618.183 filas  304.033 estudiantes  355 s
    PROPUESTA    507.519 filas  304.033 estudiantes  119 s
    Estudiantes perdidos por el filtro: 0
Sobre el SP completo: 21,2 min -> ~17,3 min (-19%).
SALVEDAD: las dos variantes corrieron seguidas, la completa primero, asi que la segunda
pudo aprovechar el cache de Oracle. La reduccion de filas (3,2x) no depende del cache.

Uso:
    .venv/Scripts/python.exe aplicar_pushdown_semestre_max.py <volcado.sql> <salida.sql>
"""
import sys
import io

VIEJO = """                'select DISTINCT C.num_identificacion, A.COD_PERIODO,
                        AP.PRO_ACUMULADO, AP.NUM_NIV_CURSA as semestre
                 from SINU.SRC_HIS_ACADEMICA A
                 INNER JOIN sinu.SRC_ALUM_PROGRAMA B ON A.ID_ALUM_PROGRAMA = B.ID_ALUM_PROGRAMA
                 INNER JOIN SINU.SRC_ALUM_PERIODO AP ON A.ID_ALUM_PROGRAMA = AP.ID_ALUM_PROGRAMA
                                                    AND AP.COD_PERIODO = A.COD_PERIODO
                 INNER JOIN src_enc_matricula M ON M.id_alum_programa = B.id_alum_programa
                                               AND M.cod_periodo = A.cod_periodo
                 INNER JOIN sinu.BAS_TERCERO C ON B.ID_TERCERO = C.ID_TERCERO
                 INNER JOIN SRC_UNI_ACADEMICA E ON E.COD_UNIDAD = B.COD_UNIDAD
                 INNER JOIN bas_dependencia dep ON dep.id_dependencia = E.id_dependencia
                 INNER JOIN SRC_GENERICA D ON D.TIP_TABLA = B.COD_EST_ALUMNO
                                          AND D.COD_TABLA = B.EST_ALUMNO
                 INNER JOIN SRC_GENERICA F ON F.TIP_TABLA = E.COD_NIVEL_FOR
                                          AND F.COD_TABLA = E.NIV_FORMACION') SRC"""

NUEVO = """                -- Oracle filtra al SEMESTRE MAXIMo por estudiante: 1.618.183 -> 507.519 filas.
                -- Exacto, no aproximado: semestre es la PRIMERA clave del ROW_NUMBER de abajo,
                -- asi que una fila fuera del semestre maximo no puede ganar nunca.
                -- El OR ... IS NULL evita que un estudiante con TODOS los semestres en NULL
                -- (max_sem = NULL) desaparezca del resultado. Hoy no hay ninguno; es una guarda.
                'select T2.num_identificacion, T2.COD_PERIODO, T2.PRO_ACUMULADO, T2.semestre
                 from (
                   select T1.num_identificacion, T1.COD_PERIODO, T1.PRO_ACUMULADO, T1.semestre,
                          max(T1.semestre) over (partition by T1.num_identificacion) max_sem
                   from (
                     select DISTINCT C.num_identificacion, A.COD_PERIODO,
                            AP.PRO_ACUMULADO, AP.NUM_NIV_CURSA as semestre
                     from SINU.SRC_HIS_ACADEMICA A
                     INNER JOIN sinu.SRC_ALUM_PROGRAMA B ON A.ID_ALUM_PROGRAMA = B.ID_ALUM_PROGRAMA
                     INNER JOIN SINU.SRC_ALUM_PERIODO AP ON A.ID_ALUM_PROGRAMA = AP.ID_ALUM_PROGRAMA
                                                        AND AP.COD_PERIODO = A.COD_PERIODO
                     INNER JOIN src_enc_matricula M ON M.id_alum_programa = B.id_alum_programa
                                                   AND M.cod_periodo = A.cod_periodo
                     INNER JOIN sinu.BAS_TERCERO C ON B.ID_TERCERO = C.ID_TERCERO
                     INNER JOIN SRC_UNI_ACADEMICA E ON E.COD_UNIDAD = B.COD_UNIDAD
                     INNER JOIN bas_dependencia dep ON dep.id_dependencia = E.id_dependencia
                     INNER JOIN SRC_GENERICA D ON D.TIP_TABLA = B.COD_EST_ALUMNO
                                              AND D.COD_TABLA = B.EST_ALUMNO
                     INNER JOIN SRC_GENERICA F ON F.TIP_TABLA = E.COD_NIVEL_FOR
                                              AND F.COD_TABLA = E.NIV_FORMACION
                   ) T1
                 ) T2
                 where T2.semestre = T2.max_sem
                    or (T2.semestre is null and T2.max_sem is null)') SRC"""


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    origen, destino = sys.argv[1], sys.argv[2]

    with io.open(origen, "r", encoding="utf-8") as fh:
        sql = fh.read()

    n = sql.count(VIEJO)
    if n != 1:
        print("ABORTADO: esperaba 1 ocurrencia del OPENQUERY de #PROM, encontre %d." % n)
        print("El SP cambio respecto de lo esperado. Volver a hacer dump y revisar.")
        sys.exit(1)

    sql = sql.replace(VIEJO, NUEVO, 1)
    print("  OK  OPENQUERY de #PROM filtra al semestre maximo en Oracle")

    # Las comillas simples del literal OPENQUERY deben quedar balanceadas: el string
    # arranca en 'select y cierra en ') SRC. Dentro no hay literales, asi que no puede
    # haber comillas sueltas.
    cuerpo = NUEVO.split("'select", 1)[1].rsplit("')", 1)[0]
    if "'" in cuerpo:
        print("ABORTADO: hay una comilla simple sin escapar dentro del literal OPENQUERY.")
        sys.exit(1)
    print("  OK  literal OPENQUERY con comillas balanceadas")

    with io.open(destino, "w", encoding="utf-8") as fh:
        fh.write(sql)
    print("\nEscrito: %s  (%d chars)" % (destino, len(sql)))


if __name__ == "__main__":
    main()
