/*===========================================================================================
  VALIDACION DE LA PRIMERA CORRIDA CON CLASIFICACION_CARTERA + 2do CRUCE POR CEDULA
  -------------------------------------------------------------------------------------------
  Objeto      : [Financiera].[Cartera_Gestion] / [Cartera_Total]
  Autor       : Analitica financiera - Universidad CUN
  Cuando      : DESPUES del job de las 6:00 am del 2026-08-28 (primera corrida con el SP
                desplegado el 2026-08-27 14:49).

  Que se despliega y por tanto que hay que ver:
      1. CLASIFICACION_CARTERA  -- columna nueva, hoy 100% NULL. Debe quedar poblada.
      2. 2do cruce academico por cedula sola -- debe rellenar el hueco de las 6 columnas
         academicas. Medido en read-only sobre la corrida del 26-ago:
             hueco      1.372 clientes / 3.400 obligaciones / $855 MM
             recupera   1.199 clientes (87%) / 2.461 obligaciones (72%) / $453 MM
             sin rescate  173 clientes
      3. Pushdown del semestre maximo a Oracle -- es una optimizacion EXACTA: el resultado
         debe ser identico, solo mas rapido. Se valida por ausencia de cambio raro.

  Condicion de salida sana: 0 marcas vacias, CLASIFICACION_CARTERA sin NULL, y el conteo de
  huerfanos academicos bajando de ~1.372 a ~173 clientes.
===========================================================================================*/

/*-------------------------------------------------------------------------------------------
  0) FRESCURA -- confirmar que lo que se mira es la corrida nueva, no la de ayer.
     OJO: FECHA_ELABORACION es varchar dd/MM/yyyy. Un MAX() directo ordena como TEXTO
     ('31/12/2025' > '27/08/2026'). Siempre TRY_CONVERT(...,103).
-------------------------------------------------------------------------------------------*/
SELECT MAX(TRY_CONVERT(date, FECHA_ELABORACION, 103)) AS MAX_FECHA_ELABORACION,
       COUNT(*)                                       AS FILAS,
       COUNT(DISTINCT IDENTIFICACION)                 AS CLIENTES
FROM Financiera.Cartera_Gestion;


/*-------------------------------------------------------------------------------------------
  1) CLASIFICACION_CARTERA -- reparto y, sobre todo, que no queden NULL.
     Antes de la corrida: 259.818 de 259.818 en NULL.
-------------------------------------------------------------------------------------------*/
SELECT ISNULL(CLASIFICACION_CARTERA, '(NULL)')         AS CLASIFICACION_CARTERA,
       COUNT(*)                                        AS OBLIGACIONES,
       COUNT(DISTINCT IDENTIFICACION)                  AS CLIENTES,
       CAST(SUM(TOTAL)/1000000 AS DECIMAL(18,1))       AS TOTAL_MM
FROM Financiera.Cartera_Gestion
GROUP BY CLASIFICACION_CARTERA
ORDER BY OBLIGACIONES DESC;

-- Semaforo: cualquier valor > 0 en CLASIF_NULL es un fallo del PASO 3/4.
SELECT SUM(CASE WHEN CLASIFICACION_CARTERA IS NULL THEN 1 ELSE 0 END) AS CLASIF_NULL,
       COUNT(*)                                                       AS TOTAL
FROM Financiera.Cartera_Gestion;


/*-------------------------------------------------------------------------------------------
  2) HUECO ACADEMICO -- lo que debia rellenar el 2do cruce por cedula.
     Las 6 columnas se llenan juntas: si NOM_UNIDAD quedo NULL, quedaron las seis (verificado:
     el conteo por NOM_UNIDAD y el de las seis a la vez dan identico).

     EL FILTRO ESTUDIANTES NO ES OPCIONAL. Sin el, el conteo arrastra la CARTERA EMPRESARIAL,
     que no tiene dato academico por diseno: 12.599 obligaciones / 1.401 clientes / $5.669 MM
     en vez de las 3.373 / 1.360 / $849 MM que son el hueco real. Ese es el numero que el
     2do cruce puede rescatar.
-------------------------------------------------------------------------------------------*/
SELECT COUNT(*)                                        AS OBLIGACIONES_SIN_ACADEMICO,
       COUNT(DISTINCT IDENTIFICACION)                  AS CLIENTES_SIN_ACADEMICO,
       CAST(SUM(TOTAL)/1000000 AS DECIMAL(18,1))       AS TOTAL_MM
FROM Financiera.Cartera_Gestion
WHERE NULLIF(LTRIM(RTRIM(ISNULL(NOM_UNIDAD, ''))), '') IS NULL
  AND NOMBRE_TIPO_CLIENTE = 'ESTUDIANTES';
-- Linea base medida el 2026-08-27 (antes de la corrida): 3.373 oblig / 1.360 cli / $849,5 MM.
-- Esperado despues: ~173 clientes / ~900 obligaciones. Si sigue en ~1.360, el 2do cruce
-- no entro: revisar que #ACAD_CEDULA se haya poblado en el PASO 3.


/*-------------------------------------------------------------------------------------------
  3) MARCA_ACADEMICA -- la escalera es nunca-NULL por diseno. 0 vacias es la salud.
-------------------------------------------------------------------------------------------*/
SELECT MARCA_ACADEMICA,
       COUNT(*)                                        AS OBLIGACIONES,
       COUNT(DISTINCT IDENTIFICACION)                  AS CLIENTES
FROM Financiera.Cartera_Gestion
GROUP BY MARCA_ACADEMICA
ORDER BY OBLIGACIONES DESC;

SELECT SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(MARCA_ACADEMICA,''))),'')         IS NULL THEN 1 ELSE 0 END) AS MARCA_VACIA,
       SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(MARCA_ACADEMICA_DETALLE,''))),'') IS NULL THEN 1 ELSE 0 END) AS DETALLE_VACIO,
       COUNT(*)                                                                                            AS TOTAL
FROM Financiera.Cartera_Gestion;


/*-------------------------------------------------------------------------------------------
  4) PROPAGACION DE LA COLUMNA a las demas tablas que materializa el SP.
     Cartera_Foto_Ayer y Cartera_Destiempo_ZOHO la heredan solas (SELECT *); si alguna
     quedo sin la columna, la herencia por nombre fallo.
-------------------------------------------------------------------------------------------*/
SELECT 'Cartera_Total'          AS TABLA, COL_LENGTH('Financiera.Cartera_Total','CLASIFICACION_CARTERA')          AS TIENE_COLUMNA
UNION ALL SELECT 'Cartera_Gestion',       COL_LENGTH('Financiera.Cartera_Gestion','CLASIFICACION_CARTERA')
UNION ALL SELECT 'Cartera_Foto_Ayer',     COL_LENGTH('Financiera.Cartera_Foto_Ayer','CLASIFICACION_CARTERA')
UNION ALL SELECT 'Cartera_Destiempo_ZOHO',COL_LENGTH('Financiera.Cartera_Destiempo_ZOHO','CLASIFICACION_CARTERA')
UNION ALL SELECT 'Creditos_pagos_CTAYUDA',COL_LENGTH('Financiera.Creditos_pagos_CTAYUDA','CLASIFICACION_CARTERA');


/*-------------------------------------------------------------------------------------------
  5) CUADRE DE VOLUMEN -- que la corrida no perdio ni multiplico filas.
     Referencia del 2026-08-27: 259.818 obligaciones / 81.7k clientes aprox.
     Una fila = una OBLIGACION, no una persona.
-------------------------------------------------------------------------------------------*/
SELECT (SELECT COUNT(*) FROM Financiera.Cartera_Total)     AS FILAS_TOTAL,
       (SELECT COUNT(*) FROM Financiera.Cartera_Gestion)   AS FILAS_GESTION,
       (SELECT COUNT(*) FROM Financiera.Cartera_Foto_Ayer) AS FILAS_FOTO_AYER;
