# -*- coding: utf-8 -*-
"""
Backup mensual de la meta dentro de USP_Foto_Meta_Comercial_Mensual.

QUE HACE
--------
Inserta un PASO 2.5 que, ANTES de refrescar, copia Cartera_Meta_Comercial_Historico
completa a Cartera_Meta_Comercial_Snapshot_Mensual etiquetada con el mes de la corrida.

POR QUE VA AQUI Y NO EN UN JOB APARTE
-------------------------------------
La foto tiene que ser exactamente el estado con el que arranco la corrida. Un job separado
correria en otro instante y podria tomar la foto despues del refresco -- justo lo que se
quiere evitar. Dentro del SP, entre el paso 2 y el 5, no hay forma de que se desordene.

POR QUE DESPUES DEL PASO 2 Y NO AL PRINCIPIO
--------------------------------------------
El paso 2 crea la columna del anio (Meta_2026, Meta_2027...) si falta. Tomando la foto
despues, la bitacora de meses queda incluida en el backup.

IDEMPOTENCIA
------------
El bloque borra las filas del mes antes de insertar, asi que dos corridas del mismo mes
dejan la foto de la ULTIMA. Es deliberado: una segunda corrida del mismo mes suele ser un
reintento tras un fallo, y la foto util es la del reintento bueno.

DRIFT DE ESQUEMA
----------------
Mismo patron de auto-reparacion que Cartera_Destiempo_ZOHO en SP_Cartera_Total: si a la
tabla viva le agregan una columna, la tabla de snapshot se reconstruye UNA vez copiando el
historico por NOMBRE de columna. Las fotos viejas quedan con NULL en la columna nueva.

Uso:
    .venv/Scripts/python.exe aplicar_snapshot_mensual_meta.py <entrada.sql> <salida.sql>
"""
import io
import sys

ANCLA = """        ----------------------------------------------------------------------
        -- 3) Enriquecimientos -> #MOODLE y #PROM (1 fila por llave)
        ----------------------------------------------------------------------"""

BLOQUE = """        ----------------------------------------------------------------------
        -- 2.5) BACKUP MENSUAL: foto de la meta ANTES de refrescarla
        ----------------------------------------------------------------------
        --   El paso 5a refresca TODAS las columnas vivas, asi que el valor que tenia la
        --   cartera al cierre del mes anterior se perderia. Aqui se congela primero.
        --
        --   ANIO_MES_SNAPSHOT = mes de ESTA corrida, y la foto es PREVIA al refresco:
        --   la fila '202609' guarda el estado con el que arranco septiembre, o sea el
        --   cierre de agosto. Se etiqueta con @Periodo para cuadrar con la bitacora
        --   Meta_<anio> que escribe el paso 5a.
        --
        --   No se excluye ninguna columna: la foto es la tabla entera, tal cual estaba.

        -- (2.5.0) Crear la tabla de fotos si no existe. Esquema derivado de la tabla viva.
        IF OBJECT_ID('Financiera.Cartera_Meta_Comercial_Snapshot_Mensual', 'U') IS NULL
        BEGIN
            EXEC('SELECT TOP 0
                      CAST(NULL AS VARCHAR(6))  AS ANIO_MES_SNAPSHOT,
                      H.*,
                      CAST(NULL AS DATETIME)    AS AUD_FECHA_SNAPSHOT
                  INTO Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
                  FROM Financiera.Cartera_Meta_Comercial_Historico H;');

            EXEC('ALTER TABLE Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
                      ALTER COLUMN ANIO_MES_SNAPSHOT VARCHAR(6) NOT NULL;');

            -- Clustered por mes (toda consulta de la serie filtra por ahi). NO unico:
            -- NUMERO_CREDITO es nullable en el origen y un unique abortaria la corrida.
            EXEC('CREATE CLUSTERED INDEX IX_SnapMeta_Mes_Credito
                      ON Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
                         (ANIO_MES_SNAPSHOT, NUMERO_CREDITO);');
        END

        -- (2.5.1) AUTO-REPARACION DE ESQUEMA (drift de la tabla viva -> tabla de fotos)
        --   Si a Cartera_Meta_Comercial_Historico le agregan una columna, la foto dejaria
        --   de guardarla en silencio. Deteccion generica: si alguna columna de la tabla viva
        --   no existe en la de fotos, se reconstruye UNA vez preservando todo el historico
        --   (copia por NOMBRE); las fotos viejas quedan con NULL en la columna nueva.
        IF EXISTS (
                SELECT 1 FROM sys.columns h
                WHERE h.object_id = OBJECT_ID('Financiera.Cartera_Meta_Comercial_Historico')
                  AND NOT EXISTS (SELECT 1 FROM sys.columns s
                                  WHERE s.object_id = OBJECT_ID('Financiera.Cartera_Meta_Comercial_Snapshot_Mensual')
                                    AND s.name = h.name)
           )
        BEGIN
            DROP TABLE IF EXISTS Financiera.Cartera_Meta_Comercial_Snapshot_Mensual_REBUILD;

            EXEC('SELECT TOP 0
                      CAST(NULL AS VARCHAR(6))  AS ANIO_MES_SNAPSHOT,
                      H.*,
                      CAST(NULL AS DATETIME)    AS AUD_FECHA_SNAPSHOT
                  INTO Financiera.Cartera_Meta_Comercial_Snapshot_Mensual_REBUILD
                  FROM Financiera.Cartera_Meta_Comercial_Historico H;');

            DECLARE @cols_snap_hist NVARCHAR(MAX);
            SELECT @cols_snap_hist = STRING_AGG(CAST(QUOTENAME(n.name) AS NVARCHAR(MAX)), ', ')
                                     WITHIN GROUP (ORDER BY n.column_id)
            FROM sys.columns n
            WHERE n.object_id = OBJECT_ID('Financiera.Cartera_Meta_Comercial_Snapshot_Mensual_REBUILD')
              AND EXISTS (SELECT 1 FROM sys.columns o
                          WHERE o.object_id = OBJECT_ID('Financiera.Cartera_Meta_Comercial_Snapshot_Mensual')
                            AND o.name = n.name);

            SET @sql = N'INSERT INTO Financiera.Cartera_Meta_Comercial_Snapshot_Mensual_REBUILD ('
                     + @cols_snap_hist + N') SELECT ' + @cols_snap_hist
                     + N' FROM Financiera.Cartera_Meta_Comercial_Snapshot_Mensual;';
            EXEC sp_executesql @sql;

            DROP TABLE Financiera.Cartera_Meta_Comercial_Snapshot_Mensual;
            EXEC sp_rename 'Financiera.Cartera_Meta_Comercial_Snapshot_Mensual_REBUILD',
                           'Cartera_Meta_Comercial_Snapshot_Mensual';

            EXEC('ALTER TABLE Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
                      ALTER COLUMN ANIO_MES_SNAPSHOT VARCHAR(6) NOT NULL;');
            EXEC('CREATE CLUSTERED INDEX IX_SnapMeta_Mes_Credito
                      ON Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
                         (ANIO_MES_SNAPSHOT, NUMERO_CREDITO);');
        END

        -- (2.5.2) Tomar la foto del mes. Lista de columnas por NOMBRE (interseccion),
        --   nunca posicional, para que una columna nueva se propague sola.
        DECLARE @cols_snap NVARCHAR(MAX);
        SELECT @cols_snap = STRING_AGG(CAST(QUOTENAME(s.name) AS NVARCHAR(MAX)), ', ')
                            WITHIN GROUP (ORDER BY s.column_id)
        FROM sys.columns s
        WHERE s.object_id = OBJECT_ID('Financiera.Cartera_Meta_Comercial_Snapshot_Mensual')
          AND s.name NOT IN ('ANIO_MES_SNAPSHOT', 'AUD_FECHA_SNAPSHOT')
          AND EXISTS (SELECT 1 FROM sys.columns h
                      WHERE h.object_id = OBJECT_ID('Financiera.Cartera_Meta_Comercial_Historico')
                        AND h.name = s.name);

        IF @cols_snap IS NULL
        BEGIN
            RAISERROR('No se pudo armar el backup mensual: la tabla de fotos no comparte columnas con Cartera_Meta_Comercial_Historico.', 16, 1);
            RETURN;
        END

        SET @sql = N'
            DELETE FROM Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
             WHERE ANIO_MES_SNAPSHOT = @P;

            INSERT INTO Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
                (ANIO_MES_SNAPSHOT, ' + @cols_snap + N', AUD_FECHA_SNAPSHOT)
            SELECT @P, ' + @cols_snap + N', GETDATE()
              FROM Financiera.Cartera_Meta_Comercial_Historico;';
        EXEC sp_executesql @sql, N'@P VARCHAR(6)', @P = @Periodo;
        SET @snap = @@ROWCOUNT;

"""

DECL_VIEJO = "    DECLARE @upd INT = 0, @ins INT = 0;"
DECL_NUEVO = "    DECLARE @upd INT = 0, @ins INT = 0, @snap INT = 0;"

PRINT_VIEJO = """        PRINT 'Meta ' + @ColMeta + ' / mes ' + @Periodo + ' (patrón ' + @Patron + '). '
            + 'Nuevos insertados: ' + CAST(@ins AS VARCHAR(20))
            + ' | Acumulados (siguen): ' + CAST(@upd AS VARCHAR(20));"""

PRINT_NUEVO = """        PRINT 'Meta ' + @ColMeta + ' / mes ' + @Periodo + ' (patrón ' + @Patron + '). '
            + 'Nuevos insertados: ' + CAST(@ins AS VARCHAR(20))
            + ' | Acumulados (siguen): ' + CAST(@upd AS VARCHAR(20))
            + ' | Backup mensual: ' + CAST(@snap AS VARCHAR(20)) + ' filas.';"""


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

    sql = reemplazar(sql, DECL_VIEJO, DECL_NUEVO, 'declaracion @snap')
    sql = reemplazar(sql, ANCLA, BLOQUE + ANCLA, 'bloque PASO 2.5')
    sql = reemplazar(sql, PRINT_VIEJO, PRINT_NUEVO, 'PRINT final')

    with io.open(salida, 'w', encoding='utf-8') as fh:
        fh.write(sql)

    print('Escrito %s (%d chars, +%d respecto al original).'
          % (salida, len(sql), len(sql) - len(open(entrada, encoding='utf-8').read())))


if __name__ == '__main__':
    main()
