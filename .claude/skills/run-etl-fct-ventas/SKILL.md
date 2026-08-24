---
name: run-etl-fct-ventas
description: Ejecutar, inspeccionar y desplegar el ETL de cartera de ETL_FCT_Ventas contra SQL Server. Usar cuando pidan correr/probar el ETL, conectarse a la base, listar o volcar un stored procedure, ver columnas de una tabla, desplegar un SP, validar Cartera_Gestion o MARCA_ACADEMICA, o generar los documentos Word/Excel del repo.
---

# ETL_FCT_Ventas

No es una app con ventana. Es un conjunto de scripts Python y archivos `.sql` que
leen y escriben contra **SQL Server `172.16.1.33` / `CUN_REPOSITORIO`** con
autenticación Windows. Casi todo cambio aquí recorre el mismo ciclo:

```
dump el SP  →  editar el .sql  →  deploy (compila)  →  query de validación
```

Ese ciclo es el driver: `.claude/skills/run-etl-fct-ventas/driver.py`.

Todas las rutas son relativas a la raíz del repo.

## Prerrequisitos

El venv ya existe. Verificar que responde:

```bash
.venv/Scripts/python.exe --version          # Python 3.13.14
```

Si falta o está roto, recrearlo (Windows, `cmd`):

```bat
setup_venv.bat
```

Requiere **ODBC Driver 18 for SQL Server**. Es el único instalado en esta máquina
—el README menciona "17 o 18", pero el 17 no está— y el driver lo exige por nombre.

## Correr (camino del agente)

Usar siempre el python del venv por ruta explícita. `python` a secas resuelve al
venv solo si el shell heredó el PATH.

```bash
D=".venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py"
```

**Empezar siempre por `check`.** Si esto falla, no es el código: es la VPN o la red.

```bash
.venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py check
```

```
  Conectado en 0.19s
  Motor    : Microsoft SQL Server 2022 (RTM-GDR) (KB5091158) - 16.0.1180.1 (X64)
  Base     : CUN_REPOSITORIO
  Usuario  : CUNADM\jefferson_patinom
  SPs en el esquema Financiera: 44
```

### Comandos

| Comando | Para qué |
|---|---|
| `check` | Conectividad, versión del motor, drivers ODBC |
| `objects [patrón]` | SPs y tablas cuyo **nombre** contiene el patrón |
| `deps <texto>` | SPs/vistas cuya **definición** menciona el texto, + tablas con esa columna |
| `dump <objeto> [-o f]` | Vuelca la definición viva de un SP |
| `columns <tabla> [pat]` | Columnas con tipo y longitud |
| `rows <tabla>` | Conteo de filas y fecha de última modificación |
| `query <sql\|@archivo>` | Ejecuta SELECT(s), tabula, soporta varios result sets |
| `deploy <archivo.sql>` | `CREATE [OR ALTER] PROCEDURE` → `ALTER PROCEDURE` y compila |
| `exec-sp <n> --yes` | Ejecuta un SP (exige `--yes`) |

Todo es de solo lectura salvo `deploy` y `exec-sp`.

### El ciclo completo, verificado

**1. Averiguar quién consume lo que vas a tocar.** Este paso no es opcional: hay
tres SP que escriben la misma columna y uno de ellos la *recalcula* por su cuenta.

```bash
.venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py deps MARCA_ACADEMICA_DETALLE
```

```
Modulos cuya definicion menciona "MARCA_ACADEMICA_DETALLE":
  Financiera.SP_Cartera_Total                 SQL_STORED_PROCEDURE  2026-08-21 17:09:57
  Financiera.Usp_Cartera_CUN_Asesor_Unico     SQL_STORED_PROCEDURE  2026-08-21 17:12:32
  Financiera.USP_Foto_Meta_Comercial_Mensual  SQL_STORED_PROCEDURE  2026-08-21 17:45:41

Tablas/vistas que TIENEN una columna llamada "MARCA_ACADEMICA_DETALLE":
  Financiera.Cartera_Destiempo_ZOHO  /  Cartera_Foto_Ayer  /  Cartera_Gestion  /  Cartera_Total
```

**2. Volcar la definición viva a un archivo.** Nunca editar los `.sql` del repo
asumiendo que reflejan producción: varios están desfasados.

```bash
.venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py dump Financiera.Usp_Cartera_CUN_Asesor_Unico -o /tmp/probe.sql
```

**3. Editar** el archivo volcado con reemplazos exactos y verificados (ver
`aplicar_marca_academica_v2.py` como plantilla: cuenta ocurrencias y aborta si no
son exactamente las esperadas, en vez de reemplazar a ciegas).

**4. Desplegar.** Compila y verifica referencias; **no** ejecuta el SP.

```bash
.venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py deploy alter_usp_cartera_cun_asesor_unico_detalle.sql
```

```
Objetivo: [Financiera].[Usp_Cartera_CUN_Asesor_Unico]   (12336 chars)
  OK - compilado en 0.03s. El SP NO fue ejecutado.
```

**5. Validar.** Un `.sql` con varios `SELECT` se tabula como varios result sets:

```bash
.venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py query @marca_academica_combinaciones.sql --limite 6
```

Chequeo estándar tras una corrida del job (0 vacías es la condición de salud):

```bash
.venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py query "
SELECT MARCA_ACADEMICA, COUNT(*) OBLIGACIONES, COUNT(DISTINCT IDENTIFICACION) CLIENTES
FROM Financiera.Cartera_Gestion GROUP BY MARCA_ACADEMICA ORDER BY OBLIGACIONES DESC;
SELECT SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(MARCA_ACADEMICA,''))),'') IS NULL THEN 1 ELSE 0 END) MARCA_VACIA,
       SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(MARCA_ACADEMICA_DETALLE,''))),'') IS NULL THEN 1 ELSE 0 END) DETALLE_VACIO,
       COUNT(*) TOTAL FROM Financiera.Cartera_Gestion;"
```

### Ejecutar un SP

`exec-sp` rehúsa sin `--yes` y sale con código 2:

```bash
.venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py exec-sp Financiera.SP_Cartera_Total
```

```
REHUSADO: "Financiera.SP_Cartera_Total" escribe en PRODUCCION y puede tardar minutos.
```

La guarda es deliberada. `SP_Cartera_Total` corre solo en el job de las **6:00 am**,
dura 10-13 min y **ya murió una vez** (error 596, "session is in the kill state")
por contención con la recarga de `ICEBERG.cartera_corporativa` a media tarde. Antes
de usar `--yes`: respaldar, y estar en ventana de baja contención.

## Generar los documentos Word

Segunda superficie del repo: varios `generar_*.py` producen `.docx`/`.xlsx` desde
datos ya consultados. Verificado en esta máquina:

```bash
.venv/Scripts/python.exe generar_doc_marca_academica.py
```

Lee `comb.json` + `comb_detalle.json` (salida del `query`) y escribe el `.docx`.

## Gotchas

- **`conn.timeout`, nunca `cur.timeout`.** El cursor de pyodbc no acepta el
  atributo. Si lo pones ahí, el timeout largo no aplica y la consulta muere a los
  30 s sin explicar por qué.

- **Error 207 al hacer `ALTER PROCEDURE` tras agregar una columna.** Si el SP tiene
  un CTE que lee de la tabla **física** (p. ej. `Cartera_Total_Dedup` sobre
  `Financiera.Cartera_Total`), la resolución diferida valida esa columna en tiempo
  de compilación y falla porque todavía no existe. Hay que hacer el
  `ALTER TABLE ... ADD <col> NULL` **antes** del `ALTER PROCEDURE`. En runtime el
  `DROP` + `SELECT INTO` la recrea con el tipo real.

- **`SELECT INTO` decide el ancho, no tu bootstrap.** La columna se creó como
  `varchar(50)` y tras la corrida quedó en `varchar(102)`. No asumas que el ancho
  del bootstrap sobrevive.

- **`sys.sql_modules` devuelve `CREATE   PROCEDURE` con espacios múltiples** cuando
  el objeto se creó con `CREATE OR ALTER`. Un `str.replace('CREATE PROCEDURE', ...)`
  literal falla en silencio. `deploy` usa regex por esto.

- **Una fila = una obligación, no una persona.** `Cartera_Gestion` tiene 258.841
  filas y 81.753 clientes. Contar filas infla los volúmenes ~3x. Para dimensionar
  campañas: `COUNT(DISTINCT IDENTIFICACION)`.

- **Columnas homónimas que no tienen nada que ver.**
  `ABOHORQUEZ.Inicio_Clases_Detalle_Pagos.MARCA_ACADEMICA` es `varchar(2)` con
  valores `SI`/NULL, de otro proceso. `deps` la lista; no la toques.

- **`MAX()` sobre fechas guardadas como varchar ordena como texto.**
  `FECHA_REAL_CARGA_NDB` es `dd/MM/yyyy`, así que `"31/07" > "09/08"`. Usar
  `MAX(TRY_CONVERT(date, col, 103))`.

- **Word bloquea el archivo.** Regenerar un `.docx` abierto en Word da
  `PermissionError: [Errno 13]`. Cerrarlo y reintentar.

- **Heredocs de Bash con Python acentuado se rompen.** Para scripts largos, escribir
  el archivo con la herramienta Write, no con `cat <<'EOF'`.

- **PowerShell aquí es 5.1**: no hay `&&`, ni ternario, ni `??`. Encadenar con
  `; if ($?) { ... }`, o usar el Bash tool.

## Troubleshooting

| Síntoma | Causa | Arreglo |
|---|---|---|
| `Login timeout expired` / `TCP Provider: error 0x2746` en `check` | Sin red hacia `172.16.1.33` | Conectar la VPN. No es el código |
| `Data source name not found` | Falta ODBC Driver 18 | Instalarlo; el driver lo exige por nombre exacto |
| `Invalid column name 'X'` (207) al desplegar | Columna nueva consumida por un CTE que lee la tabla física | `ALTER TABLE ... ADD` antes del `ALTER PROCEDURE` |
| `No se encontro el encabezado CREATE/ALTER PROCEDURE` | El `.sql` no es una definición de SP, o el volcado se truncó | Volver a `dump` |
| `PermissionError: [Errno 13]` al generar un `.docx` | Archivo abierto en Word | Cerrarlo |
| `error 596: session is in the kill state` | `SP_Cartera_Total` corrido en horario de contención | Correrlo temprano. Hizo rollback limpio, no corrompe |
