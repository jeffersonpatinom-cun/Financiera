-----------------------ajuste query marzo ---------------------------


-- ==============================================================================================
-- INSERCIÓN DE CIERRE MENSUAL: MARZO 2026
-- ==============================================================================================
-- Se utiliza INSERT INTO para no sobreescribir enero y febrero.
-- Se parametriza el mes '3' en los DECODE y CASE para obtener:
-- 1. Saldo Inicial: Saldo a 1 de Marzo (Saldo Inicial Año + Movimientos Ene + Movimientos Feb).
-- 2. Movimientos: Débitos y Créditos exclusivos de Marzo.
-- 3. Saldo Final: Saldo al 31 de Marzo.
-- ==============================================================================================

INSERT INTO FINANCIERA.NIFF_BALANCE
SELECT * FROM OPENQUERY([172.16.1.175], '
    SELECT 
        2026             AS ANO, 
        3                AS INICIO, 
        3                AS FINAL, 
        V.ORDEN, 
        V.CODIGO_CONTABLE, 
        V.CODIGO_INDENTADO, 
        V.NOMBRE_CUENTA, 
        
        -- ── CÁLCULO SALDO INICIAL (Corte al 1 de marzo) ──
        -- Al elegir el caso 3, sumamos los movimientos de Ene y Feb al saldo de apertura.
        SUM( 
            DECODE( 
                3, 
                1, V.SALDO_INICIAL, 
                2, V.SALDO_INICIAL + V.DEBITO_ENERO - V.CREDITO_ENERO, 
                3, V.SALDO_INICIAL + V.DEBITO_ENERO - V.CREDITO_ENERO 
                   + V.DEBITO_FEBRERO - V.CREDITO_FEBRERO, 
                4, V.SALDO_INICIAL + V.DEBITO_ENERO - V.CREDITO_ENERO 
                   + V.DEBITO_FEBRERO - V.CREDITO_FEBRERO 
                   + V.DEBITO_MARZO - V.CREDITO_MARZO, 
                5, V.SALDO_INICIAL + V.DEBITO_ENERO - V.CREDITO_ENERO 
                   + V.DEBITO_FEBRERO - V.CREDITO_FEBRERO 
                   + V.DEBITO_MARZO - V.CREDITO_MARZO 
                   + V.DEBITO_ABRIL - V.CREDITO_ABRIL, 
                6, V.SALDO_INICIAL + V.DEBITO_ENERO - V.CREDITO_ENERO 
                   + V.DEBITO_FEBRERO - V.CREDITO_FEBRERO 
                   + V.DEBITO_MARZO - V.CREDITO_MARZO 
                   + V.DEBITO_ABRIL - V.CREDITO_ABRIL 
                   + V.DEBITO_MAYO - V.CREDITO_MAYO 
            ) 
        ) AS SALDO_INICIAL, 
        
        -- ── CÁLCULO DÉBITOS MARZO ──
        SUM( 
            (CASE WHEN 1 BETWEEN 3 AND 3 THEN V.DEBITO_ENERO   ELSE 0 END) + 
            (CASE WHEN 2 BETWEEN 3 AND 3 THEN V.DEBITO_FEBRERO ELSE 0 END) + 
            (CASE WHEN 3 BETWEEN 3 AND 3 THEN V.DEBITO_MARZO   ELSE 0 END) + 
            (CASE WHEN 4 BETWEEN 3 AND 3 THEN V.DEBITO_ABRIL   ELSE 0 END) + 
            (CASE WHEN 5 BETWEEN 3 AND 3 THEN V.DEBITO_MAYO    ELSE 0 END) + 
            (CASE WHEN 6 BETWEEN 3 AND 3 THEN V.DEBITO_JUNIO   ELSE 0 END) 
        ) AS DEBITO, 
        
        -- ── CÁLCULO CRÉDITOS MARZO ──
        SUM( 
            (CASE WHEN 1 BETWEEN 3 AND 3 THEN V.CREDITO_ENERO   ELSE 0 END) + 
            (CASE WHEN 2 BETWEEN 3 AND 3 THEN V.CREDITO_FEBRERO ELSE 0 END) + 
            (CASE WHEN 3 BETWEEN 3 AND 3 THEN V.CREDITO_MARZO   ELSE 0 END) + 
            (CASE WHEN 4 BETWEEN 3 AND 3 THEN V.CREDITO_ABRIL   ELSE 0 END) 
        ) AS CREDITO, 
        
        -- ── CÁLCULO SALDO FINAL (Corte al 31 de marzo) ──
        SUM( 
            DECODE( 
                3, 
                1, V.SALDO_INICIAL, 
                2, V.SALDO_INICIAL + V.DEBITO_ENERO - V.CREDITO_ENERO, 
                3, V.SALDO_INICIAL + V.DEBITO_ENERO - V.CREDITO_ENERO 
                   + V.DEBITO_FEBRERO - V.CREDITO_FEBRERO, 
                4, V.SALDO_INICIAL + V.DEBITO_ENERO - V.CREDITO_ENERO 
                   + V.DEBITO_FEBRERO - V.CREDITO_FEBRERO 
                   + V.DEBITO_MARZO - V.CREDITO_MARZO, 
                5, V.SALDO_INICIAL + V.DEBITO_ENERO - V.CREDITO_ENERO 
                   + V.DEBITO_FEBRERO - V.CREDITO_FEBRERO 
                   + V.DEBITO_MARZO - V.CREDITO_MARZO 
                   + V.DEBITO_ABRIL - V.CREDITO_ABRIL 
            ) 
            + (CASE WHEN 3 BETWEEN 3 AND 3 THEN V.DEBITO_MARZO   ELSE 0 END) 
            - (CASE WHEN 3 BETWEEN 3 AND 3 THEN V.CREDITO_MARZO  ELSE 0 END) 
        ) AS SALDO_FINAL 
        
    FROM NIIF.V_BALANCE_GENERAL V 
    WHERE V.ANO = 2026 
    GROUP BY 
        V.ORDEN, 
        V.CODIGO_CONTABLE, 
        V.CODIGO_INDENTADO, 
        V.NOMBRE_CUENTA 
    ORDER BY 
        V.CODIGO_CONTABLE 
');