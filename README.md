# ETL FCT_Ventas — `ETL_Zoho_llamadas.py`

Cruza `zoho.Base_Personas` con `coe.venta_contact_nuevo` por número de teléfono normalizado (últimos 10 dígitos) y carga el resultado en `coe.FCT_Zoho_Llamadas`.

---

## Contenido del repositorio

```
ETL_FCT_Ventas/
├── ETL_Zoho_llamadas.py     # ETL cruce Zoho × COE por teléfono → coe.FCT_Zoho_Llamadas
├── run_etl_zoho.bat         # Lanzador para el Programador de Tareas de Windows
├── .env                     # Variables de entorno (credenciales) — NO subir a Git
├── logs/                    # Logs en modo append (etl_zoho_llamadas.log)
└── README.md                # Este archivo
```

---

## Requisitos

- Python 3.10+
- Microsoft ODBC Driver 17 o 18 para SQL Server
- Acceso a la red del servidor `172.16.1.33`

### Instalación de dependencias

```bash
pip install pandas sqlalchemy pyodbc python-dotenv rapidfuzz
```

---

## Configuración

Crea un archivo `.env` en la misma carpeta con el siguiente contenido:

```env
# Obligatorias
ETL_DB_USER=coe
ETL_DB_PASSWORD=tu_contrasena

# Opcionales (valores por defecto)
ETL_DB_SERVER=172.16.1.33
ETL_DB_DATABASE=CUN_REPOSITORIO
ETL_ZOHO_TABLA_DESTINO=FCT_Zoho_Llamadas
ETL_ZOHO_TABLA_SCHEMA=coe
ETL_ZOHO_CHUNK_SIZE=5000
ETL_ZOHO_ANIO=2026          # Si no se define, usa el año actual
```

> El archivo `.env` contiene credenciales. Nunca lo subas a un repositorio de Git.

---

## Ejecución

```bash
python ETL_Zoho_llamadas.py

# Procesar un año específico:
ETL_ZOHO_ANIO=2025 python ETL_Zoho_llamadas.py
```

### Automatización (Programador de Tareas de Windows)

El script se ejecuta automáticamente lunes a viernes a las 09:00 y 15:00 mediante dos tareas:

- `ETL_Zoho_Llamadas_AM` — 09:00
- `ETL_Zoho_Llamadas_PM` — 15:00

El lanzador `run_etl_zoho.bat` gestiona la ejecución y el código de salida.

### Salida esperada en log

```
2026-marzo-10-martes 19:18:33 | INFO | NORMALIZACION   | SUCCESS | 0     | Tildes, caracteres especiales y mayusculas aplicados
2026-marzo-10-martes 19:18:34 | INFO | UNIF_PROGRAMAS  | SUCCESS | 7     | Programas unificados por similitud fuzzy
2026-marzo-10-martes 19:18:37 | INFO | PROGRAMA_JOIN   | SUCCESS | 49309 | Coincidencias Zoho-COE (>=70%): 10 de 84 pares unicos
2026-marzo-10-martes 19:18:37 | INFO | TRANSFORMACION  | SUCCESS | 97830 | 97830 -> 97830 registros
2026-marzo-10-martes 19:18:37 | INFO | CARGA           | START   | 97830 | coe.FCT_Zoho_Llamadas
2026-marzo-10-martes 19:31:00 | INFO | CARGA           | SUCCESS | 97830 | CUN_REPOSITORIO.coe.FCT_Zoho_Llamadas
```

---

## Flujo del proceso

```
[zoho.Base_Personas]        ──┐
                               ├── SQL (FULL OUTER JOIN por tel. normalizado) ──▶ EXTRACCIÓN
[coe.venta_contact_nuevo]   ──┘                                                    (pandas)
                                                │
                                                ▼
                                         TRANSFORMACIÓN
                                  1. Eliminar cols auxiliares (rn_zoho, rn_coe)
                                  2. Normalizar texto → MAYÚSCULAS
                                     (excepto emails y Programa_Detectado)
                                  3. Unificar programas por similitud fuzzy
                                  4. Crear PROGRAMA_LIMPIO_JOIN
                                  5. Descartar registros COE puros sin teléfono
                                  6. Agregar columna timestamp
                                                │
                                                ▼
                                    [coe.FCT_Zoho_Llamadas]
                                    DROP + CREATE + INSERT (replace)
```

---

## Tablas fuente

| Tabla | Schema | Descripción |
|---|---|---|
| `Base_Personas` | `zoho` | Prospectos y ventas registradas en Zoho CRM |
| `venta_contact_nuevo` | `coe` | Evaluaciones de llamadas del contact center (COE) |

## Filtros de extracción (Zoho)

```sql
CLASE_ACTUAL = 'Nuevo'
AND TIPO IN ('pregrado', 'postgrado')
AND ANIO = '<año_actual>'
```

---

## Tabla destino: `coe.FCT_Zoho_Llamadas`

Se recarga completa en cada ejecución (año en curso). Contiene todas las columnas de `zoho.Base_Personas` y `coe.venta_contact_nuevo`, más las columnas calculadas:

| Columna calculada | Origen | Descripción |
|---|---|---|
| `Telefono_Limpio` | JOIN | `ISNULL(tel_zoho, tel_coe)` — últimos 10 dígitos del teléfono |
| `llave_zoho` | Zoho | Clave de dedup: `PERIODO\|DOC_ALUM\|PROGRAMA` |
| `llave_llamadas` | COE | Clave de dedup: `Celular\|Fecha\|Hora_Llamada` |
| `tel_match` / `cel_match` | Ambos | Teléfono normalizado usado en el JOIN |
| `PROGRAMA_LIMPIO_JOIN` | Calculado | Programa unificado: prioridad PROGRAMA (Zoho) → fallback Programa_Detectado (COE) |
| `timestamp` | Auditoría | Fecha y hora de la última carga |

---

## Lógica SQL — Deduplicación antes del JOIN

### Zoho (`llave_zoho = PERIODO|DOC_ALUM|PROGRAMA`)
- **Prioridad 1:** `ESTADO_PAGO = 'PAGO'` — se conserva sobre cualquier otro estado
- **Prioridad 2 (desempate):** `FEC_VENTA` más reciente
  - Si todos los registros del grupo son `NO PAGO`, se conserva el más reciente

### COE (`llave_llamadas = Celular_Prospecto|Fecha|Hora_Llamada`)
- Sin prioridad específica — se conserva un registro por combinación

### JOIN
```sql
FULL OUTER JOIN ON RIGHT(tel_zoho, 10) = RIGHT(tel_coe, 10)
```
El teléfono se normaliza eliminando espacios, guiones y paréntesis antes de comparar.

---

## Lógica Python — Transformación

| Paso | Operación | Detalle |
|---|---|---|
| 1 | Eliminar auxiliares | Elimina `rn_zoho`, `rn_coe` (no van al destino) |
| 2 | Normalizar texto | Quita tildes, caracteres especiales y espacios dobles → MAYÚSCULAS. Excepción: emails (minúsculas) y `Programa_Detectado` (caso original) |
| 3 | Unificar programas | Clustering fuzzy (`fuzz.ratio ≥ 85`) sobre `PROGRAMA`. Asigna el nombre más frecuente como canónico |
| 4 | `PROGRAMA_LIMPIO_JOIN` | Une `PROGRAMA` (Zoho) con `Programa_Detectado` (COE). Prioridad: Zoho → fallback COE. Ignora nulos, vacíos y `'NO DETECTADO'` |
| 5 | Filtrar sin teléfono | Descarta solo registros **COE puro sin teléfono**. Los registros de Zoho sin teléfono se conservan |
| 6 | Auditoría | Agrega columna `timestamp` con la fecha/hora de la carga |

## Conservación de registros Zoho sin teléfono

Un registro de Zoho puede llegar al resultado con `Telefono_Limpio = NULL` si `TEL_CASA` estaba vacío y no hubo match con COE. Estos registros **se conservan** porque pueden contener datos valiosos (nombre, programa, estado de pago, etc.).

Solo se descartan los registros del lado COE que no tienen teléfono y no tienen match con Zoho.

## Estrategia de carga

Usa `if_exists='replace'` de pandas, que **elimina y recrea la tabla** en cada ejecución. Esto garantiza consistencia de esquema si cambian las columnas fuente, pero implica que:
- Los índices y permisos definidos a nivel SQL Server se pierden en cada ejecución
- No hay riesgo de datos parciales (es atómico dentro del `engine.begin()`)

---

## Errores comunes

| Error | Causa | Solución |
|---|---|---|
| `EnvironmentError: ETL_DB_USER / ETL_DB_PASSWORD` | Archivo `.env` ausente o incompleto | Crear/revisar el archivo `.env` |
| `RuntimeError: No se encontró un driver ODBC` | Driver de SQL Server no instalado | Instalar [ODBC Driver 18](https://learn.microsoft.com/es-es/sql/connect/odbc/download-odbc-driver-for-sql-server) |
| `SSL Provider: certificado no confiado` | ODBC Driver 18 valida SSL por defecto | Ya corregido con `TrustServerCertificate=yes` |
| `ValueError: La consulta no retornó registros` | La tabla fuente está vacía o el filtro de año no da resultados | Revisar las tablas fuente o usar `ETL_ZOHO_ANIO` para ajustar el año |
| `WARNING: Registros descartados` | Registros COE sin teléfono y sin datos Zoho | Normal si hay datos incompletos; revisar el volumen |

---

## Notas generales

- **ETL de carga completa**: no hay carga incremental.
- **Logs**: el script escribe en `logs/etl_zoho_llamadas.log` en modo append con formato estructurado `STEP | STATUS | ROWS | MSG`.
