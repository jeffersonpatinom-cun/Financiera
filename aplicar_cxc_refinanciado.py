# -*- coding: utf-8 -*-
"""
CXC REFINANCIADO: tercer valor de CLASIFICACION_CARTERA para el estudiante que arrastra
deuda de un periodo cerrado Y ADEMAS debe del periodo vigente.

DECISION DE CARTERA (2026-08-28)
--------------------------------
Ese estudiante tiene un tratamiento de cobranza distinto, asi que TODAS sus obligaciones
-- tambien las del periodo cerrado -- se etiquetan 'CXC REFINANCIADO'. Se evaluaron dos
alcances y se eligio el amplio:
    solo las filas CUENTAS POR COBRAR ->  8.256 obligaciones / $2.263,6 MM
    TODAS las filas del estudiante    -> 22.062 obligaciones / $5.874,4 MM   <-- elegido

Medido sobre la corrida del 2026-08-28:
    CARTERA             128.453 oblig / 42.620 cli / $32.020,5 MM
    CUENTAS POR COBRAR  109.299 oblig / 35.217 cli / $30.210,8 MM
    CXC REFINANCIADO     22.062 oblig /  4.748 cli /  $5.874,4 MM
Los tres suman 82.585 clientes = el universo exacto de la cartera. Antes de este cambio
los buckets se solapaban (47.368 + 39.965 = 87.333, con 4.748 contados dos veces).

COMO SE DETECTA "TIENE LAS DOS"
-------------------------------
    MIN(clasificacion) OVER (PARTITION BY IDENTIFICACION)
 <> MAX(clasificacion) OVER (PARTITION BY IDENTIFICACION)

COUNT(DISTINCT ...) no se admite como funcion de ventana en SQL Server. Como los valores
base son solo dos y 'CARTERA' < 'CUENTAS POR COBRAR' alfabeticamente, MIN y MAX difieren
si y solo si el estudiante tiene ambas. Es una pasada de ventana sobre 259.814 filas.

POR QUE VA EN EL PASO 3 Y NO EN EL 4
------------------------------------
`Cartera_Gestion` (PASO 4) hereda la columna desde `Cartera_Total_Dedup`, asi que basta
calcularla una vez en el PASO 3. Verificado que ambas tablas tienen EXACTAMENTE la misma
poblacion (259.814 filas / 82.585 identificaciones), de modo que evaluar la ventana sobre
Cartera_Total da el mismo resultado que sobre Cartera_Gestion. Si algun dia Cartera_Gestion
pasa a filtrar filas, esta equivalencia se rompe y hay que recalcular alli.

LO QUE ESTE CAMBIO ROMPE A PROPOSITO
------------------------------------
CLASIFICACION_CARTERA deja de ser funcion UNICAMENTE del PERIODO. Antes se cumplia que
0 pares (identificacion, periodo) tenian dos clasificaciones y 0 periodos tenian dos.
Ahora la etiqueta de una fila depende del resto de la cartera de su dueño: dos obligaciones
del mismo periodo pueden quedar distinto. Cualquier logica que asuma
"una clasificacion por periodo" deja de ser valida.

ANCHO DE LA COLUMNA
-------------------
'CXC REFINANCIADO' son 16 caracteres, menos que 'CUENTAS POR COBRAR' (18), asi que el
SELECT INTO no ensancha la columna respecto de hoy. El bootstrap la declaro varchar(20).

Uso:
    .venv/Scripts/python.exe aplicar_cxc_refinanciado.py <entrada.sql> <salida.sql>
"""
import io
import sys

VIEJO = """                CASE WHEN C.ESTADO IN ('ACTIVO', 'PERIODO NO HA INICIADO')
                     THEN 'CUENTAS POR COBRAR'
                     ELSE 'CARTERA'
                END AS CLASIFICACION_CARTERA,"""

NUEVO = """                -- CXC REFINANCIADO (decision de Cartera 2026-08-28): el estudiante que
                -- arrastra deuda de un periodo CERRADO y ademas debe del periodo VIGENTE
                -- tiene tratamiento de cobranza distinto, asi que TODAS sus obligaciones
                -- -- incluidas las del periodo cerrado -- se reetiquetan.
                --   Medido: 4.748 estudiantes / 22.062 obligaciones / $5.874,4 MM.
                --   MIN <> MAX es el equivalente de "tiene mas de un valor": COUNT(DISTINCT)
                --   no se admite como funcion de ventana. Como los valores base son dos y
                --   'CARTERA' < 'CUENTAS POR COBRAR', difieren si y solo si estan ambas.
                --   OJO: con esto la clasificacion deja de depender solo del PERIODO y pasa
                --   a depender de la cartera completa del estudiante.
                CASE
                    WHEN MIN(CASE WHEN C.ESTADO IN ('ACTIVO', 'PERIODO NO HA INICIADO')
                                  THEN 'CUENTAS POR COBRAR' ELSE 'CARTERA' END)
                             OVER (PARTITION BY A.IDENTIFICACION)
                      <> MAX(CASE WHEN C.ESTADO IN ('ACTIVO', 'PERIODO NO HA INICIADO')
                                  THEN 'CUENTAS POR COBRAR' ELSE 'CARTERA' END)
                             OVER (PARTITION BY A.IDENTIFICACION)
                        THEN 'CXC REFINANCIADO'
                    WHEN C.ESTADO IN ('ACTIVO', 'PERIODO NO HA INICIADO')
                        THEN 'CUENTAS POR COBRAR'
                    ELSE 'CARTERA'
                END AS CLASIFICACION_CARTERA,"""


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
    sql = reemplazar(sql, VIEJO, NUEVO, 'CASE de CLASIFICACION_CARTERA')

    with io.open(salida, 'w', encoding='utf-8') as fh:
        fh.write(sql)

    print('Escrito %s (%d chars, +%d).' % (salida, len(sql), len(sql) - original))


if __name__ == '__main__':
    main()
