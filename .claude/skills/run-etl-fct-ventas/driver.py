# -*- coding: utf-8 -*-
"""Driver del repositorio ETL_FCT_Ventas.

Este repo no es una app con ventana: es un conjunto de scripts que leen y
escriben contra SQL Server (172.16.1.33 / CUN_REPOSITORIO, autenticacion
Windows). La superficie que tocan casi todos los cambios es el ciclo
    dump -> editar el .sql -> deploy -> query de validacion
y eso es exactamente lo que este driver expone.

Uso:
    .venv/Scripts/python.exe .claude/skills/run-etl-fct-ventas/driver.py <cmd> [args]

Comandos:
    check                      Conectividad, version del motor, drivers ODBC.
    objects [patron]           Lista SPs y tablas cuyo nombre contiene <patron>.
    deps <texto>               SPs/vistas cuya DEFINICION menciona <texto>.
                               (Para saber quien consume una columna antes de tocarla.)
    dump <objeto> [-o file]    Vuelca la definicion viva de un SP/vista.
    columns <tabla> [patron]   Columnas de una tabla, con tipo y longitud.
    rows <tabla>               Conteo de filas y fecha de ultima modificacion.
    query <sql|@archivo.sql>   Ejecuta SELECT(s) y tabula el resultado.
                               Soporta multiples result sets.
    deploy <archivo.sql>       CREATE [OR ALTER] PROCEDURE -> ALTER PROCEDURE y lo
                               aplica. Solo compila; NO ejecuta el SP.
    exec-sp <nombre> --yes     Ejecuta un SP. Exige --yes: son minutos y escriben
                               en produccion.

Todo es de solo lectura salvo `deploy` y `exec-sp`.
"""
import argparse
import io
import re
import sys
import time

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

try:
    import pyodbc
except ImportError:
    sys.exit('Falta pyodbc. Instalar con: .venv/Scripts/python.exe -m pip install -r requirements.txt')

SERVER = '172.16.1.33'
DATABASE = 'CUN_REPOSITORIO'
CONN_STR = (
    'DRIVER={ODBC Driver 18 for SQL Server};'
    f'SERVER={SERVER};DATABASE={DATABASE};'
    'Trusted_Connection=yes;TrustServerCertificate=yes;Connect Timeout=30;'
)


def connect(query_timeout=600):
    """OJO: el timeout de QUERY va en conn.timeout, no en cursor.timeout.
    El cursor de pyodbc no acepta el atributo y falla silenciosamente."""
    cn = pyodbc.connect(CONN_STR, timeout=30)
    cn.autocommit = True
    cn.timeout = query_timeout
    return cn


def tabular(cur, limite=200):
    """Imprime el resultado actual del cursor como tabla de ancho fijo."""
    if cur.description is None:
        return 0
    cols = [c[0] for c in cur.description]
    filas = cur.fetchall()
    datos = [['' if v is None else str(v) for v in f] for f in filas[:limite]]
    anchos = [min(max([len(c)] + [len(f[i]) for f in datos]), 46) for i, c in enumerate(cols)]
    print('  ' + '  '.join(c[:w].ljust(w) for c, w in zip(cols, anchos)))
    print('  ' + '  '.join('-' * w for w in anchos))
    for f in datos:
        print('  ' + '  '.join(v[:w].ljust(w) for v, w in zip(f, anchos)))
    if len(filas) > limite:
        print('  ... %d filas mas (limite %d)' % (len(filas) - limite, limite))
    print('  [%d filas]' % len(filas))
    return len(filas)


# --------------------------------------------------------------------------- cmds
def cmd_check(a):
    print('Conectando a %s / %s (autenticacion Windows)...' % (SERVER, DATABASE))
    print('Drivers ODBC disponibles:')
    for d in pyodbc.drivers():
        print('   ', d)
    t0 = time.time()
    cn = connect(60)
    cur = cn.cursor()
    v = cur.execute('SELECT @@VERSION, DB_NAME(), SUSER_SNAME(), GETDATE()').fetchone()
    print('\n  Conectado en %.2fs' % (time.time() - t0))
    print('  Motor    :', v[0].split('\n')[0].strip())
    print('  Base     :', v[1])
    print('  Usuario  :', v[2])
    print('  Hora srv :', v[3])
    n = cur.execute("SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id)='Financiera'").fetchone()[0]
    print('  SPs en el esquema Financiera:', n)
    cn.close()


def cmd_objects(a):
    cn = connect(); cur = cn.cursor()
    pat = '%%%s%%' % (a.patron or '')
    cur.execute("""
        SELECT SCHEMA_NAME(o.schema_id)+'.'+o.name AS objeto, o.type_desc, o.modify_date
        FROM sys.objects o
        WHERE o.type IN ('P','U','V') AND o.name LIKE ?
        ORDER BY o.type_desc, objeto""", pat)
    tabular(cur)
    cn.close()


def cmd_deps(a):
    """Quien consume esto. Imprescindible antes de cambiar una columna."""
    cn = connect(); cur = cn.cursor()
    cur.execute("""
        SELECT SCHEMA_NAME(o.schema_id)+'.'+o.name AS objeto, o.type_desc, o.modify_date
        FROM sys.sql_modules m
        JOIN sys.objects o ON o.object_id = m.object_id
        WHERE m.definition LIKE ?
        ORDER BY objeto""", '%%%s%%' % a.texto)
    print('Modulos cuya definicion menciona "%s":' % a.texto)
    tabular(cur)
    cur.execute("""
        SELECT SCHEMA_NAME(o.schema_id)+'.'+o.name AS tabla, o.type_desc
        FROM sys.columns c
        JOIN sys.objects o ON o.object_id = c.object_id
        WHERE c.name = ? ORDER BY tabla""", a.texto)
    print('\nTablas/vistas que TIENEN una columna llamada "%s":' % a.texto)
    tabular(cur)
    cn.close()


def cmd_dump(a):
    cn = connect(); cur = cn.cursor()
    r = cur.execute("SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(?)",
                    a.objeto).fetchone()
    if not r:
        sys.exit('No existe (o no es un modulo con definicion): %s' % a.objeto)
    d = r[0]
    if a.o:
        open(a.o, 'w', encoding='utf-8').write(d)
        print('%s -> %s  (%d chars, %d lineas)' % (a.objeto, a.o, len(d), d.count('\n') + 1))
    else:
        print(d)
    cn.close()


def cmd_columns(a):
    cn = connect(); cur = cn.cursor()
    cur.execute("""
        SELECT c.column_id AS id, c.name, TYPE_NAME(c.system_type_id) AS tipo,
               c.max_length AS largo, c.is_nullable AS nulable
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(?) AND c.name LIKE ?
        ORDER BY c.column_id""", a.tabla, '%%%s%%' % (a.patron or ''))
    tabular(cur, limite=500)
    cn.close()


def cmd_rows(a):
    cn = connect(); cur = cn.cursor()
    cur.execute("""
        SELECT SCHEMA_NAME(t.schema_id)+'.'+t.name AS tabla,
               SUM(p.rows) AS filas, MAX(t.modify_date) AS modificada
        FROM sys.tables t
        JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
        WHERE t.name LIKE ?
        GROUP BY SCHEMA_NAME(t.schema_id), t.name
        ORDER BY filas DESC""", '%%%s%%' % a.tabla)
    tabular(cur)
    cn.close()


def cmd_query(a):
    sql = open(a.sql[1:], encoding='utf-8').read() if a.sql.startswith('@') else a.sql
    cn = connect(a.timeout); cur = cn.cursor()
    t0 = time.time()
    cur.execute(sql)
    n = 1
    while True:
        if cur.description is not None:
            print('--- result set %d' % n)
            tabular(cur, a.limite)
            n += 1
        if not cur.nextset():
            break
    print('  (%.2fs)' % (time.time() - t0))
    cn.close()


def cmd_deploy(a):
    """CREATE [OR ALTER] PROCEDURE -> ALTER PROCEDURE, y aplicar.

    sys.sql_modules devuelve siempre el texto ORIGINAL del CREATE, incluso si el
    objeto se creo con CREATE OR ALTER (queda como 'CREATE   PROCEDURE', con
    espacios multiples). Por eso el reemplazo es por regex y no literal.
    """
    d = open(a.archivo, encoding='utf-8').read()
    ddl, n = re.subn(r'\bCREATE\s+(OR\s+ALTER\s+)?PROCEDURE\b', 'ALTER PROCEDURE', d, count=1)
    if n != 1:
        sys.exit('No se encontro el encabezado CREATE/ALTER PROCEDURE en %s' % a.archivo)
    m = re.search(r'ALTER PROCEDURE\s+(\[?[\w]+\]?\.\[?[\w]+\]?)', ddl)
    nombre = m.group(1) if m else '(desconocido)'
    print('Objetivo: %s   (%d chars)' % (nombre, len(d)))
    cn = connect(a.timeout); cur = cn.cursor()
    t0 = time.time()
    cur.execute(ddl)
    print('  OK - compilado en %.2fs. El SP NO fue ejecutado.' % (time.time() - t0))
    r = cur.execute("SELECT modify_date FROM sys.objects WHERE object_id=OBJECT_ID(?)",
                    nombre.replace('[', '').replace(']', '')).fetchone()
    if r:
        print('  modify_date:', r[0])
    cn.close()


def cmd_exec_sp(a):
    if not a.yes:
        print('REHUSADO: "%s" escribe en PRODUCCION y puede tardar minutos.' % a.nombre)
        print('  SP_Cartera_Total dura 10-13 min y ya murio una vez (error 596) por')
        print('  contencion con la recarga de ICEBERG.cartera_corporativa a media tarde.')
        print('  Si estas seguro y estas en ventana de baja contencion, repetir con --yes.')
        sys.exit(2)
    cn = connect(a.timeout); cur = cn.cursor()
    print('Ejecutando EXEC %s ...' % a.nombre)
    t0 = time.time()
    cur.execute('EXEC ' + a.nombre)
    while cur.nextset():
        pass
    print('  OK en %.1fs' % (time.time() - t0))
    cn.close()


def main():
    p = argparse.ArgumentParser(description='Driver del repo ETL_FCT_Ventas')
    s = p.add_subparsers(dest='cmd', required=True)

    s.add_parser('check').set_defaults(fn=cmd_check)

    q = s.add_parser('objects'); q.add_argument('patron', nargs='?', default='')
    q.set_defaults(fn=cmd_objects)

    q = s.add_parser('deps'); q.add_argument('texto'); q.set_defaults(fn=cmd_deps)

    q = s.add_parser('dump'); q.add_argument('objeto'); q.add_argument('-o')
    q.set_defaults(fn=cmd_dump)

    q = s.add_parser('columns'); q.add_argument('tabla')
    q.add_argument('patron', nargs='?', default=''); q.set_defaults(fn=cmd_columns)

    q = s.add_parser('rows'); q.add_argument('tabla'); q.set_defaults(fn=cmd_rows)

    q = s.add_parser('query'); q.add_argument('sql')
    q.add_argument('--limite', type=int, default=200)
    q.add_argument('--timeout', type=int, default=600); q.set_defaults(fn=cmd_query)

    q = s.add_parser('deploy'); q.add_argument('archivo')
    q.add_argument('--timeout', type=int, default=600); q.set_defaults(fn=cmd_deploy)

    q = s.add_parser('exec-sp'); q.add_argument('nombre'); q.add_argument('--yes', action='store_true')
    q.add_argument('--timeout', type=int, default=1800); q.set_defaults(fn=cmd_exec_sp)

    a = p.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
