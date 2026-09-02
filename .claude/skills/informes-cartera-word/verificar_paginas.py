"""Verifica el tope de paginas de un .docx y lo rasteriza para revision visual.

El conteo de paginas NO se puede estimar: solo Word sabe donde parte. Este script
lo abre por COM (via PowerShell, porque pywin32 no esta en el venv del repo),
repagina, reporta el numero real y exporta un PDF que luego rasteriza a PNG con
pymupdf para que se puedan mirar las paginas una por una.

    .venv/Scripts/python.exe .claude/skills/informes-cartera-word/verificar_paginas.py \
        Informe_Ejecutivo_Cierre_Agosto_2026.docx --max 3

Sale con codigo 1 si excede el tope, para que se note en un pipeline.

Por defecto deja los PNG (_preview_pN.png) y borra el PDF. Con --limpiar borra
todo: usarlo al terminar, porque esos archivos NO se comitean.
"""
import argparse
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# Abre en solo lectura y siempre cierra sin guardar. Aun asi Word deja el .docx
# "modificado" para git si otra instancia lo tiene abierto: ver el SKILL.md.
PS = r"""
$ErrorActionPreference = 'Stop'
$w = New-Object -ComObject Word.Application
$w.Visible = $false
try {{
    $d = $w.Documents.Open('{docx}', $false, $true)
    $d.Repaginate()
    'PAGINAS=' + $d.ComputeStatistics(2)
    $d.SaveAs2('{pdf}', 17)
    $d.Close($false)
}} finally {{
    $w.Quit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($w)
}}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("docx")
    ap.add_argument("--max", type=int, default=None,
                    help="tope de paginas; sale con codigo 1 si se excede")
    ap.add_argument("--dpi", type=int, default=105)
    ap.add_argument("--prefijo", default="_preview_p")
    ap.add_argument("--limpiar", action="store_true",
                    help="borra los PNG y el PDF y no rasteriza")
    a = ap.parse_args()

    docx = os.path.abspath(a.docx)
    if not os.path.exists(docx):
        sys.exit(f"No existe: {docx}")
    pdf = os.path.splitext(docx)[0] + "_preview.pdf"

    if a.limpiar:
        borrados = 0
        for f in os.listdir(os.path.dirname(docx) or "."):
            if f.startswith(a.prefijo) and f.endswith(".png"):
                os.remove(f)
                borrados += 1
        if os.path.exists(pdf):
            os.remove(pdf)
            borrados += 1
        print(f"Limpiados {borrados} archivos de preview.")
        return

    salida = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command",
         PS.format(docx=docx, pdf=pdf)],
        capture_output=True, text=True)
    if salida.returncode != 0:
        sys.exit(f"Word fallo:\n{salida.stderr.strip()}")

    m = re.search(r"PAGINAS=(\d+)", salida.stdout)
    if not m:
        sys.exit(f"No se pudo leer el conteo:\n{salida.stdout}\n{salida.stderr}")
    paginas = int(m.group(1))

    try:
        import pymupdf
    except ImportError:
        sys.exit("Falta pymupdf en el venv:  .venv/Scripts/python.exe -m pip install pymupdf")

    doc = pymupdf.open(pdf)
    pngs = []
    for i, page in enumerate(doc):
        ruta = f"{a.prefijo}{i + 1}.png"
        page.get_pixmap(dpi=a.dpi).save(ruta)
        pngs.append(ruta)
    doc.close()
    os.remove(pdf)

    print(f"PAGINAS: {paginas}" + (f"   (tope {a.max})" if a.max else ""))
    print("Rasterizado: " + ", ".join(pngs))
    print("Revisar cada PNG antes de entregar: el conteo no detecta tablas "
          "cortadas ni titulos huerfanos.")

    if a.max is not None and paginas > a.max:
        print(f"\nEXCEDE EL TOPE por {paginas - a.max} pagina(s). "
              "Recortar contenido, no reducir la fuente.")
        sys.exit(1)


if __name__ == "__main__":
    main()
