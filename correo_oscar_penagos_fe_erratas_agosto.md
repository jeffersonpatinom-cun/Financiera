# Correo — Fe de erratas del cierre de agosto (Óscar Penagos)

**Para:** Óscar Penagos — Coordinador de Recaudo y Cartera
**CC:** _(jefe directo de Analítica / Vicerrectoría de Servicios Digitales, según corresponda)_
**Asunto:** Fe de erratas — Informe de cierre de agosto 2026: corrección de las cifras de gestión y recaudo por asesor
**Adjuntos:**
1. `Informe_Ejecutivo_Cierre_Agosto_2026.docx` — versión 2, corregida
2. `Base_Gestion_Asesores_Agosto_2026.xlsx` — base de trabajo (la primera hoja es la fe de erratas)

---

Óscar, buen día.

Te escribo para corregir las cifras de gestión y recaudo que te entregamos el 2 de septiembre. **El error es nuestro** y lo detectamos revisando cómo se atribuye el trabajo a cada asesor, antes de que las cifras se usaran para la liquidación. Te adjunto el informe corregido y la base con el detalle.

**Qué pasó.** El informe identificaba al asesor responsable con un campo del CRM que está diseñado para nunca quedar vacío: cuando nadie ha tipificado un registro, ese campo cae al usuario que lo modificó por última vez o al propietario asignado de la cartera. Sirve muy bien para saber *de quién es* una cartera, pero no para saber *quién la trabajó*. Como el robot CUN DIGITAL tipifica en volumen, su trabajo terminaba acreditado a asesores de carne y hueso.

**Las cifras corregidas:**

| Cifra | Publicado 2 sep | Corregido | Naturaleza |
|---|---|---|---|
| Gestiones de agosto | 61.767 | **22.941** | Error de cálculo |
| Asesores activos | 18 | **14** | Error de cálculo |
| Personas gestionadas | 18.716 | **18.483** | Sin cambio relevante |
| Pagos registrados | 19.002 | **9.281** | Cambio de criterio |
| Valor recaudado | $5.483,9 MM | **$2.408,8 MM** | Cambio de criterio |
| Efectividad | 32,1% | **18,1%** | Cambio de criterio |

Quiero separar con claridad dos cosas distintas, porque no tienen la misma gravedad:

**1. Lo que estaba mal (error de cálculo).** De las 61.767 gestiones que reportamos, **42.768 las ejecutó el robot, no un asesor**. Las gestiones humanas reales de agosto fueron 22.941, repartidas entre 14 asesores y no 18. Esta parte es un error nuestro, sin matices.

**2. Lo que cambió de criterio.** El recaudo ya no cuenta cualquier pago de cartera asignada. Ahora exige que la persona haya sido gestionada y que el pago sea **posterior a la primera gestión**. La conciliación:

| Concepto | Pagos | Valor |
|---|---|---|
| Publicado el 2 de septiembre | 19.002 | $5.483,9 MM |
| (–) De personas que nadie gestionó | 5.158 | $1.849,5 MM |
| (–) Pago anterior a la primera gestión | 4.855 | $1.292,4 MM |
| **(=) Atribuible a la gestión del equipo** | **9.281** | **$2.408,8 MM** |

**Lo que NO empeoró, y quiero subrayarlo.** Bajo el criterio anterior, las personas gestionadas que pagaron siguen siendo 5.974 y la efectividad 32,3% — prácticamente lo que te reportamos. La caída a 18,1% **no es un desplome del equipo**: es el efecto de exigir que el pago llegue después de la gestión. El trabajo del equipo no fue peor de lo que creíamos; lo que teníamos mal era la vara de medir.

**Para la liquidación de agosto**, la sección 6 del informe adjunto trae el detalle nominal por asesor —gestiones, personas, pagos atribuibles y valor—. Te pido usar esa tabla y no las cifras anteriores: la diferencia por asesor es material.

**Dos hallazgos que salieron de la revisión y valen para septiembre:**

- **El esfuerzo llega tarde.** La mediana entre el contacto y el pago es de 7 días, pero el 33,5% de la gestión del mes se ejecuta en la última semana. Buena parte de ese trabajo cobra en septiembre y no alcanza a contarse en el cierre de agosto. Adelantar carga a la primera quincena no cuesta un peso más.
- **La tipificación que anticipa el pago es «genera acuerdo de pago verbal»**, con 19,7% de conversión contra 13,6% del seguimiento simple. Ojo con «ya realizó el pago», que aparece con 61,6%: esa no mide gestión, se aplica porque el pago ya ocurrió.

**Qué ya está corregido.** El procedimiento que alimenta el tablero ya distingue quién gestionó de quién tiene asignada la cartera (columnas `GESTION_ASESOR`, `GESTION_MARCA` y `GESTION_PAGO_POST_MARCA`), y la corrección quedó documentada en las reglas de negocio para que no se reintroduzca. Los informes de septiembre en adelante salen ya con el criterio correcto.

Quedo atento a tus comentarios y con gusto lo revisamos juntos si te sirve.

Un saludo,

**Jefferson Patiño**
Analítica financiera — Universidad CUN
