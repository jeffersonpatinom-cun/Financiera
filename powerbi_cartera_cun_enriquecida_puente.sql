/*===========================================================================================
  CARTERA CUN ENRIQUECIDA — CONSULTA PUENTE PARA POWER BI DESKTOP
  -------------------------------------------------------------------------------------------
  Autor    : Analitica financiera - Universidad CUN
  Fecha    : 2026-08-28
  Proposito: Alimentar el modelo de Power BI EN VIVO mientras el job de
             Usp_Cartera_CUN_Asesor_Unico empieza a correr a diario.

  COMO SE REEMPLAZA DESPUES
  -------------------------
  Cuando el job este corriendo, esta consulta entera se sustituye por:

      SELECT * FROM CUN_REPOSITORIO.Financiera.Cartera_CUN_Asesor_Unico

  y el modelo NO se rompe: los nombres de columna de aqui son exactamente los que
  produce el SP ajustado. Por eso este archivo se aparta del query original en tres
  puntos que parecen cosmeticos y no lo son:

    1. Las columnas de Cartera_Gestion van SUFIJADAS `_GESTION`
       (ESTADO_ALUMNO_GESTION, MARCA_ACADEMICA_GESTION, PROMEDIO_GESTION). En el query
       viejo salian sin sufijo porque omitia las homonimas de Zoho. Aqui se proyectan
       LAS DOS, igual que la tabla: `Estado_alumno` / `Promedio` son de Zoho y las
       `_GESTION` son de cartera. Cualquier medida que hoy lea `ESTADO_ALUMNO` a secas
       hay que repuntarla a `ESTADO_ALUMNO_GESTION`, o quedara leyendo la de Zoho.
    2. `Periodo_Fix` se llama `Periodo` (el CAST se conserva).
    3. `Hora_de_modificación_TIPIFICACION` se llama `Hora_modificacion_tipif`.

  Se agregan ademas las 12 columnas que el query original traia de mas o de menos
  respecto de la tabla: CLASIFICACION_CARTERA, CICLO, MODALIDAD, RES_PERFIL_RIESGO,
  RES_SCORE, los dos RECAUDO_PAGOS_*, AUD_FECHA_PROCESAMIENTO, MARCA_CARGA_DESTIEMPO,
  METODOLOGIA_PERIODO, FECHA_INICIO, FECHA_FIN, y MARCA_ACADEMICA_DETALLE_GESTION.

  Salida: 110 columnas, una fila por Id de Cartera_CUN.
===========================================================================================*/

WITH Gestion_Clasificada AS (
    /* CLASIFICACION_CARTERA con la regla de refinanciados (decision de Cartera 2026-08-28).

       La regla base es por PERIODO: CUENTAS POR COBRAR si el periodo esta vigente o no ha
       iniciado, CARTERA si ya cerro. Verificado: 0 pares identificacion+periodo con las dos.

       ENCIMA de eso va la regla nueva: el estudiante que arrastra deuda de un periodo
       cerrado Y ADEMAS debe del periodo vigente tiene tratamiento de cobranza distinto,
       asi que TODAS sus obligaciones pasan a 'CXC REFINANCIADO'. Medido al 2026-08-28:
       4.748 estudiantes / 22.062 obligaciones / $5.874,4 MM.

       El MIN <> MAX es el truco para "tiene mas de un valor distinto": COUNT(DISTINCT)
       no se admite como funcion de ventana en SQL Server. Alfabeticamente
       'CARTERA' < 'CUENTAS POR COBRAR', asi que MIN y MAX solo diferen cuando estan ambas.

       OJO -- la ventana se evalua sobre Cartera_Gestion COMPLETA, no sobre el resultado
       del JOIN con Cartera_CUN. Un estudiante puede tener obligaciones que no estan en el
       CRM; particionar despues del JOIN daria un resultado distinto y silenciosamente malo.

       Consecuencia de diseno: CLASIFICACION_CARTERA deja de ser funcion solo del PERIODO
       y pasa a depender de la cartera completa del estudiante. Dos obligaciones del mismo
       periodo pueden quedar distinto si sus dueños tienen carteras distintas. Es
       deliberado, pero invalida cualquier logica que asuma "una clasificacion por periodo". */
    SELECT
        g.NUMERO_CREDITO,
        g.ESTADO_ALUMNO,
        g.MARCA_ACADEMICA,
        g.MARCA_ACADEMICA_DETALLE,
        g.PROMEDIO,
        g.ultimoaccesoplataformlimpio,
        g.CICLO,
        g.MODALIDAD,
        g.RES_PERFIL_RIESGO,
        g.RES_SCORE,
        g.RECAUDO_PAGOS_NOMBRE_CAJA,
        g.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
        g.AUD_FECHA_PROCESAMIENTO,
        CASE
            WHEN MIN(g.CLASIFICACION_CARTERA) OVER (PARTITION BY g.IDENTIFICACION)
              <> MAX(g.CLASIFICACION_CARTERA) OVER (PARTITION BY g.IDENTIFICACION)
                THEN 'CXC REFINANCIADO'
            ELSE g.CLASIFICACION_CARTERA
        END AS CLASIFICACION_CARTERA
    FROM CUN_REPOSITORIO.Financiera.Cartera_Gestion g
),
Asesor_Dedup AS (
    /* 278.629 filas -> 85.084. Asesor_Unico es funcionalmente unico por
       identificacion (0 identificaciones con >1 asesor distinto), asi que
       MIN() no pierde informacion. Sin esta pre-agregacion el JOIN por
       identificacion explota a ~62M de filas (fan-out N x N). */
    SELECT
        CONVERT(varchar(20), a.[Número_de_identificación])       AS ident,
        MIN(CONVERT(varchar(200), a.Asesor_Unico))               AS Asesor_Unico
    FROM [Financiera].[Cartera_CUN_Asesor_Unico] a
    WHERE a.[Número_de_identificación] IS NOT NULL
      AND a.[Número_de_identificación] <> ''
    GROUP BY CONVERT(varchar(20), a.[Número_de_identificación])
),
Destiempo_Dedup AS (
    /* 38.974 filas -> 38.968: 6 NUMERO_CREDITO duplicados que reintroducirian
       fan-out. MARCA_CARGA_DESTIEMPO es funcionalmente unica por credito
       (38.968 combinaciones credito+marca), asi que MAX() no altera el dato;
       va agregada porque de lo contrario el GROUP BY no compila (error 8120). */
    SELECT
        d.NUMERO_CREDITO,
        CONVERT(varchar(10), MAX(TRY_CONVERT(date, d.FECHA_REAL_CARGA_NDB, 103)), 103)
            AS FECHA_REAL_CARGA_NDB,
        CONVERT(bit, MAX(CONVERT(tinyint, d.MARCA_CARGA_DESTIEMPO)))
            AS MARCA_CARGA_DESTIEMPO
    FROM CUN_REPOSITORIO.Financiera.Cartera_Destiempo_ZOHO d
    GROUP BY d.NUMERO_CREDITO
),
Tipificacion_Ultima AS (
    /* Una sola fila por Cartera_CUN: la ultima tipificacion.
       Medido 2026-08-25: 70.019 filas / 61.481 registros -> 61.481.

       Criterio de orden:
         1. FECHA_ORDEN DESC = COALESCE(Hora_de_modificación, Hora_de_creación),
            ambas parseadas con style 103 (DD/MM/YYYY HH:mm). Manda
            Hora_de_modificación; cuando esta NULL o vacia (17 de 70.019 filas
            medidas el 2026-08-25) cae a Hora_de_creación, que si esta poblada
            y parsea al 100%. El COALESCE va sobre el TRY_CONVERT, no sobre el
            texto: asi una cadena impresentable tambien cae al fallback en vez
            de ordenar como NULL.
            Hora_de_la_última_actividad NO entra: solo esta poblada en 4.365
            de 70.019 filas (6,2%).
         2. Desempate por la cadena de estados: entre filas del mismo instante,
            la ultima es aquella cuya Tipificación_nueva NO es la
            Tipificación_anterior de otra fila del mismo empate.
            Aplica a 702 de 71.585 cartera_id (1,0%).
         3. Fallback Id DESC, para empates ciclicos que (2) no resuelve. */
    SELECT cartera_id, Hecho_por, Tipificación_anterior, Tipificación_nueva,
           Hora_de_modificación
    FROM (
        SELECT
            CONVERT(varchar(30), e.Cartera_CUN)   AS cartera_id,
            e.Hecho_por,
            e.Tipificación_anterior,
            e.Tipificación_nueva,
            e.Hora_de_modificación,
            ROW_NUMBER() OVER (
                PARTITION BY CONVERT(varchar(30), e.Cartera_CUN)
                ORDER BY
                    f.FECHA_ORDEN DESC,
                    CASE WHEN EXISTS (
                        SELECT 1
                        FROM ZOHO.CRM.Historico_tipificacion_contact e2
                        WHERE CONVERT(varchar(30), e2.Cartera_CUN) = CONVERT(varchar(30), e.Cartera_CUN)
                          AND COALESCE(TRY_CONVERT(datetime, e2.Hora_de_modificación, 103),
                                       TRY_CONVERT(datetime, e2.Hora_de_creación,     103))
                            = f.FECHA_ORDEN
                          AND CONVERT(varchar(30), e2.Id) <> CONVERT(varchar(30), e.Id)
                          AND CONVERT(varchar(200), e2.Tipificación_anterior)
                            = CONVERT(varchar(200), e.Tipificación_nueva)
                    ) THEN 1 ELSE 0 END ASC,
                    CONVERT(varchar(30), e.Id) DESC
            ) AS rn
        FROM ZOHO.CRM.Historico_tipificacion_contact e
        CROSS APPLY (
            SELECT COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                            TRY_CONVERT(datetime, e.Hora_de_creación,     103)) AS FECHA_ORDEN
        ) f
    ) x
    WHERE x.rn = 1
)
SELECT
    /*--- Bloque Cartera_CUN: las 81 columnas, en el mismo orden que la tabla ---------*/
    c.[Id],
    c.[Año_acuerdo_de_pago],
    c.[Beneficio],
    c.[Cantidad_de_cuotas],
    c.[Celular],
    c.[Contacto_tipo_gestión],
    c.[Creado_por],
    c.[Hora_de_creación],
    c.[Número_de_crédito],
    c.[Moneda],
    c.[Descripción],
    c.[Deuda_total],
    c.[Dirección_casa],
    c.[Días_de_mora],
    c.[Correo_electrónico],
    c.[No_participación_del_correo_electrónico],
    c.[Tasa_de_cambio],
    c.[Fecha],
    c.[Fecha_del_pago_según_acuerdo],
    c.[Fecha_de_cobro],
    c.[Fecha_de_pago_oportuno],
    c.[Fecha_de_pago_oportuno_reprogramado],
    c.[Fechahora_llamada],
    c.[Fecha_limite],
    c.[Fecha_vencimiento],
    c.[Identificador],
    c.[Estado_cartera],
    c.[Interesado],
    c.[Hora_de_la_última_actividad],
    c.[Locked],
    c.[Medio_de_pago],
    c.[Meses_de_acuerdo_de_pago],
    c.[Hora_de_modificación],
    c.[Motivo_de_no_acuerdo],
    c.[Modificado_por],
    c.[Documento_Cartera_CUN],
    c.[Nuevo],
    c.[Número_de_cuota],
    c.[Número_de_identificación],
    c.[Observaciones],
    c.[Observaciones_del_compromiso_de_pago],
    c.[Observaciones_pago_realizado],
    c.[Otro_teléfono],
    c.[Propietario_de_Cartera_CUN_Name],
    c.[Pago_realizado_por_el_estudiante],
    c.[Fecha_de_pago],
    /* Se conserva el CAST del query original, pero con el nombre de la tabla. */
    CAST(c.Periodo AS VARCHAR(20))              AS [Periodo],
    c.[Propietario_de_Cartera_CUN],
    c.[Plantilla],
    c.[Población],
    c.[Proceso_a_generar],
    c.[Programa_académico],
    c.[Regional],
    c.[Correo_electrónico_secundario],
    c.[Semestre],
    c.[Etiqueta],
    c.[Teléfono],
    c.[Tipificación_a_marcar],
    c.[Tipo_cliente],
    c.[Tipo_de_cartera],
    c.[Valor_pagado],
    c.[Modalidad_de_cancelación_de_suscripción],
    c.[Hora_de_cancelación_de_suscripción],
    c.[Valor_acuerdo_de_pago],
    c.[Valor_corriente],
    c.[Valor_del_pago_según_acuerdo],
    c.[Valor_del_pago_según_opción_de_pago],
    c.[Valor_de_compromiso],
    c.[Valor_mensual_de_pago],
    c.[Valor_original],
    c.[Valor_total],
    c.[Corriente],
    c.[Documento],
    c.[Último_acceso_plataforma],
    c.[Último_acceso_plataforma_limpio],
    c.[Nombre_causa],
    c.[Nombre_concepto],
    /* Promedio / Estado_alumno son los de ZOHO. Los de cartera van sufijados _GESTION. */
    c.[Promedio],
    c.[Ejecutivo_responsable],
    c.[Estado_alumno],
    c.[Marca_académica],

    /*--- Enriquecimientos, con los nombres exactos de la tabla -----------------------*/
    ct.ESTADO_ALUMNO                AS ESTADO_ALUMNO_GESTION,
    ct.MARCA_ACADEMICA              AS MARCA_ACADEMICA_GESTION,
    ct.MARCA_ACADEMICA_DETALLE      AS MARCA_ACADEMICA_DETALLE_GESTION,
    ct.PROMEDIO                     AS PROMEDIO_GESTION,
    ct.ultimoaccesoplataformlimpio  AS ultimoaccesomoodle,
    m.Meta_2026,
    d.FECHA_REAL_CARGA_NDB,
    e.Hecho_por,
    e.Tipificación_anterior,
    e.Tipificación_nueva,
    e.Hora_de_modificación          AS Hora_modificacion_tipif,
    u.Nombre_completo               AS [Usuarios.Nombre_completo],
    u.Correo_electrónico            AS [Usuarios.Correo_electrónico],
    u.Estado                        AS [Usuarios.Estado],
    u.Profile_Name                  AS [Usuarios.Profile_Name],
    u.Role_Name                     AS [Usuarios.Role_Name],
    a.Asesor_Unico,

    /*--- Columnas nuevas (van al final para no mover el orden de las existentes) -----*/
    ct.CLASIFICACION_CARTERA,
    ct.CICLO,
    ct.MODALIDAD,
    ct.RES_PERFIL_RIESGO,
    ct.RES_SCORE,
    ct.RECAUDO_PAGOS_NOMBRE_CAJA,
    ct.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
    ct.AUD_FECHA_PROCESAMIENTO,
    d.MARCA_CARGA_DESTIEMPO,
    p.descripcion_metod             AS METODOLOGIA_PERIODO,
    p.fec_inicio                    AS FECHA_INICIO,
    p.fec_fin                       AS FECHA_FIN
FROM ZOHO.CRM.Cartera_CUN c

/* El TRY_CONVERT del numero de credito se escribe una sola vez y se reutiliza
   en los 3 joins que lo necesitan. */
CROSS APPLY (SELECT TRY_CONVERT(numeric(18,0), c.[Número_de_crédito]) AS NUM_CREDITO) k

LEFT JOIN Gestion_Clasificada ct
       ON ct.NUMERO_CREDITO = k.NUM_CREDITO
LEFT JOIN CUN_REPOSITORIO.Financiera.Cartera_Meta_Comercial_Historico m
       ON m.NUMERO_CREDITO = k.NUM_CREDITO
LEFT JOIN Destiempo_Dedup d
       ON d.NUMERO_CREDITO = k.NUM_CREDITO
LEFT JOIN Tipificacion_Ultima e
       ON e.cartera_id = CONVERT(varchar(30), c.Id)
LEFT JOIN ZOHO.crm.Usuarios u
       ON u.Id = c.Modificado_por
LEFT JOIN Asesor_Dedup a
       ON a.ident = CONVERT(varchar(20), c.[Número_de_identificación])

/* Llave completa periodo + metodologia. Sin GROUP BY: la pareja
   (cod_periodo, descripcion_metod) ya es unica en la tabla. Depende de ct,
   por eso este JOIN va despues de Cartera_Gestion. */
LEFT JOIN DBO.Periodos_Calendario p
       ON p.cod_periodo       = c.PERIODO
      AND p.descripcion_metod = ct.MODALIDAD

WHERE c.[Número_de_identificación] IS NOT NULL
  AND c.[Número_de_identificación] <> '';
