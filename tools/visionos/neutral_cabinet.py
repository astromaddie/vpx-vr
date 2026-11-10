#!/usr/bin/env python3
"""Bundle the neutral VR cabinet for the visionOS player and write its fit check data.

The cabinet comes from https://github.com/astromaddie/vpx-cabinet (the add-cabinet
tool). Its assets/ folder holds canonical OBJ meshes in VPX units (x right, y toward
the player, z up from the floor, VPX tv and winding), three JPEG textures and the fit
specification. The player loads GLB meshes the same way as the stock cabinet, so:

  pack    converts the meshes to GLB (MeshGLTF.cpp's convention: metres, (x, z, y),
          flipped V, reversed winding), reads every file back the way MeshGLTF.cpp does
          and checks it against the OBJ, measures the control anchors and display
          regions into controls.json, and copies the spec, textures and credits.
  golden  runs the tool's own Python fit, glass and variant rules on a set of cases
          and writes the results for apps/visionos/Checks/CabinetFitChecks.cpp.

  python3 tools/visionos/neutral_cabinet.py pack --cabinet-repo ~/code/vpx-cabinet
  python3 tools/visionos/neutral_cabinet.py golden --cabinet-repo ~/code/vpx-cabinet \
      > apps/visionos/Checks/CabinetFitGolden.json
"""

import argparse
import json
import math
import os
import shutil
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PACK = os.path.join(ROOT, "src", "assets", "neutralCabinet")
VPU_TO_M = 0.0254 * 1.0625 / 50.0


def load_tool(repo):
    sys.path.insert(0, os.path.abspath(repo))
    from add_cabinet import mesh as M  # noqa: E402
    from add_cabinet import build as B  # noqa: E402
    from add_cabinet import fit as F  # noqa: E402
    from add_cabinet import glass as G  # noqa: E402
    return M, B, F, G


# --------------------------------------------------------------------------
# GLB


def write_glb(path, mesh):
    pos, nrm, uv = bytearray(), bytearray(), bytearray()
    lo, hi = [math.inf] * 3, [-math.inf] * 3
    for (x, y, z), (nx, ny, nz), (tu, tv) in zip(mesh.v, mesh.n, mesh.t):
        p = (x * VPU_TO_M, z * VPU_TO_M, y * VPU_TO_M)
        p = struct.unpack("<3f", struct.pack("<3f", *p))
        lo = [min(a, b) for a, b in zip(lo, p)]
        hi = [max(a, b) for a, b in zip(hi, p)]
        pos += struct.pack("<3f", *p)
        nrm += struct.pack("<3f", nx, nz, ny)
        uv += struct.pack("<2f", tu, 1.0 - tv)
    idx = bytearray()
    for a, b, c in mesh.f:
        idx += struct.pack("<3I", a, c, b)
    blobs = [pos, nrm, uv, idx]
    views, offset = [], 0
    for blob in blobs:
        views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(blob)})
        offset += len(blob)
    n = len(mesh.v)
    doc = {
        "asset": {"version": "2.0", "generator": "vpx neutral_cabinet.py"},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "mode": 4}]}],
        "buffers": [{"byteLength": offset}],
        "bufferViews": views,
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3", "min": lo, "max": hi},
            {"bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": n, "type": "VEC2"},
            {"bufferView": 3, "componentType": 5125, "count": len(mesh.f) * 3, "type": "SCALAR"},
        ],
    }
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    bin_ = b"".join(blobs)
    bin_ += b"\0" * (-len(bin_) % 4)
    total = 12 + 8 + len(js) + 8 + len(bin_)
    with open(path, "wb") as fh:
        fh.write(struct.pack("<4sII", b"glTF", 2, total))
        fh.write(struct.pack("<I4s", len(js), b"JSON") + js)
        fh.write(struct.pack("<I4s", len(bin_), b"BIN\0") + bin_)


def read_glb_like_vpx(path):
    """Decode the way MeshGLTF.cpp's LoadGLB does: back to VPX vertices and winding."""
    data = open(path, "rb").read()
    magic, _, total = struct.unpack_from("<4sII", data, 0)
    assert magic == b"glTF" and total == len(data)
    jlen, = struct.unpack_from("<I", data, 12)
    doc = json.loads(data[20:20 + jlen])
    blen, = struct.unpack_from("<I", data, 20 + jlen)
    bin_ = data[28 + jlen:28 + jlen + blen]

    def acc(i, fmt, width):
        a = doc["accessors"][i]
        v = doc["bufferViews"][a["bufferView"]]
        raw = bin_[v["byteOffset"]:v["byteOffset"] + v["byteLength"]]
        flat = struct.unpack("<%d%s" % (a["count"] * width, fmt), raw)
        return [flat[k:k + width] for k in range(0, len(flat), width)]

    prim = doc["meshes"][0]["primitives"][0]
    m = 1.0 / VPU_TO_M
    v = [(x * m, z * m, y * m) for x, y, z in acc(prim["attributes"]["POSITION"], "f", 3)]
    n = [(x, z, y) for x, y, z in acc(prim["attributes"]["NORMAL"], "f", 3)]
    t = [(u, 1.0 - w) for u, w in acc(prim["attributes"]["TEXCOORD_0"], "f", 2)]
    ind = [i[0] for i in acc(prim["indices"], "I", 1)]
    f = [(ind[k], ind[k + 2], ind[k + 1]) for k in range(0, len(ind), 3)]
    return v, n, t, f


# --------------------------------------------------------------------------
# control anchors, measured from the canonical meshes


def bounds(points):
    lo = [min(p[i] for p in points) for i in range(3)]
    hi = [max(p[i] for p in points) for i in range(3)]
    return lo, hi


def measure_controls(M, assets):
    def verts(name):
        return M.read_obj(os.path.join(assets, "meshes", name + ".obj")).v

    def front_face(name, depth):
        """The front-most surface (largest y) of a part, as a centre and x/z half extents."""
        v = verts(name)
        top = max(p[1] for p in v)
        lo, hi = bounds([p for p in v if p[1] >= top - depth])
        return {"part": name, "point": [(lo[0] + hi[0]) / 2, top, (lo[2] + hi[2]) / 2],
                "half": [(hi[0] - lo[0]) / 2, (hi[2] - lo[2]) / 2]}

    def flipper(side):
        v = [p for p in verts("FlipperButtons") if (p[0] - 500.0) * side > 0]
        lo, hi = bounds(v)
        return {"part": "FlipperButtons", "point": [lo[0] if side < 0 else hi[0], (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2]}

    coin = verts("CoinInserts")
    clo, chi = bounds(coin)
    # The plunger knob is the front 28.6 VPU of the rod assembly.
    knob_v = verts("Plunger")
    kfront = max(p[1] for p in knob_v)
    klo, khi = bounds([p for p in knob_v if p[1] > kfront - 28.6])

    # Translite: the front quad and its UV layout (tools/build_assets.py translite_texture:
    # 1024 x 818, smoked glass above a 20.5% speaker panel with a 24% wide display window).
    tm = M.read_obj(os.path.join(assets, "meshes", "Translite.obj"))
    front = [i for i, n in enumerate(tm.n) if n[1] > 0.9]  # the quad facing the player
    xs = [tm.v[i][0] for i in front]
    zs = [tm.v[i][2] for i in front]
    us = [tm.t[i][0] for i in front]
    x0, x1, z0, z1 = min(xs), max(xs), min(zs), max(zs)
    u0, u1 = min(us), max(us)
    y_top = max(tm.v[i][1] for i in front if tm.v[i][2] > (z0 + z1) / 2)
    y_bottom = max(tm.v[i][1] for i in front if tm.v[i][2] < (z0 + z1) / 2)

    def x_at(u):
        return x0 + (u - u0) / (u1 - u0) * (x1 - x0)

    def z_at(v):
        return z1 - v * (z1 - z0)

    w, h = 1024, 818
    th = int(h * (1 - 0.205))
    ph = h - th
    pad = int(ph * 0.14)
    disp_w = int(w * 0.24)
    dx0 = (w - disp_w) // 2
    return {
        "frame": "VPX units in the canonical cabinet frame, before fitting. 'part' is the mesh whose fit moves the anchor.",
        "start": front_face("StartButton", 6.0),
        "coin": {"part": "CoinInserts", "point": [(clo[0] + chi[0]) / 2, (clo[1] + chi[1]) / 2, (clo[2] + chi[2]) / 2],
                 "half": [(chi[0] - clo[0]) / 2, (chi[2] - clo[2]) / 2]},
        "leftFlipper": flipper(-1),
        "rightFlipper": flipper(1),
        "plunger": {"part": "Plunger", "point": [(klo[0] + khi[0]) / 2, (klo[1] + khi[1]) / 2, (klo[2] + khi[2]) / 2]},
        "launch": front_face("LaunchButton", 3.0),
        "translite": {"part": "Translite", "front_y_top": y_top, "front_y_bottom": y_bottom,
                      "glass": {"x": [x0, x1], "z": [z_at(th / h), z1]},
                      "window": {"x": [x_at(dx0 / w), x_at((dx0 + disp_w) / w)],
                                 "z": [z_at((th + ph - pad) / h), z_at((th + pad) / h)]}},
    }


def pack(args):
    M, B, F, G = load_tool(args.cabinet_repo)
    assets = os.path.join(args.cabinet_repo, "assets")
    if os.path.isdir(PACK):
        shutil.rmtree(PACK)
    os.makedirs(os.path.join(PACK, "meshes"))
    os.makedirs(os.path.join(PACK, "textures"))
    spec = json.load(open(os.path.join(assets, "cabinet.json")))
    worst = 0.0
    for p in spec["parts"]:
        mesh = M.read_obj(os.path.join(assets, "meshes", p["mesh"] + ".obj"))
        assert len(mesh.v) == len(mesh.t) == len(mesh.n), p["mesh"]
        out = os.path.join(PACK, "meshes", p["mesh"] + ".glb")
        write_glb(out, mesh)
        v, n, t, f = read_glb_like_vpx(out)
        assert f == mesh.f, p["mesh"] + ": winding or indices changed"
        for a, b in zip(v, mesh.v):
            worst = max(worst, max(abs(x - y) for x, y in zip(a, b)))
        for a, b in zip(n + t, mesh.n + mesh.t):
            assert all(abs(x - y) < 1e-6 for x, y in zip(a, b)), p["mesh"] + ": normal or UV changed"
    assert worst < 0.01, f"GLB positions moved by {worst} VPU"
    for name in ("cabinet.json", "reference.json"):
        shutil.copyfile(os.path.join(assets, name), os.path.join(PACK, name))
    for fn in spec["images"].values():
        shutil.copyfile(os.path.join(assets, "textures", fn), os.path.join(PACK, "textures", fn))
    shutil.copyfile(os.path.join(args.cabinet_repo, "CREDITS.md"), os.path.join(PACK, "CREDITS.md"))
    with open(os.path.join(PACK, "controls.json"), "w") as fh:
        json.dump(measure_controls(M, assets), fh, indent=1)
        fh.write("\n")
    print(f"wrote {PACK}: {len(spec['parts'])} meshes, largest GLB round-trip error {worst:.5f} VPU")


# --------------------------------------------------------------------------
# golden data for the C++ fit check


def golden(args):
    M, B, F, G = load_tool(args.cabinet_repo)
    spec, ref = B.load_assets()
    meshes = {p["mesh"]: M.read_obj(os.path.join(B.ASSETS, "meshes", p["mesh"] + ".obj")) for p in spec["parts"]}

    probe = [(x, y, z) for x in (-200.0, -37.0, 140.0, 500.0, 1031.0, 1300.0)
             for y in (-500.0, 4.0, 1000.0, 2086.0, 2300.0)
             for z in (0.0, 600.0, 1059.0, 1400.0, 1700.0, 1848.0, 3400.0)]

    def fit_case(name, table, clamp=False):
        case = {"name": name, "table": {"left": table.left, "top": table.top, "right": table.right, "bottom": table.bottom,
                                         "glass_top": table.glass_top, "glass_bottom": table.glass_bottom,
                                         "slope": table.slope, "ground_to_lockbar": table.ground_to_lockbar,
                                         "plunger_x": table.plunger_x},
                "clamp_glass": clamp}
        try:
            fit = F.Fit(ref, spec, table, clamp_glass=clamp)
        except ValueError as e:
            case["error"] = str(e)
            return case
        case["values"] = {"sx_left": fit.sx["left"], "sx_centre": fit.sx["centre"], "sx_right": fit.sx["right"],
                          "sy_front": fit.sy["front"], "sy_back": fit.sy["back"], "yf": fit.yf, "yb": fit.yb,
                          "glass_eff": fit.glass_eff, "pf_front_z": fit.pf_front_z, "lockbar_z": fit.lockbar_z,
                          "dz": fit.dz, "rail_slope": fit.rail_slope, "plunger_x": fit.plunger_x,
                          "warnings": len(fit.warnings)}
        case["body"] = [fit.map_body(p) for p in probe]
        case["head"] = [fit.map_head(p) for p in probe]
        case["legs"] = [fit.map_leg(p) for p in probe]
        case["walls"] = [c for _, c, _ in fit.inner_walls()]
        case["parts"] = {}
        for variant in ("plunger", "launch-button"):
            for pname, _, _, _, mesh in B.fitted_parts(fit, spec, variant):
                lo, hi = mesh.bounds()
                case["parts"][pname] = {"lo": lo, "hi": hi, "triangles": mesh.triangles}
        case["rigid"] = {p["name"]: fit.rigid_offset(meshes[p["mesh"]].centre(), p["anchor"])
                         for p in spec["parts"] if p["deform"] == "rigid"}
        return case

    T = F.Table
    cases = []
    for w, l, g, s, px in ((1000.0, 1910.0, 250.0, 5.5, None), (1269.0, 1910.0, 250.0, 5.5, None),
                           (900.0, 1700.0, 250.0, 5.5, None), (952.0, 1927.0, 150.0, 5.0, 903.7),
                           (952.0, 1927.0, 250.0, 5.5, 200.0), (1269.0, 2400.0, 250.0, 5.5, None),
                           (1000.0, 2350.0, 250.0, 4.0, None), (1000.0, 2350.0, 250.0, 7.5, None),
                           (1000.0, 2200.0, 148.0, 4.0, None), (1000.0, 2200.0, 100.0, 7.0, None),
                           (1000.0, 2350.0, 148.0, 7.0, None), (1000.0, 1910.0, 300.0, 5.5, None),
                           (1000.0, 1910.0, 600.0, 5.5, None), (700.0, 1910.0, 250.0, 5.5, None),
                           (1000.0, 900.0, 250.0, 5.5, None), (1000.0, 1910.0, 1600.0, 5.5, None)):
        cases.append(fit_case(f"{w:g}x{l:g} glass {g:g} slope {s:g}", T(0.0, 0.0, w, l, g, None, s, s, 0.5, plunger_x=px, version=1060)))
    cases.append(fit_case("clamped 600", T(0.0, 0.0, 1000.0, 1910.0, 600.0, None, 5.5, 5.5, 0.5, version=1060), clamp=True))
    cases.append(fit_case("10.8 sloped glass", T(0.0, 0.0, 1000.0, 2000.0, 400.0, 150.0, 6.0, 6.0, 0.5, version=1080)))
    cases.append(fit_case("offset bounds", T(20.0, 10.0, 1020.0, 1930.0, 250.0, None, 5.5, 5.5, 0.5, version=1060)))
    cases.append(fit_case("custom lockbar", T(0.0, 0.0, 1000.0, 1910.0, 250.0, None, 5.5, 5.5, 0.5, ground_to_lockbar=1800.0, version=1060)))
    # The real tables the tool was run on (bounds, glass after its glass rule, slope, plunger x).
    for name, w, l, g, s, px in (("Attack from Mars", 1024.0, 2350.0, 299.0, 6.56, None),
                                  ("Black Hole", 1116.0, 2186.0, 598.0, 4.0, 1067.3),
                                  ("Bride of Pinbot", 952.0, 2127.0, 259.0, 6.2, 898.9),
                                  ("Middle Earth", 1269.0, 2115.0, 156.0, 5.0, 1205.0)):
        cases.append(fit_case(name, T(0.0, 0.0, w, l, g, None, s, s, 0.5, plunger_x=px, version=1060)))

    variants = []
    for plungers in ([], [{"name": "AutoPlunger", "auto_plunger": True}],
                     [{"name": "P", "auto_plunger": False, "is_visible": False}],
                     [{"name": "Plunger", "auto_plunger": False, "is_visible": True}, {"name": "Kick", "auto_plunger": True}],
                     [{"name": "Kick", "auto_plunger": True}, {"name": "Hidden", "auto_plunger": False, "is_visible": False},
                      {"name": "Shooter", "auto_plunger": False, "is_visible": True}]):
        variants.append({"plungers": plungers, "variant": F.choose_variant(plungers)[0]})

    class GT:
        def __init__(self, version, items, glass_top=300.0, glass_bottom=None, size=(1000.0, 2000.0)):
            self.version = version
            self.root = "/nonexistent"
            self.gamedata = {"left": 0.0, "top": 0.0, "right": size[0], "bottom": size[1],
                             "glass_top_height": glass_top, "glass_bottom_height": glass_bottom}
            self.items = [(k, b, {"file_name": f"{k}.{b['name']}.json"}) for k, b in items]

    square = [{"x": 0, "y": 0}, {"x": 1000, "y": 0}, {"x": 1000, "y": 2000}, {"x": 0, "y": 2000}]
    small = [{"x": 0, "y": 0}, {"x": 300, "y": 0}, {"x": 300, "y": 300}, {"x": 0, "y": 300}]
    glass_inputs = [
        ("legacy empty", GT(1060, [])),
        ("legacy ramp", GT(1060, [("Ramp", {"name": "Hab", "height_top": 120.0, "height_bottom": 0.0, "is_collidable": True})])),
        ("non-collidable ramp", GT(1060, [("Ramp", {"name": "Deco", "height_top": 220.0, "height_bottom": 10.0, "is_collidable": False})])),
        ("referenced non-collidable ramp", GT(1060, [("Ramp", {"name": "Deco", "height_top": 220.0, "height_bottom": 10.0, "is_collidable": False}),
                                                     ("Trigger", {"name": "T1", "surface": "deco"})])),
        ("raised playfield", GT(1030, [("Wall", {"name": "UpperPF", "height_top": 450.0, "drag_points": square}),
                                       ("Kicker", {"name": "K1", "surface": "UpperPF"})], glass_top=600.0)),
        ("small raised wall", GT(1060, [("Wall", {"name": "Island", "height_top": 90.0, "drag_points": small}),
                                        ("Bumper", {"name": "B1", "surface": "Island"})])),
        ("unreferenced wall", GT(1060, [("Wall", {"name": "Upper", "height_top": 450.0, "drag_points": square})])),
        ("10.8 lower", GT(1080, [], glass_top=400.0, glass_bottom=300.0)),
        ("10.8 raise top", GT(1080, [], glass_top=100.0, glass_bottom=100.0)),
        ("tie on name", GT(1060, [("Ramp", {"name": "A", "height_top": 150.0, "height_bottom": 0.0}),
                                  ("Ramp", {"name": "B", "height_top": 150.0, "height_bottom": 0.0})])),
        ("half round", GT(1060, [("Ramp", {"name": "R", "height_top": 73.5, "height_bottom": 0.0})])),
    ]
    glass = []
    for label, gt in glass_inputs:
        out = G.choose(gt, 8.0)
        items = [{"kind": k, **{key: val for key, val in b.items()}} for k, b, _ in gt.items]
        glass.append({"name": label, "version": gt.version, "glass_top": gt.gamedata["glass_top_height"],
                      "glass_bottom": gt.gamedata["glass_bottom_height"], "size": [gt.gamedata["right"], gt.gamedata["bottom"]],
                      "items": items, "new": out["new"], "fields": out["fields"], "limited_by": out["limited_by"],
                      "main_surface": out["main_surface"]})

    def rounded(o):
        if isinstance(o, float):
            return float(f"{o:.9g}")
        if isinstance(o, (list, tuple)):
            return [rounded(x) for x in o]
        if isinstance(o, dict):
            return {k: rounded(v) for k, v in o.items()}
        return o

    json.dump(rounded({"probe": probe, "fits": cases, "variants": variants, "glass": glass}),
              sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("pack", "golden"))
    ap.add_argument("--cabinet-repo", required=True, help="checkout of the vpx-cabinet repository")
    args = ap.parse_args()
    pack(args) if args.command == "pack" else golden(args)


if __name__ == "__main__":
    main()
