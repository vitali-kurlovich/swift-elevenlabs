"""Convert ElevenLabs openapi.json to YAML, plus an audio-only subset."""
import json, sys, re, yaml

src, full_out, audio_out = sys.argv[1:4]
spec = json.load(open(src))

class Dumper(yaml.SafeDumper):
    pass
# keep multi-line descriptions readable
def str_rep(d, s):
    style = "|" if "\n" in s else None
    return d.represent_scalar("tag:yaml.org,2002:str", s, style=style)
Dumper.add_representer(str, str_rep)

def dump(obj, path):
    with open(path, "w") as f:
        yaml.dump(obj, f, Dumper=Dumper, sort_keys=False, allow_unicode=True, width=120)

dump(spec, full_out)

AUDIO_PREFIXES = (
    "/v1/text-to-speech/", "/v1/text-to-dialogue", "/v1/speech-to-text",
    "/v1/voice-changer/", "/v1/sound-generation", "/v1/audio-isolation",
    "/v1/forced-alignment", "/v1/music", "/v1/models", "/v1/voices",
    "/v2/voices", "/v1/history", "/v1/user", "/v1/single-use-token/",
)
paths = {p: v for p, v in spec["paths"].items() if p.startswith(AUDIO_PREFIXES)}

# collect transitively referenced components
comps = spec.get("components", {})
needed = {}  # (section, name)
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "$ref" and isinstance(v, str):
                m = re.match(r"#/components/([^/]+)/(.+)", v)
                if m and m.groups() not in needed:
                    sec, name = m.groups()
                    needed[(sec, name)] = True
                    walk(comps[sec][name])
            else:
                walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(paths)

# swift-openapi-generator can't encode multipart fields typed `string | [string] | null`.
# Collapse them to `[string]`: ["all"] sends the same form part as "all".
def resolve(s):
    while "$ref" in s:
        s = comps["schemas"][s["$ref"].split("/")[-1]]
    return s
for ops in paths.values():
    for op in ops.values():
        if not isinstance(op, dict):
            continue
        body = op.get("requestBody", {}).get("content", {}).get("multipart/form-data")
        if not body:
            continue
        # Without an explicit encoding, binary parts are sent as text/plain.
        for name, prop in resolve(body["schema"]).get("properties", {}).items():
            if "binary" in json.dumps(prop):
                body.setdefault("encoding", {}).setdefault(name, {"contentType": "application/octet-stream"})
        for prop in resolve(body["schema"]).get("properties", {}).values():
            # It also requires multipart array fields to be inline, not behind a $ref.
            if "$ref" in prop and resolve(prop).get("type") == "array":
                target = resolve(prop)
                del prop["$ref"]
                prop.update({k: v for k, v in target.items() if k not in prop})
            variants = prop.get("anyOf", [])
            arrays = [v for v in variants if v.get("type") == "array"]
            types = {v.get("type") for v in variants}
            if arrays and types - {"array", "null"}:
                del prop["anyOf"]
                prop.update(arrays[0])
            # `object | string` parts fail to compile; send them as a JSON-encoded string.
            elif {"object", "string"} <= types:
                del prop["anyOf"]
                prop["type"] = "string"

# The generator silently drops `X | null` (anyOf with null) properties and params.
# Strip the null variant and make such properties optional: Swift optionals decode null.
def strip_null(o):
    if isinstance(o, list):
        for v in o:
            strip_null(v)
        return
    if not isinstance(o, dict):
        return
    for v in o.values():
        strip_null(v)
    nullable = set()
    for name, prop in o.get("properties", {}).items():
        if isinstance(prop, dict) and any(v.get("type") == "null" for v in prop.get("anyOf", [])):
            nullable.add(name)
    if nullable and isinstance(o.get("required"), list):
        o["required"] = [r for r in o["required"] if r not in nullable] or None
        if o["required"] is None:
            del o["required"]
    variants = o.get("anyOf")
    if isinstance(variants, list) and any(v.get("type") == "null" for v in variants):
        rest = [v for v in variants if v.get("type") != "null"]
        del o["anyOf"]
        if len(rest) == 1:
            o.update({k: v for k, v in rest[0].items() if k not in o})
        elif rest:
            o["anyOf"] = rest
        # an anyOf of only null leaves an unconstrained schema

strip_null(paths)
for sec, name in needed:
    strip_null(comps[sec][name])

sub_comps = {}
for sec, name in needed:
    sub_comps.setdefault(sec, {})[name] = comps[sec][name]
if "securitySchemes" in comps:
    sub_comps["securitySchemes"] = comps["securitySchemes"]
for sec in sub_comps:
    sub_comps[sec] = dict(sorted(sub_comps[sec].items()))

used_tags = {t for op in paths.values() for m in op.values() if isinstance(m, dict) for t in m.get("tags", [])}
audio = {k: v for k, v in spec.items() if k not in ("paths", "components", "tags")}
audio["info"] = dict(spec["info"], title="ElevenLabs Audio API (subset)")
if "tags" in spec:
    audio["tags"] = [t for t in spec["tags"] if t.get("name") in used_tags]
audio["paths"] = paths
audio["components"] = sub_comps
dump(audio, audio_out)

print(f"full: {len(spec['paths'])} paths, {len(comps.get('schemas', {}))} schemas")
print(f"audio: {len(paths)} paths, {len(sub_comps.get('schemas', {}))} schemas")
