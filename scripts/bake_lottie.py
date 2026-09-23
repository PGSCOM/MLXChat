"""Bake a dotLottie's slots and themes into plain Lottie JSON for lottie-ios.

lottie-ios has no slot/theme support: it draws each property's inline value,
and a Lottie Creator export leaves those stale (a gradient slot's inline
fallback keeps an old stop count, so lottie-ios reads leftover colour values
as opacity stops). This writes one JSON per appearance with every slot
resolved and no `slots`/`sid` left, so any renderer draws what the official
dotlottie player draws:

    <prefix>Oscuro.json      the file's defaults (no theme)
    <prefix><Theme>.json     one per theme in the manifest

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
    out = f"{prefix}{theme_id or 'Oscuro'}.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(anim, f, separators=(",", ":"), ensure_ascii=False)
    print(f"{out}: {len(used)} slots baked")


bake()
for theme in manifest.get("themes", []):
    bake(theme["id"])
