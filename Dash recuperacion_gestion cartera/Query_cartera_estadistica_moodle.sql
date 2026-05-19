

---------------------------------CONSULTA_FINAL_ADAPTADA SP-------------------------------------



WITH 

-- Deduplicacion de Cartera_Total (una fila por estudiante/periodo)
Cartera_Total_Dedup AS (
    SELECT
        IDENTIFICACION,
        PERIODO,
        NOM_UNIDAD,
        NOM_SECCIONAL,
        MODALIDAD,
        CICLO,
        ESTADO_ALUMNO,
        NUEVO,
        PROMEDIO,
        SEMESTRE,
        ESTADO,
        MARCA_ACADEMICA,
        ROW_NUMBER() OVER (
            PARTITION BY IDENTIFICACION, PERIODO
            ORDER BY IDENTIFICACION
        ) AS rn
    FROM Financiera.Cartera_Total
),

-- Deduplicacion de ESTADISTICA_ESTUDIANTE_2 (misma logica del SP)
Estadistica_Dedup AS (
    SELECT
        NUM_IDENTIFICACION,
        COD_PERIODO,
        NOM_UNIDAD,
        NOM_SECCIONAL,
        MODALIDAD,
        CICLO,
        ESTADO_ALUMNO,
        NUEVO,
        PROMEDIO,
        SEMESTRE
    FROM (
        SELECT
            NUM_IDENTIFICACION, COD_PERIODO, NOM_UNIDAD, NOM_SECCIONAL,
            MODALIDAD, CICLO, ESTADO_ALUMNO, NUEVO, PROMEDIO, SEMESTRE,
            ROW_NUMBER() OVER (
                PARTITION BY NUM_IDENTIFICACION, COD_PERIODO
                ORDER BY
                    CASE WHEN CICLO = 'Profesional'           THEN 1
                         WHEN CICLO = 'Tecnólogo'             THEN 2
                         WHEN CICLO = 'Técnico Profesional'   THEN 3
                         ELSE 99
                    END ASC,
                    CASE WHEN ESTADO_ALUMNO = '1-Activo'      THEN 1
                         WHEN ESTADO_ALUMNO = '-1-Inscrito'   THEN 2
                         WHEN ESTADO_ALUMNO = '4-Traslado'    THEN 3
                         ELSE 9
                    END ASC,
                    COD_PERIODO DESC
            ) AS rn
        FROM CUN.ESTADISTICA_ESTUDIANTE_2
    ) x
    WHERE rn = 1
)

SELECT
    -- Financiera.Cartera
    C.PERIODO,
    C.TIPO_CLIENTE,
    C.NOMBRE_TIPO_CLIENTE,
    C.IDENTIFICACION,
    C.FEC_NAC,
    C.GENDER,
    C.DIRECCION_CASA,
    C.EMAIL,
    C.TEL_CASA,
    C.TEL_CELULAR,
    C.WHATSAPP,
    C.PAIS,
    C.DEPARTAMENTO,
    C.CLIENTE,
    C.NOMBRE,
    C.LINEA,
    C.TIPO_DOCUMENTO,
    C.DOCUMENTO,
    C.NUMERO_CREDITO,
    C.FECHA,
    C.FECHA_VENCIMIENTO,
    C.CENTRO_COSTO,
    C.NOMBRE_CENTRO,
    C.FONDO,
    C.NOMBRE_FONDO,
    C.NOMBRE_CONCEPTO,
    C.NOMBRE_CAUSA,
    C.VALOR_ORIGINAL,
    C.CORRIENTE,
    C.GR1A30,
    C.GR31A60,
    C.GR61A90,
    C.GR91A120,
    C.GR121A150,
    C.GR151A360,
    C.GR360MAS,
    C.TOTAL,
    C.CODIGO_CONTABLE,
    C.DESCRIPCION,

    -- Financiera.Cartera_Total (deduplicada)
    CT.NOM_UNIDAD,
    CT.NUEVO,

    -- ESTADISTICA_ESTUDIANTE_2 (deduplicada, como fallback)
    COALESCE(CT.SEMESTRE,  EE.SEMESTRE)  AS SEMESTRE,
    COALESCE(CT.PROMEDIO,  EE.PROMEDIO)  AS PROMEDIO,

    -- DBARON.CURSOS_MOODLE_2026 (aplanada)
    CM.ultimoaccesoplataformlimpio

FROM Financiera.Cartera C

LEFT JOIN Cartera_Total_Dedup CT
    ON  C.IDENTIFICACION = CT.IDENTIFICACION
    AND C.PERIODO        = CT.PERIODO
    AND CT.rn            = 1

LEFT JOIN Estadistica_Dedup EE
    ON  C.IDENTIFICACION = EE.NUM_IDENTIFICACION
    AND C.PERIODO        = EE.COD_PERIODO

LEFT JOIN (
    SELECT
        cedula,
        MAX(ultimoaccesoplataformlimpio) AS ultimoaccesoplataformlimpio
    FROM DBARON.CURSOS_MOODLE_2026
    GROUP BY cedula
) CM
    ON C.IDENTIFICACION = CM.cedula

WHERE C.DOCUMENTO = 'NDB'
  AND (
      C.PERIODO LIKE '%22%' OR
      C.PERIODO LIKE '%23%' OR
      C.PERIODO LIKE '%24%' OR
      C.PERIODO LIKE '%25%' OR
      C.PERIODO LIKE '%26%'
  )








  -----------------------------------  CONSULTA DE COMPARACION CIFRAS  --------------------------------




  WITH 

Cartera_Total_Dedup AS (
    SELECT IDENTIFICACION, PERIODO, NOM_UNIDAD, NUEVO, PROMEDIO, SEMESTRE,
        ROW_NUMBER() OVER (PARTITION BY IDENTIFICACION, PERIODO ORDER BY IDENTIFICACION) AS rn
    FROM Financiera.Cartera_Total
),

Estadistica_Dedup AS (
    SELECT NUM_IDENTIFICACION, COD_PERIODO, SEMESTRE, PROMEDIO
    FROM (
        SELECT NUM_IDENTIFICACION, COD_PERIODO, SEMESTRE, PROMEDIO,
            ROW_NUMBER() OVER (
                PARTITION BY NUM_IDENTIFICACION, COD_PERIODO
                ORDER BY
                    CASE WHEN CICLO = 'Profesional'         THEN 1
                         WHEN CICLO = 'Tecnólogo'           THEN 2
                         WHEN CICLO = 'Técnico Profesional' THEN 3 ELSE 99 END ASC,
                    CASE WHEN ESTADO_ALUMNO = '1-Activo'    THEN 1
                         WHEN ESTADO_ALUMNO = '-1-Inscrito' THEN 2
                         WHEN ESTADO_ALUMNO = '4-Traslado'  THEN 3 ELSE 9 END ASC,
                    COD_PERIODO DESC
            ) AS rn
        FROM CUN.ESTADISTICA_ESTUDIANTE_2
    ) x WHERE rn = 1
),

-- Consulta adaptada agrupada por periodo
Consulta_Adaptada AS (
    SELECT
        C.PERIODO,
        SUM(CAST(C.TOTAL AS DECIMAL(18,2))) AS TOTAL_CONSULTA
    FROM Financiera.Cartera C
    LEFT JOIN Cartera_Total_Dedup CT
        ON  C.IDENTIFICACION = CT.IDENTIFICACION
        AND C.PERIODO        = CT.PERIODO
        AND CT.rn            = 1
    LEFT JOIN Estadistica_Dedup EE
        ON  C.IDENTIFICACION = EE.NUM_IDENTIFICACION
        AND C.PERIODO        = EE.COD_PERIODO
    LEFT JOIN (
        SELECT cedula, MAX(ultimoaccesoplataformlimpio) AS ultimoaccesoplataformlimpio
        FROM DBARON.CURSOS_MOODLE_2026
        GROUP BY cedula
    ) CM ON C.IDENTIFICACION = CM.cedula
    WHERE C.DOCUMENTO = 'NDB'
      AND (C.PERIODO LIKE '%22%' OR C.PERIODO LIKE '%23%' OR
           C.PERIODO LIKE '%24%' OR C.PERIODO LIKE '%25%' OR C.PERIODO LIKE '%26%')
    GROUP BY C.PERIODO
),

-- Cartera_Total agrupada por periodo
Cartera_Total_Agrupada AS (
    SELECT
        PERIODO,
        SUM(CAST(TOTAL AS DECIMAL(18,2))) AS TOTAL_CARTERA_TOTAL
    FROM Financiera.Cartera_Total
    WHERE DOCUMENTO = 'NDB'
    GROUP BY PERIODO
)

SELECT
    COALESCE(A.PERIODO, B.PERIODO)                  AS PERIODO,
    A.TOTAL_CONSULTA,
    B.TOTAL_CARTERA_TOTAL,
    ISNULL(A.TOTAL_CONSULTA, 0)
        - ISNULL(B.TOTAL_CARTERA_TOTAL, 0)          AS DIFERENCIA,
    CASE
        WHEN A.TOTAL_CONSULTA = B.TOTAL_CARTERA_TOTAL THEN 'OK'
        WHEN B.TOTAL_CARTERA_TOTAL IS NULL            THEN 'FALTA EN CARTERA_TOTAL'
        WHEN A.TOTAL_CONSULTA IS NULL                 THEN 'FALTA EN CONSULTA'
        ELSE 'DIFERENCIA'
    END                                             AS ESTADO
FROM Consulta_Adaptada A
FULL OUTER JOIN Cartera_Total_Agrupada B ON A.PERIODO = B.PERIODO
ORDER BY PERIODO



--------------------------------------------------------------------------------SUMA CONSULTA ADAPTADA  ------------------


WITH 

Cartera_Total_Dedup AS (
    SELECT IDENTIFICACION, PERIODO,
        ROW_NUMBER() OVER (PARTITION BY IDENTIFICACION, PERIODO ORDER BY IDENTIFICACION) AS rn
    FROM Financiera.Cartera_Total
),

Estadistica_Dedup AS (
    SELECT NUM_IDENTIFICACION, COD_PERIODO
    FROM (
        SELECT NUM_IDENTIFICACION, COD_PERIODO,
            ROW_NUMBER() OVER (
                PARTITION BY NUM_IDENTIFICACION, COD_PERIODO
                ORDER BY
                    CASE WHEN CICLO = 'Profesional'         THEN 1
                         WHEN CICLO = 'Tecnólogo'           THEN 2
                         WHEN CICLO = 'Técnico Profesional' THEN 3 ELSE 99 END ASC,
                    CASE WHEN ESTADO_ALUMNO = '1-Activo'    THEN 1
                         WHEN ESTADO_ALUMNO = '-1-Inscrito' THEN 2
                         WHEN ESTADO_ALUMNO = '4-Traslado'  THEN 3 ELSE 9 END ASC,
                    COD_PERIODO DESC
            ) AS rn
        FROM CUN.ESTADISTICA_ESTUDIANTE_2
    ) x WHERE rn = 1
)

SELECT
    SUM(CAST(C.TOTAL AS DECIMAL(18,2))) AS TOTAL_CONSULTA_ADAPTADA
FROM Financiera.Cartera C
LEFT JOIN Cartera_Total_Dedup CT
    ON  C.IDENTIFICACION = CT.IDENTIFICACION
    AND C.PERIODO        = CT.PERIODO
    AND CT.rn            = 1
LEFT JOIN Estadistica_Dedup EE
    ON  C.IDENTIFICACION = EE.NUM_IDENTIFICACION
    AND C.PERIODO        = EE.COD_PERIODO
LEFT JOIN (
    SELECT cedula, MAX(ultimoaccesoplataformlimpio) AS ultimoaccesoplataformlimpio
    FROM DBARON.CURSOS_MOODLE_2026
    GROUP BY cedula
) CM ON C.IDENTIFICACION = CM.cedula
WHERE C.DOCUMENTO = 'NDB'
  AND (C.PERIODO LIKE '%22%' OR C.PERIODO LIKE '%23%' OR
       C.PERIODO LIKE '%24%' OR C.PERIODO LIKE '%25%' OR C.PERIODO LIKE '%26%')





       --------------------------------------------------------------------------------SUMA CONSULTA CARTERA_TOTAL ------------------

SELECT SUM(TOTAL) DEUDA  
FROM Financiera.Cartera_Total
WHERE DOCUMENTO = 'NDB'