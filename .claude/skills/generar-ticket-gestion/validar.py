# -*- coding: utf-8 -*-
"""Valida un borrador de ticket de gestion antes de pegarlo en el formulario.

Dos reglas que un borrador viola sin que uno se de cuenta:
  1. Pasarse de 100 palabras (se cuenta mal a ojo).
  2. Colarse detalle tecnico: nombres de objetos, columnas, codigos de error.
     El ticket lo lee un coordinador de area, no un ingeniero.

Uso:
    .venv/Scripts/python.exe .claude/skills/generar-ticket-gestion/validar.py borrador.txt
    ... | .venv/Scripts/python.exe .claude/skills/generar-ticket-gestion/validar.py -

Sale con codigo 1 si el borrador no pasa.
"""
import io
import re
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

LIMITE = 100

# Jerga que NO debe aparecer -> como decirlo en el ticket.
TECNICO = [
    (r'\bCTE\b',                      'omitir: es detalle de implementacion'),
    (r'\bvarchar\b|\bnvarchar\b|\bint\b\(',  'omitir: tipo de dato'),
    (r'\bCROSS APPLY\b|\bLEFT JOIN\b|\bINNER JOIN\b|\bFULL OUTER\b', 'omitir: detalle de consulta'),
    (r'\bSELECT\b|\bINSERT\b|\bUPDATE\b|\bDROP\b|\bALTER\b|\bMERGE\b|\bTRUNCATE\b',
                                      'omitir: sentencia SQL'),
    (r'\bCOALESCE\b|\bISNULL\b|\bCASE WHEN\b|\bROW_NUMBER\b', 'omitir: funcion SQL'),
    (r'\bpyodbc\b|\bODBC\b|\bSQL Server\b|\bOracle\b|\bOPENQUERY\b', 'omitir: tecnologia'),
    (r'\berror\s+\d{3}\b|\bcodigo\s+\d{3}\b', 'omitir: codigo de error'),
    (r'\bNULL\b',                     'decir "sin informacion" o "en blanco"'),
    (r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', 'omitir: direccion IP'),
    (r'\.(sql|py|docx|xlsx|json|bat)\b', 'omitir: nombre de archivo, salvo que sea un adjunto'),
    (r'\bcommit\b|\bgit\b|\brollback\b|\bdeploy\b', 'omitir: jerga de desarrollo'),
    (r'\bschema\b|\besquema\b\s+\w+\.', 'omitir: ruta de base de datos'),
]

# Identificadores de codigo: PALABRA_CON_GUION_BAJO o Tabla.Columna
IDENT = re.compile(r'\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\b')
PUNTO = re.compile(r'\b[A-Z][A-Za-z0-9]+\.[A-Z][A-Za-z0-9]+\b')

# Nombres que PARECEN identificadores de codigo pero son vocabulario de negocio:
# asi se llama el tablero y asi lo nombra el area. Dejarlos es correcto.
# Ampliar con --permitir Nombre1,Nombre2 cuando aparezca uno nuevo.
PERMITIDOS = {
    'gestion_cobranza',
    'meta_comercial',
    'flujo_caja',
}

# Al menos un verbo de accion: el ticket describe QUE SE HIZO.
ACCION = re.compile(
    r'\b(se\s+)?(cre[oó]|creaci[oó]n|ajust[eoó]|ajuste|modific[oó]|actualiz[oó]|'
    r'implement[oó]|automatiz[oó]|corrigi[oó]|correcci[oó]n|desarroll[oó]|'
    r'construy[oó]|configur[oó]|document[oó]|separ[oó]|unific[oó]|agreg[oó]|'
    r'elabor[oó]|entreg[oó])\b',
    re.I)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    permitidos = set(PERMITIDOS)
    if '--permitir' in sys.argv:
        extra = sys.argv[sys.argv.index('--permitir') + 1]
        permitidos |= {p.strip().lower() for p in extra.split(',') if p.strip()}
    txt = sys.stdin.read() if src == '-' else open(src, encoding='utf-8').read()

    palabras = re.findall(r"[\wÁÉÍÓÚÜÑáéíóúüñ'-]+", txt)
    n = len(palabras)
    fallos = []

    print('Palabras: %d / %d' % (n, LIMITE))
    if n > LIMITE:
        fallos.append('Se pasa por %d palabras. Recortar.' % (n - LIMITE))
    elif n < 35:
        fallos.append('Solo %d palabras: probablemente falta el "para que" o el impacto.' % n)

    hallazgos = []
    for pat, sug in TECNICO:
        for m in re.finditer(pat, txt, re.I):
            hallazgos.append((m.group(0), sug))
    for m in IDENT.finditer(txt):
        if m.group(0).lower() not in permitidos:
            hallazgos.append((m.group(0), 'identificador de codigo: describirlo en palabras'))
    for m in PUNTO.finditer(txt):
        if m.group(0).lower() not in permitidos:
            hallazgos.append((m.group(0), 'ruta de objeto: describirla en palabras'))

    if hallazgos:
        print('\nDetalle tecnico detectado:')
        vistos = set()
        for termino, sug in hallazgos:
            k = termino.lower()
            if k in vistos:
                continue
            vistos.add(k)
            print('  - "%s"  ->  %s' % (termino, sug))
        fallos.append('%d termino(s) tecnico(s) por reemplazar.' % len(vistos))

    if not ACCION.search(txt):
        fallos.append('No se detecta un verbo de accion (se creo / se ajusto / se corrigio...). '
                      'El ticket debe decir QUE SE HIZO.')

    if fallos:
        print('\nNO PASA:')
        for f in fallos:
            print('  * ' + f)
        sys.exit(1)

    print('\nOK: dentro del limite, sin jerga tecnica y con accion explicita.')


if __name__ == '__main__':
    main()
