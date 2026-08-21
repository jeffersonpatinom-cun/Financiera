# -*- coding: utf-8 -*-
"""Aplica la nueva logica de MARCA_ACADEMICA aprobada por Coordinacion de Cartera.

Cambios sobre Financiera.SP_Cartera_Total:
  1. Segmento empresarial como primera rama de la escalera (MARCA_BASE).
  2. Corte de aprobacion academica 2.95 -> 3.0.
  3. Refinamiento por riesgo: 'Riesgo Alto' -> 'Riesgo Alto' + 'Riesgo Regular'.
  4. Nueva columna MARCA_ACADEMICA_DETALLE, propagada a Cartera_Total y Cartera_Gestion
     (Cartera_Foto_Ayer la hereda porque se crea con SELECT *).

Genera el archivo alter_sp_cartera_total_marca_v2.sql; NO lo despliega.
"""
import io
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

SRC = 'SP_Cartera_Total_BASELINE_20260821.sql'
OUT = 'alter_sp_cartera_total_marca_v2.sql'
ORIGINAL = open(SRC, encoding='utf-8').read()
d = ORIGINAL
n_ok = 0


def rep(viejo, nuevo, etiqueta, esperado=1):
    """Reemplazo exacto con verificacion de unicidad: si el texto no aparece
    exactamente 'esperado' veces, aborta sin escribir nada."""
    global d, n_ok
    c = d.count(viejo)
    if c != esperado:
        print('  [FALLO] %-42s encontrado %d veces (esperado %d)' % (etiqueta, c, esperado))
        sys.exit(1)
    d = d.replace(viejo, nuevo)
    n_ok += 1
    print('  [OK]    %s' % etiqueta)


# ---------------------------------------------------------------- 1) CROSS APPLY MARCA_BASE
VIEJO_1 = """        CROSS APPLY (VALUES (
                CASE
                        WHEN C.ESTADO = 'ACTIVO'                   THEN 'PERIODO EN CURSO'
                        WHEN C.ESTADO = 'PERIODO NO HA INICIADO'   THEN 'PERIODO NO HA INICIADO'

                        WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  1.55  THEN 'SIN REGISTRO DE CLASE'
                        WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <= 2.95  THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                        WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) >  2.95  THEN 'GESTIONABLE'"""

NUEVO_1 = """        CROSS APPLY (VALUES (
                CASE
                        -- 0) Segmento no estudiantil (empresas, convenios, colaboradores).
                        --    Se evalua PRIMERO: un NIT no tiene notas, ni plataforma, ni periodo
                        --    academico. Aplicarle la lectura academica produce marcas sin sentido.
                        WHEN ISNULL(A.NOMBRE_TIPO_CLIENTE,'') <> 'ESTUDIANTES'
                                                                      THEN 'CARTERA EMPRESARIAL'

                        WHEN C.ESTADO = 'ACTIVO'                   THEN 'PERIODO EN CURSO'
                        WHEN C.ESTADO = 'PERIODO NO HA INICIADO'   THEN 'PERIODO NO HA INICIADO'

                        WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  1.55  THEN 'SIN REGISTRO DE CLASE'
                        WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  3.0   THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                        WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) >= 3.0   THEN 'GESTIONABLE'"""

rep(VIEJO_1, NUEVO_1, '1) CROSS APPLY MARCA_BASE (segmento + corte 3.0)')

# ---------------------------------------------------------------- 2) Riesgo adverso + DETALLE
VIEJO_2 = """                -- MARCA_ACADEMICA: marca académica base (MB.MARCA_BASE, ver CROSS APPLY abajo)
                -- REFINADA con el riesgo financiero de Financiaciones_CTAYUDA_V2:
                --   Un caso académicamente 'blando' (GESTIONABLE) pero con RES_PERFIL_RIESGO = 'Riesgo Alto'
                --   se escala a 'PERIODO PERDIDO, PRIORIDAD ALTA' para priorizar la gestión de cobro.
                --   El resto conserva su marca académica base sin alterar.
                CASE
                        WHEN MB.MARCA_BASE = 'GESTIONABLE' AND F.RES_PERFIL_RIESGO = 'Riesgo Alto'
                                THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                        ELSE MB.MARCA_BASE
                END AS MARCA_ACADEMICA,"""

NUEVO_2 = """                -- MARCA_ACADEMICA: marca académica base (MB.MARCA_BASE, ver CROSS APPLY abajo)
                -- REFINADA con el riesgo financiero de Financiaciones_CTAYUDA_V2:
                --   Un caso académicamente 'blando' (GESTIONABLE) con perfil crediticio ADVERSO
                --   se escala a 'PERIODO PERDIDO, PRIORIDAD ALTA' para priorizar la gestión de cobro.
                --   Riesgo adverso = 'Riesgo Alto' + 'Riesgo Regular' (score < 670), que es la
                --   frontera de la propia escala del buró entre Regular (<=668) y Bueno (>=670).
                --   El resto conserva su marca académica base sin alterar.
                CASE
                        WHEN MB.MARCA_BASE = 'GESTIONABLE'
                         AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                                THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                        ELSE MB.MARCA_BASE
                END AS MARCA_ACADEMICA,
                -- MARCA_ACADEMICA_DETALLE: abre cada marca según el riesgo crediticio y la
                -- evidencia de conexión. NO sustituye a MARCA_ACADEMICA (el tablero sigue
                -- leyendo esa); ordena la cola de trabajo del asesor dentro de cada marca.
                CASE
                        WHEN MB.MARCA_BASE = 'CARTERA EMPRESARIAL'
                                THEN 'CARTERA EMPRESARIAL - ' + ISNULL(NULLIF(LTRIM(RTRIM(A.NOMBRE_TIPO_CLIENTE)),''),'SIN DATO')

                        WHEN MB.MARCA_BASE = 'PERIODO NO HA INICIADO'
                                THEN 'PERIODO NO HA INICIADO'

                        WHEN MB.MARCA_BASE = 'PERIODO EN CURSO'
                         AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                                THEN 'PERIODO EN CURSO - RIESGO CREDITICIO'
                        WHEN MB.MARCA_BASE = 'PERIODO EN CURSO'
                                THEN 'PERIODO EN CURSO'

                        WHEN MB.MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA'
                         AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                                THEN 'PERIODO PERDIDO + RIESGO CREDITICIO'
                        WHEN MB.MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA'
                                THEN 'PERIODO PERDIDO'

                        -- Aprobó, pero el buró advierte: es el caso que se escala arriba.
                        WHEN MB.MARCA_BASE = 'GESTIONABLE'
                         AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                                THEN 'RIESGO CREDITICIO ADVERSO'
                        WHEN MB.MARCA_BASE = 'GESTIONABLE'
                                THEN 'GESTIONABLE'

                        -- Sin registro de clase: el rastro de conexión decide si es recuperable.
                        WHEN M.Ultimo_acceso_moodle IS NOT NULL
                                THEN 'SIN REGISTRO DE CLASE - CON CONEXION'
                        ELSE 'SIN REGISTRO DE CLASE - SIN CONTACTO'
                END AS MARCA_ACADEMICA_DETALLE,"""

rep(VIEJO_2, NUEVO_2, '2) Riesgo adverso + MARCA_ACADEMICA_DETALLE')

# ---------------------------------------------------------------- 3) CTE Cartera_Total_Dedup
rep("                NOM_SECCIONAL, MODALIDAD, CICLO, MARCA_ACADEMICA, ESTADO_ALUMNO, ESTADO,",
    "                NOM_SECCIONAL, MODALIDAD, CICLO, MARCA_ACADEMICA, MARCA_ACADEMICA_DETALLE, ESTADO_ALUMNO, ESTADO,",
    '3) CTE Cartera_Total_Dedup')

# ---------------------------------------------------------------- 4) SELECT INTO Cartera_Gestion
rep("            CT.NOM_SECCIONAL, CT.MODALIDAD, CT.CICLO, CT.MARCA_ACADEMICA, CT.ESTADO_ALUMNO,",
    "            CT.NOM_SECCIONAL, CT.MODALIDAD, CT.CICLO, CT.MARCA_ACADEMICA, CT.MARCA_ACADEMICA_DETALLE, CT.ESTADO_ALUMNO,",
    '4) SELECT INTO Cartera_Gestion')

# ---------------------------------------------------------------- verificaciones finales
assert 'CARTERA EMPRESARIAL' in d
assert d.count('MARCA_ACADEMICA_DETALLE') >= 4
assert "F.RES_PERFIL_RIESGO = 'Riesgo Alto'" not in d, 'quedo un filtro de riesgo sin ampliar'
assert '<= 2.95' not in d, 'quedo el corte viejo de aprobacion'

open(OUT, 'w', encoding='utf-8').write(d)
print('\n  %d/4 reemplazos aplicados -> %s (%d chars)' % (n_ok, OUT, len(d)))
print('  Delta vs baseline: %+d chars' % (len(d) - len(ORIGINAL)))
