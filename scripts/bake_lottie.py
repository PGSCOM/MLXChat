"""Bake a dotLottie's slots and themes into plain Lottie JSON for lottie-ios.

lottie-ios has no slot/theme support: it draws each property's inline value,
and a Lottie Creator export leaves those stale (a gradient slot's inline
fallback keeps an old stop count, so lottie-ios reads leftover colour values
as opacity stops). This writes one JSON per appearance with every slot
resolved and no `slots`/`sid` left, so any renderer draws what the official
dotlottie player draws:

    <prefix>Oscuro.json      the file's defaults (no theme)
    <prefix><Theme>.json     one per theme in the manifest

It also removes two things lottie-ios draws with Core Graphics that no other
renderer shows (see `core_graphics_safe`); both are invisible changes
everywhere else.

usage: python3 scripts/bake_lottie.py <file.lottie | URL> <out prefix>
e.g.:  python3 scripts/bake_lottie.py \
         https://lottie.host/97b6ca36-2b48-457e-9ca5-133d03666c7a/ZBPxnS6sko.lottie \
         Faro/App/Resources/NuevaConversacion
"""
import io
import json
import sys
import urllib.request
import zipfile

src, prefix = sys.argv[1:3]
raw = urllib.request.urlopen(src).read() if src.startswith("http") else open(src, "rb").read()
bundle = zipfile.ZipFile(io.BytesIO(raw))
manifest = json.loads(bundle.read("manifest.json"))
source = json.loads(bundle.read(f"a/{manifest['initial']['animation']}.json"))


def theme_values(theme_id):
    """A theme's rules, in the same shape as a slot's `p` value."""
    values = {}
    for rule in json.loads(bundle.read(f"t/{theme_id}.json"))["rules"]:
        v = rule["value"]
        if rule["type"] in ("Color", "Scalar"):
            values[rule["id"]] = {"a": 0, "k": v}
        elif rule["type"] == "Gradient":
            stops = [x for s in v for x in (s["offset"], *s["color"][:3])]
            if any(s["color"][3:4] not in ([], [1]) for s in v):
                stops += [x for s in v for x in (s["offset"], s["color"][3])]
            values[rule["id"]] = {"p": len(v), "k": {"a": 0, "k": stops}}
        else:
            sys.exit(f"unsupported theme rule type {rule['type']!r} in {theme_id}")
    return values


def core_graphics_safe(shapes):
    """Fix what lottie-ios' main-thread engine (Core Graphics) draws wrong:
    - a 0-width stroke is a hairline to Core Graphics, not nothing;
    - subpaths sharing one fill but winding in opposite directions leave a
      see-through seam along their inner edges (the nonzero coverage sums to
      0 there), so every subpath under a fill is made to wind the same way.
    """
    shapes[:] = [s for s in shapes if not (s["ty"] in ("st", "gs") and s["w"]["a"] == 0 and s["w"]["k"] == 0)]
    for i, item in enumerate(shapes):
        if item["ty"] == "gr":
            core_graphics_safe(item["it"])
        elif item["ty"] in ("fl", "gf"):
            filled = list(paths_under(shapes[:i], 1))
            if len({sign for _, sign in filled} - {0}) > 1:
                assert not has_trim(shapes[:i]), "reversing a trimmed path would change the trim"
                majority = 1 if sum(sign for _, sign in filled) >= 0 else -1
                for path, sign in filled:
                    if sign == -majority:
                        reverse(path)


def has_trim(items):
    return any(s["ty"] == "tm" or s["ty"] == "gr" and has_trim(s["it"]) for s in items)


def paths_under(items, parent_sign):
    """Every path a fill after `items` paints, with its winding (+1/-1, 0 for no area)."""
    for item in items:
        if item["ty"] in ("sh", "el", "rc"):
            yield item, parent_sign * winding(item)
        elif item["ty"] == "gr":
            scale = next(s for s in item["it"] if s["ty"] == "tr")["s"]
            sx, sy = (scale["k"] if scale["a"] == 0 else scale["k"][0]["s"])[:2]
            yield from paths_under(item["it"], parent_sign * (1 if sx * sy > 0 else -1))


def shape_values(path):
    """The bezier(s) of a `sh` item: its static value or every keyframe's."""
    ks = path["ks"]
    return [ks["k"]] if ks["a"] == 0 else [kf[key][0] for kf in ks["k"] for key in ("s", "e") if key in kf]


def winding(path):
    if path["ty"] != "sh":
        return -1 if path.get("d") == 3 else 1  # ellipse/rect: d=1 is clockwise
    signs = set()
    for shape in shape_values(path):
        v = shape["v"]
        area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(v, v[1:] + v[:1]))
        signs.add(0 if abs(area) < 1e-6 else 1 if area > 0 else -1)
    signs.discard(0)
    assert len(signs) <= 1, f"{path.get('nm')} changes winding while it animates"
    return signs.pop() if signs else 0


def reverse(path):
    if path["ty"] != "sh":
        path["d"] = 1 if path.get("d") == 3 else 3
        return
    for shape in shape_values(path):
        # Same start vertex, opposite direction: each in-tangent becomes an out-tangent.
        order = [0, *range(len(shape["v"]) - 1, 0, -1)]
        shape["v"], shape["i"], shape["o"] = ([shape[key][j] for j in order] for key in ("v", "o", "i"))


def bake(theme_id=None):
    anim = json.loads(json.dumps(source))
    values = {sid: slot["p"] for sid, slot in anim.pop("slots", {}).items()}
    if theme_id:
        values |= theme_values(theme_id)
    used = set()

    def walk(node):
        items = node.values() if isinstance(node, dict) else node if isinstance(node, list) else ()
        for prop in items:
            if not isinstance(prop, dict):
                walk(prop)
                continue
            gradient = isinstance(prop.get("k"), dict) and "sid" in prop["k"]
            # A gradient slot replaces the whole gradient (stop count + stops),
            # any other slot the animated property holding the `sid`.
            target = prop["k"] if gradient else prop
            if "sid" in target:
                sid = target.pop("sid")
                ix = target.get("ix")
                new = values[sid]
                if gradient:
                    prop["p"] = new["p"]
                    prop["k"] = target = dict(new["k"])
                else:
                    prop.clear()
                    prop.update(new)
                    target = prop
                if ix is not None:
                    target["ix"] = ix
                used.add(sid)
            walk(prop)

    walk(anim)
    assert used == set(values), f"never applied: {set(values) - used}"
    assert '"sid"' not in json.dumps(anim), "a slot reference survived"
    for layer in [*anim["layers"], *(l for a in anim["assets"] for l in a.get("layers", []))]:
        if layer["ty"] == 4:
            core_graphics_safe(layer["shapes"])
    out = f"{prefix}{theme_id or 'Oscuro'}.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(anim, f, separators=(",", ":"), ensure_ascii=False)
    print(f"{out}: {len(used)} slots baked")


bake()
for theme in manifest.get("themes", []):
    bake(theme["id"])
