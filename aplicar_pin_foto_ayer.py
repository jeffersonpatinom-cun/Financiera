# -*- coding: utf-8 -*-
"""
Seguro de UN SOLO USO para que la proxima corrida de SP_Cartera_Total compare contra
una foto CONGELADA en vez de derivarla de Cartera_Gestion.

Por que hace falta
------------------
El PASO 0 no lee Cartera_Foto_Ayer: la DROPea y la vuelve a derivar de Cartera_Gestion.
Por eso "restaurar la foto" no sobrevive a la siguiente corrida -- se pierde en la primera
instruccion del SP, sin dejar rastro.

Contexto (2026-08-26): el SP corrio DOS veces el mismo dia (job 06:11 con la logica vieja +
corrida manual 13:50 con PROMEDIO unificado). Sin este seguro, la corrida de manana comparara
contra la foto de las 13:50 y subcontara los pagos de esas ~8 horas.

Como funciona
-------------
Si existe la tabla PIN, el PASO 0 toma la foto de ahi y ACTO SEGUIDO borra el PIN.
Autolimpiante a proposito: un seguro que hubiera que quitar a mano es un modo de falla
silencioso -- si alguien lo olvida, la foto se congela para siempre y la deteccion de pagos
deja de funcionar sin avisar.

El DROP del PIN ocurre DENTRO de la transaccion del SP: si la corrida falla y hace rollback,
el PIN sobrevive y el seguro sigue armado para el siguiente intento.

Uso:
    .venv/Scripts/python.exe aplicar_pin_foto_ayer.py <volcado.sql> <salida.sql>
"""
import sys
import io

PIN = "Financiera.Cartera_Foto_Ayer_PIN_20260826"

VIEJO = """            DROP TABLE IF EXISTS Financiera.Cartera_Foto_Ayer;

            -- Snapshot COMPLETO: la foto conserva todas las columnas para que
            -- Creditos_pagos_CTAYUDA pueda heredar el esquema de Cartera_Gestion.
            SELECT *
            INTO Financiera.Cartera_Foto_Ayer
            FROM Financiera.Cartera_Gestion
            WHERE DOCUMENTO = 'NDB';
"""

NUEVO = """            DROP TABLE IF EXISTS Financiera.Cartera_Foto_Ayer;

            -- ──────────────────────────────────────────────────────────────────────────────
            -- SEGURO DE UN SOLO USO (autolimpiante).
            --   Si existe %s, la foto se toma de ahí en vez de derivarla
            --   de Cartera_Gestion, y el PIN se borra en el acto: sirve UNA corrida y el SP
            --   vuelve solo a su comportamiento normal. No hay que acordarse de quitarlo.
            --
            --   Se armó el 2026-08-26 porque el SP corrió dos veces ese día (job 06:11 con la
            --   lógica vieja + corrida manual 13:50 con el PROMEDIO unificado). Sin el PIN, la
            --   corrida siguiente compararía contra la foto de las 13:50 y subcontaría los
            --   pagos de esas ~8 horas.
            --
            --   El DROP va dentro de la transacción del SP: si la corrida falla y hace
            --   rollback, el PIN sobrevive y el seguro sigue armado para el reintento.
            -- ──────────────────────────────────────────────────────────────────────────────
            IF OBJECT_ID('%s', 'U') IS NOT NULL
            BEGIN
                SELECT *
                INTO Financiera.Cartera_Foto_Ayer
                FROM %s
                WHERE DOCUMENTO = 'NDB';

                DROP TABLE %s;
            END
            ELSE
            BEGIN
                -- Snapshot COMPLETO: la foto conserva todas las columnas para que
                -- Creditos_pagos_CTAYUDA pueda heredar el esquema de Cartera_Gestion.
                SELECT *
                INTO Financiera.Cartera_Foto_Ayer
                FROM Financiera.Cartera_Gestion
                WHERE DOCUMENTO = 'NDB';
            END
""" % (PIN, PIN, PIN, PIN)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    origen, destino = sys.argv[1], sys.argv[2]

    with io.open(origen, "r", encoding="utf-8") as fh:
        sql = fh.read()

    n = sql.count(VIEJO)
    if n != 1:
        print("ABORTADO: esperaba 1 ocurrencia del bloque del PASO 0, encontre %d." % n)
        print("El SP cambio respecto de lo esperado. Volver a hacer dump y revisar.")
        sys.exit(1)

    sql = sql.replace(VIEJO, NUEVO, 1)
    print("  OK  PASO 0 ahora respeta el PIN (y lo autoborra)")

    # El PIN debe aparecer 4 veces: comentario, guarda, FROM y DROP.
    if sql.count(PIN) != 4:
        print("ABORTADO: se esperaban 4 referencias al PIN, hay %d" % sql.count(PIN))
        sys.exit(1)

    with io.open(destino, "w", encoding="utf-8") as fh:
        fh.write(sql)
    print("\nEscrito: %s  (%d chars)" % (destino, len(sql)))


if __name__ == "__main__":
    main()
