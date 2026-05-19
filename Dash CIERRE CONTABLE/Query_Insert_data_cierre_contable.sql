--DROP TABLE IF EXISTS FINANCIERA.NIFF_BALANCE
---------------------------------query cierre contable (drop_table) ------------------


SELECT *
INTO FINANCIERA.NIFF_BALANCE
FROM OPENQUERY([172.16.1.175], '
    SELECT 
        2026             AS ANO, 
        1                AS INICIO, 
        3                AS FINAL, 
        V.ORDEN, 
        V.CODIGO_CONTABLE, 
        V.CODIGO_INDENTADO, 
        V.NOMBRE_CUENTA, 
        
        -- ── CÁLCULO SALDO INICIAL (Hasta fin de febrero para marzo) ──
        SUM( 
            DECODE( 
                3, /* Parámetro Mes de Inicio: 1 (Enero) */
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
        
        -- ── CÁLCULO DÉBITOS (Solo movimientos de marzo) ──
        SUM( 
            (CASE WHEN 1 BETWEEN 3 AND 3 THEN V.DEBITO_ENERO   ELSE 0 END) + 
            (CASE WHEN 2 BETWEEN 3 AND 3 THEN V.DEBITO_FEBRERO ELSE 0 END) + 
            (CASE WHEN 3 BETWEEN 3 AND 3 THEN V.DEBITO_MARZO   ELSE 0 END) + 
            (CASE WHEN 4 BETWEEN 3 AND 3 THEN V.DEBITO_ABRIL   ELSE 0 END) + 
            (CASE WHEN 5 BETWEEN 3 AND 3 THEN V.DEBITO_MAYO    ELSE 0 END) + 
            (CASE WHEN 6 BETWEEN 3 AND 3 THEN V.DEBITO_JUNIO   ELSE 0 END) 
        ) AS DEBITO, 
        
        -- ── CÁLCULO CRÉDITOS (Solo movimientos de marzo) ──
        SUM( 
            (CASE WHEN 1 BETWEEN 3 AND 3 THEN V.CREDITO_ENERO   ELSE 0 END) + 
            (CASE WHEN 2 BETWEEN 3 AND 3 THEN V.CREDITO_FEBRERO ELSE 0 END) + 
            (CASE WHEN 3 BETWEEN 3 AND 3 THEN V.CREDITO_MARZO   ELSE 0 END) + 
            (CASE WHEN 4 BETWEEN 3 AND 3 THEN V.CREDITO_ABRIL   ELSE 0 END) 
        ) AS CREDITO, 
        
        -- ── CÁLCULO SALDO FINAL ──
        SUM( 
            DECODE( 
                3, /* Parámetro Mes de Inicio: 3 (Marzo) */
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
            + ( 
                (CASE WHEN 1 BETWEEN 3 AND 3 THEN V.DEBITO_ENERO   ELSE 0 END) + 
                (CASE WHEN 2 BETWEEN 3 AND 3 THEN V.DEBITO_FEBRERO ELSE 0 END) + 
                (CASE WHEN 3 BETWEEN 3 AND 3 THEN V.DEBITO_MARZO   ELSE 0 END) 
            ) 
            - ( 
                (CASE WHEN 1 BETWEEN 3 AND 3 THEN V.CREDITO_ENERO   ELSE 0 END) + 
                (CASE WHEN 2 BETWEEN 3 AND 3 THEN V.CREDITO_FEBRERO ELSE 0 END) + 
                (CASE WHEN 3 BETWEEN 3 AND 3 THEN V.CREDITO_MARZO   ELSE 0 END) 
            ) 
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

