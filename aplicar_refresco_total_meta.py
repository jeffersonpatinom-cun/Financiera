# -*- coding: utf-8 -*-
"""
Refresco COMPLETO de Cartera_Meta_Comercial_Historico para los creditos que siguen vivos,
preservando intacto el historico de los que ya salieron de la cartera.

QUE CAMBIA
----------
Hoy el paso 5a refresca solo 6 campos (Ultimo_acceso_moodle, Promedio_notas, ESTADO_ALUMNO,
MARCA_ACADEMICA, MARCA_ACADEMICA_DETALLE, AUD_FECHA_ACTUALIZACION). Todo lo demas -- TOTAL,
CORRIENTE, los GR*, EMAIL, TEL_CELULAR, WHATSAPP -- quedo congelado en el primer ingreso.
Ahora se refresca TODO lo que venga de #SRC.

POR QUE NO SE PIERDE EL HISTORICO
---------------------------------
El UPDATE hace JOIN contra #SRC por NUMERO_CREDITO. Un credito que ya salio de la cartera
viva no esta en #SRC, asi que el UPDATE ni lo ve: conserva sus ultimos valores conocidos.
La preservacion es por construccion del JOIN, no por una condicion que alguien pueda borrar.

Medido al 2026-08-26 sobre 65.456 filas:
    21.402 filas (33%, $6.984 MM) ya NO estan en cartera viva -> intactas
    44.054 filas (67%, $13.377 MM) siguen vivas              -> se refrescan

COMO SE ARMA LA LISTA
---------------------
Por NOMBRE, no a mano: toda columna de la tabla que exista tambien en #SRC entra al SET.
Asi una columna nueva se propaga sola, igual que se hizo en Creditos_pagos_CTAYUDA.
Se excluyen las que son historia o identidad:
    NUMERO_CREDITO           llave del JOIN
    Anio_Mes_Ingreso         mes en que el credito entro a la meta
    AUD_FECHA_FOTO           instante del primer ingreso
    AUD_FECHA_ACTUALIZACION  se pone con GETDATE()
    Meta_<anio>              la bitacora de meses; se maneja aparte y es idempotente
[Asignacion Q] va explicita porque en #SRC se llama Asignacion_Q (con guion bajo) y el
cruce por nombre no la encontraria.

DECISIONES DE CARTERA (2026-08-26)
----------------------------------
  * NO se guarda linea base del saldo de ingreso. Para los 44.054 creditos vivos, el saldo
    con que entraron a la meta se sobrescribe y no es recuperable. Lo unico que sobrevive
    del recorrido es en que meses estuvo en la meta (columna Meta_<anio>).
  * Cadencia mensual: se conserva el WHERE actual, asi que el refresco ocurre una vez por
    mes. OJO: una segunda corrida dentro del mismo mes NO refresca nada.

Uso:
    .venv/Scripts/python.exe aplicar_refresco_total_meta.py <volcado.sql> <salida.sql>
"""
import sys
import io

VIEJO = """        SET @sql = N'
            UPDATE T
               SET T.' + QUOTENAME(@ColMeta) + N' =
                       CASE WHEN T.' + QUOTENAME(@ColMeta) + N' IS NULL THEN @Periodo
                            ELSE T.' + QUOTENAME(@ColMeta) + N' + '', '' + @Periodo END,
                   T.Ultimo_acceso_moodle    = S.Ultimo_acceso_moodle,   -- refresco mensual (dato vivo)
                   T.Promedio_notas          = S.Promedio_notas,         -- refresco mensual
                   T.ESTADO_ALUMNO           = S.ESTADO_ALUMNO,          -- refresco mensual (marcador académico)
                   T.MARCA_ACADEMICA         = S.MARCA_ACADEMICA,        -- refresco mensual
                   T.MARCA_ACADEMICA_DETALLE = S.MARCA_ACADEMICA_DETALLE,-- refresco mensual
                   T.AUD_FECHA_ACTUALIZACION = GETDATE()
              FROM Financiera.Cartera_Meta_Comercial_Historico T
              JOIN #SRC S ON T.NUMERO_CREDITO = S.NUMERO_CREDITO
             WHERE T.' + QUOTENAME(@ColMeta) + N' IS NULL
                OR T.' + QUOTENAME(@ColMeta) + N' NOT LIKE ''%'' + @Periodo + ''%'';';
        EXEC sp_executesql @sql, N'@Periodo VARCHAR(6)', @Periodo = @Periodo;
        SET @upd = @@ROWCOUNT;"""

NUEVO = """        -- ------------------------------------------------------------------
        -- Refresco COMPLETO (2026-08-26). Antes solo se actualizaban 6 campos y el resto
        -- -- TOTAL, CORRIENTE, los GR*, EMAIL, TEL_CELULAR, WHATSAPP -- quedaba congelado
        -- en el primer ingreso, mostrando saldos y contactos viejos.
        --
        -- El historico NO se pierde: el JOIN es contra #SRC por NUMERO_CREDITO, asi que un
        -- credito que ya salio de la cartera viva no esta en #SRC y el UPDATE ni lo ve.
        -- Al 2026-08-26 eso son 21.402 de 65.456 filas ($6.984 MM) que quedan intactas.
        -- La preservacion la da la forma del JOIN, no una condicion que se pueda borrar.
        --
        -- La lista del SET se arma POR NOMBRE desde la interseccion tabla ∩ #SRC: una
        -- columna nueva se propaga sola. Se excluyen las que son identidad o historia.
        -- ------------------------------------------------------------------
        DECLARE @set_cols NVARCHAR(MAX);
        SELECT @set_cols = STRING_AGG(CAST(
                    'T.' + QUOTENAME(t.name) + ' = S.' + QUOTENAME(t.name) AS NVARCHAR(MAX)),
                    ',' + CHAR(13) + CHAR(10) + '                   ')
                    WITHIN GROUP (ORDER BY t.column_id)
        FROM sys.columns t
        WHERE t.object_id = OBJECT_ID('Financiera.Cartera_Meta_Comercial_Historico')
          AND t.name NOT IN ('NUMERO_CREDITO',          -- llave del JOIN
                             'Anio_Mes_Ingreso',        -- mes de ingreso a la meta
                             'AUD_FECHA_FOTO',          -- instante del primer ingreso
                             'AUD_FECHA_ACTUALIZACION') -- se pone con GETDATE()
          AND t.name NOT LIKE 'Meta[_]%'                -- bitacora de meses, aparte
          AND EXISTS (SELECT 1 FROM tempdb.sys.columns s
                      WHERE s.object_id = OBJECT_ID('tempdb..#SRC')
                        AND s.name = t.name);

        IF @set_cols IS NULL
        BEGIN
            RAISERROR('No se pudo armar la lista de refresco: #SRC no comparte columnas con Cartera_Meta_Comercial_Historico.', 16, 1);
            RETURN;
        END

        SET @sql = N'
            UPDATE T
               SET T.' + QUOTENAME(@ColMeta) + N' =
                       CASE WHEN T.' + QUOTENAME(@ColMeta) + N' IS NULL THEN @Periodo
                            ELSE T.' + QUOTENAME(@ColMeta) + N' + '', '' + @Periodo END,
                   ' + @set_cols + N',
                   T.[Asignacion Q]          = S.Asignacion_Q,   -- nombre distinto en #SRC
                   T.AUD_FECHA_ACTUALIZACION = GETDATE()
              FROM Financiera.Cartera_Meta_Comercial_Historico T
              JOIN #SRC S ON T.NUMERO_CREDITO = S.NUMERO_CREDITO
             WHERE T.' + QUOTENAME(@ColMeta) + N' IS NULL
                OR T.' + QUOTENAME(@ColMeta) + N' NOT LIKE ''%'' + @Periodo + ''%'';';
        EXEC sp_executesql @sql, N'@Periodo VARCHAR(6)', @Periodo = @Periodo;
        SET @upd = @@ROWCOUNT;"""


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    origen, destino = sys.argv[1], sys.argv[2]

    with io.open(origen, "r", encoding="utf-8") as fh:
        sql = fh.read()

    n = sql.count(VIEJO)
    if n != 1:
        print("ABORTADO: esperaba 1 ocurrencia del UPDATE del paso 5a, encontre %d." % n)
        sys.exit(1)
    sql = sql.replace(VIEJO, NUEVO, 1)
    print("  OK  paso 5a refresca todas las columnas de #SRC")

    errores = []
    # El JOIN que preserva el historico debe seguir intacto.
    if sql.count("JOIN #SRC S ON T.NUMERO_CREDITO = S.NUMERO_CREDITO") != 1:
        errores.append("el JOIN contra #SRC cambio: es lo que preserva el historico")
    # Las columnas de identidad/historia no pueden acabar en el SET generico.
    for prohibida in ("Anio_Mes_Ingreso", "AUD_FECHA_FOTO"):
        if "T.%s = S." % prohibida in sql or "T.[%s] = S." % prohibida in sql:
            errores.append("%s quedo en el SET y es historia, no dato vivo" % prohibida)
    if "T.[Asignacion Q]          = S.Asignacion_Q" not in sql:
        errores.append("falta el mapeo explicito de [Asignacion Q]")

    if errores:
        print("\nABORTADO. No se escribio nada:")
        for e in errores:
            print("   - %s" % e)
        sys.exit(1)
    print("  OK  el JOIN que preserva el historico sigue intacto")

    with io.open(destino, "w", encoding="utf-8") as fh:
        fh.write(sql)
    print("\nEscrito: %s  (%d chars)" % (destino, len(sql)))


if __name__ == "__main__":
    main()
