#!/usr/bin/env python3
"""Generates the sample 3MF bundled with the model viewer.

  app/assets/model3d/sample.3mf

A little 3D-printed cup in two parts ("底座" base + "杯身" cup), each carrying
its own base-material colour, so the viewer exercises the parts of the 3MF core
spec a print-oriented viewer actually meets: multiple objects, basematerials,
colour groups, millimetre units, Z-up. Regenerate after editing this script:

  python3 app/tool/make_sample_3mf.py
"""
from __future__ import annotations

import math
import zipfile
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "model3d" / "sample.3mf"


def cylinder(*, r_bottom: float, r_top: float, h: float, z0: float = 0.0, seg: int = 48):
    """A capped cylinder (a truncated cone when r_top != r_bottom), Z-up."""
    verts: list[tuple[float, float, float]] = []
    tris: list[tuple[int, int, int]] = []

    for i in range(seg):
        a = 2 * math.pi * i / seg
        verts.append((r_bottom * math.cos(a), r_bottom * math.sin(a), z0))
    top_ring = len(verts)
    for i in range(seg):
        a = 2 * math.pi * i / seg
        verts.append((r_top * math.cos(a), r_top * math.sin(a), z0 + h))
    cap_bottom = len(verts)
    verts.append((0.0, 0.0, z0))
    cap_top = len(verts)
    verts.append((0.0, 0.0, z0 + h))

    for i in range(seg):
        j = (i + 1) % seg
        b_i, b_j = i, j
        t_i, t_j = top_ring + i, top_ring + j
        # Side, outward-facing (the ring runs counter-clockwise seen from +Z).
        tris.append((b_i, b_j, t_j))
        tris.append((b_i, t_j, t_i))
        # Caps.
        tris.append((cap_bottom, b_j, b_i))  # bottom, faces -Z
        tris.append((cap_top, t_i, t_j))  # top, faces +Z
    return verts, tris


def mesh_xml(verts, tris) -> str:
    v = "\n".join(
        f'<vertex x="{x:.4f}" y="{y:.4f}" z="{z:.4f}" />' for x, y, z in verts
    )
    t = "\n".join(f'<triangle v1="{a}" v2="{b}" v3="{c}" />' for a, b, c in tris)
    return f"<mesh>\n<vertices>\n{v}\n</vertices>\n<triangles>\n{t}\n</triangles>\n</mesh>"


def main() -> None:
    base_verts, base_tris = cylinder(r_bottom=26, r_top=24, h=10, z0=0)
    cup_verts, cup_tris = cylinder(r_bottom=24, r_top=21, h=34, z0=10)

    content_types = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml" />'
        '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml" />'
        "</Types>\n"
    )
    rels = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rel0" '
        'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel" '
        'Target="/3D/3dmodel.model" />'
        "</Relationships>\n"
    )
    model = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<model unit="millimeter" xml:lang="en-US" '
        'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\n'
        " <resources>\n"
        '  <basematerials id="2">\n'
        '   <base name="陶红" displaycolor="#C4453CFF" />\n'
        '   <base name="釉蓝" displaycolor="#3C6EC4FF" />\n'
        "  </basematerials>\n"
        '  <object id="1" name="底座" type="model" pid="2" pindex="0">\n'
        f"{mesh_xml(base_verts, base_tris)}\n"
        "  </object>\n"
        '  <object id="2" name="杯身" type="model" pid="2" pindex="1">\n'
        f"{mesh_xml(cup_verts, cup_tris)}\n"
        "  </object>\n"
        " </resources>\n"
        " <build>\n"
        '  <item objectid="1" />\n'
        '  <item objectid="2" />\n'
        " </build>\n"
        "</model>\n"
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", content_types)
        z.writestr("_rels/.rels", rels)
        z.writestr("3D/3dmodel.model", model)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
