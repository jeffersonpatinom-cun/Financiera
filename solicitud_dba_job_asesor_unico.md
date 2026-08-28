# Solicitud al DBA — encadenar paso al `JOB_Cartera_Total`

**Asunto sugerido:** Solicitud de cambio en `JOB_Cartera_Total` — agregar paso para `Usp_Cartera_CUN_Asesor_Unico`

---

Buen día,

Escribo para solicitar un cambio en el SQL Agent del servidor **172.16.1.33**, que no
puedo aplicar yo mismo: el usuario `CUNADM\jefferson_patinom` no pertenece a ninguno de
los roles de Agent (`SQLAgentUserRole`, `SQLAgentReaderRole`, `SQLAgentOperatorRole`) ni
tiene permiso de ejecución sobre `msdb.dbo.sp_add_jobstep` ni `sp_update_jobstep`.

**Qué se necesita**

Agregar un segundo paso al job existente `JOB_Cartera_Total`, que ejecute:

```sql
EXEC Financiera.Usp_Cartera_CUN_Asesor_Unico;
```

sobre la base `CUN_REPOSITORIO`.

**Por qué**

Ese procedimiento materializa `Financiera.Cartera_CUN_Asesor_Unico`, que alimenta el
tablero de gestión de cobranza en Power BI. Hoy se ejecuta a mano —las últimas corridas
fueron el 10, 13, 21, 24 y 26 de agosto—, de modo que la tabla queda desactualizada entre
una y otra: al 28 de agosto tiene 305.332 filas frente a 308.062 en el origen.

El procedimiento lee `Financiera.Cartera_Gestion`, que ese mismo job reconstruye a diario.
Si corriera antes, tomaría la cartera del día anterior sin arrojar error: entregaría datos
viejos en silencio. Por eso se solicita encadenarlo al job en lugar de programarlo por
separado a una hora fija — así el orden queda garantizado por construcción.

**Impacto en la ventana de ejecución**

`JOB_Cartera_Total` inicia a las 06:00 y sus últimas corridas duraron entre 12 y 20
minutos. El procedimiento nuevo tarda entre 2 y 5 minutos, así que el job quedaría en
15 a 25 minutos aproximadamente.

**Un detalle importante de la configuración**

El paso 1 actual tiene `on_success_action = 1` ("salir informando éxito"). Si se agrega el
paso 2 sin modificar ese valor, el job termina en el paso 1 y el paso nuevo no se ejecuta
nunca, sin generar error ni alerta. El script adjunto ya incluye el `sp_update_jobstep`
que lo cambia a `3` ("ir al siguiente paso"), además de dejar el `@start_step_id` en 1.

**Adjunto**

`configurar_job_asesor_unico.sql` — script idempotente, comentado, con la verificación
posterior incluida. Contempla también, comentada, la alternativa de un job independiente
por si prefieren no modificar `JOB_Cartera_Total`; en ese caso convendría revisar el
margen, ya que la corrida del 27 de agosto duró 20 minutos.

Quedo atento a cualquier ajuste que consideren necesario, y con gusto acompaño la
ejecución y la validación posterior.

Cordialmente,

**Jefferson Patiño**
Analítica financiera — Universidad CUN
