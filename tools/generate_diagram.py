#!/usr/bin/env python3
"""Diagram compiler for cpp-concurrency-and-parallelism.

Based on the lgtm-diagram-generator, recolored to this book's bespoke palette
(see diagrams/README.md) instead of the generator's default amber theme. Keeps
the same spec shape: bands (background lanes), nodes (rounded boxes with a bold
title + smaller grey detail lines), edges (arrows with optional labels), notes.
emit() writes a themed SVG (embedded in the site) and an editable Excalidraw
source into OUT/.

Usage:
    import sys; sys.path.insert(0, "tools")
    import generate_diagram as g
    g.OUT = "diagrams"
    g.emit("16-first-touch-misplacement", 820, 360, bands=[...], nodes=[...], ...)

Node styles: box (white), blue, green, orange, red (solid-colored subject
boxes with a light wash fill), sub (secondary, light border), ghost (dashed,
absent/optional), ink (dark fill, light text, a strong terminal/result box).
Edges: default dark; pass heat=True (alias amber=True) for an emphasized red
arrow. bands hold other boxes (label sits top-left).
"""
import json, random, html

OUT = "."  # output dir; callers set: generate_diagram.OUT = "diagrams"

# ---- bespoke palette ------------------------------------------------------
# (fill, stroke) per node style. Washes are the light tints; strokes are the
# saturated brand colors from diagrams/README.md.
CREAM   = "#fdfbf7"
INK     = "#1a1a1a"   # title text / strong boxes
GREY    = "#6b6b6b"   # detail text
DARK    = "#2d2d2d"   # default arrows + box borders
HEAT    = "#c0392b"   # emphasized ("hot") arrows + danger
BAND_FILL   = "#fbfaf6"
BAND_STROKE = "#e8e1d3"

STYLES = {
    "box":    ("#ffffff", DARK),       # the default thing
    "blue":   ("#e8f0fb", "#4a73b8"),  # primary / user-space / client side
    "green":  ("#d8e8df", "#5a8870"),  # success / local / fast path
    "orange": ("#faf0e6", "#a06030"),  # warning / the highlighted subject
    "red":    ("#fef3f0", HEAT),       # danger / heat / remote cost
    "accent": ("#faf0e6", "#a06030"),  # alias of orange (generator-compat)
    "user":   ("#e8f0fb", "#4a73b8"),  # alias of blue (generator-compat)
    "sub":    ("#ffffff", "#b9b2a4"),  # secondary / aside boxes
    "kernel": ("#f2efe9", "#8a8172"),  # kernel / system side
    "ghost":  ("#ffffff", "#b9b2a4"),  # dashed: optional/absent/future
    "ink":    ("#2d2d2d", INK),        # dark fill, light text (strong result)
}

def _seed(): return random.randint(1, 2_000_000_000)
def esc(s): return html.escape(str(s), quote=True)

def _is_hot(e): return e.get("heat") or e.get("amber")

# ---- SVG ------------------------------------------------------------------
def _svg(width, height, bands, nodes, edges, notes):
    o = []
    o.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
             f'font-family="\'Red Hat Text\', system-ui, sans-serif" role="img">')
    o.append(f'<rect x="0" y="0" width="{width}" height="{height}" fill="{CREAM}"/>')
    o.append('<defs>'
             f'<marker id="a" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="9" markerHeight="9" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{DARK}"/></marker>'
             f'<marker id="am" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="9" markerHeight="9" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{HEAT}"/></marker>'
             '</defs>')
    for b in bands:
        x,y,w,h,label,fill = b["x"],b["y"],b["w"],b["h"],b.get("label",""),b.get("fill",BAND_FILL)
        o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{fill}" stroke="{BAND_STROKE}"/>')
        if label:
            o.append(f'<text x="{x+12}" y="{y+20}" font-size="12" font-weight="700" fill="{GREY}">{esc(label)}</text>')
    # Nodes draw BEFORE edges so arrowheads land on top of boxes.
    for n in nodes:
        fill, stroke = STYLES[n.get("style","box")]
        dash = ' stroke-dasharray="6 4"' if n.get("style")=="ghost" else ""
        sw = 2 if n.get("style") in ("box","accent","blue","green","orange","red","user","ink") else 1.5
        x,y,w,h = n["x"],n["y"],n["w"],n["h"]
        o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="9" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{dash}/>')
        lines = n["lines"]; cx = x+w/2
        tcol = "#ffffff" if n.get("style")=="ink" else INK
        scol = "#d7d7d7" if n.get("style")=="ink" else GREY
        n_extra = len(lines)-1
        block_h = 17 + n_extra*15
        ty = y + (h-block_h)/2 + 14
        o.append(f'<text x="{cx}" y="{ty}" font-size="13.5" font-weight="700" fill="{tcol}" text-anchor="middle">{esc(lines[0])}</text>')
        for i,ln in enumerate(lines[1:]):
            o.append(f'<text x="{cx}" y="{ty+17+i*15}" font-size="11.5" fill="{scol}" text-anchor="middle">{esc(ln)}</text>')
    for e in edges:
        hot = _is_hot(e)
        col = HEAT if hot else DARK
        mk = "am" if hot else "a"
        dash = ' stroke-dasharray="5 4"' if e.get("dashed") else ""
        ms = f' marker-start="url(#{mk})"' if e.get("bidir") else ""
        o.append(f'<path d="M{e["x1"]},{e["y1"]} L{e["x2"]},{e["y2"]}" fill="none" stroke="{col}" stroke-width="2"{dash}{ms} marker-end="url(#{mk})"/>')
        if e.get("label"):
            mx,my = (e["x1"]+e["x2"])/2, (e["y1"]+e["y2"])/2
            lx,ly = mx+e.get("lx",6), my+e.get("ly",-6)
            o.append(f'<text x="{lx}" y="{ly}" font-size="11" fill="{CREAM}" stroke="{CREAM}" stroke-width="3" paint-order="stroke" text-anchor="middle">{esc(e["label"])}</text>')
            o.append(f'<text x="{lx}" y="{ly}" font-size="11" fill="{col}" text-anchor="middle">{esc(e["label"])}</text>')
    for t in notes:
        anchor = t.get("anchor","start")
        bold = ' font-weight="700"' if t.get("bold") else ''
        o.append(f'<text x="{t["x"]}" y="{t["y"]}" font-size="{t.get("size",11)}" fill="{t.get("color",GREY)}" text-anchor="{anchor}"{bold}>{esc(t["text"])}</text>')
    o.append('</svg>')
    return "\n".join(o)

# ---- Excalidraw -----------------------------------------------------------
def _exc(bands, nodes, edges, notes):
    els = []
    def rect(x,y,w,h,stroke,bg,dashed=False):
        els.append({"id":f"r{_seed()}","type":"rectangle","x":x,"y":y,"width":w,"height":h,"angle":0,
            "strokeColor":stroke,"backgroundColor":bg,"fillStyle":"solid","strokeWidth":2,
            "strokeStyle":"dashed" if dashed else "solid","roughness":1,"opacity":100,"groupIds":[],
            "frameId":None,"roundness":{"type":3},"seed":_seed(),"versionNonce":_seed(),"isDeleted":False,
            "boundElements":[],"updated":1,"link":None,"locked":False})
    def text(x,y,s,size=14,color=INK):
        els.append({"id":f"t{_seed()}","type":"text","x":x,"y":y,"width":max(40,len(s)*size*0.55),
            "height":size*1.25,"angle":0,"strokeColor":color,"backgroundColor":"transparent","fillStyle":"solid",
            "strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"frameId":None,
            "roundness":None,"seed":_seed(),"versionNonce":_seed(),"isDeleted":False,"boundElements":[],
            "updated":1,"link":None,"locked":False,"text":s,"fontSize":size,"fontFamily":1,"textAlign":"left",
            "verticalAlign":"top","containerId":None,"originalText":s,"lineHeight":1.25,"baseline":size})
    def arrow(x1,y1,x2,y2,color=DARK,dashed=False):
        els.append({"id":f"a{_seed()}","type":"arrow","x":x1,"y":y1,"width":abs(x2-x1),"height":abs(y2-y1),
            "angle":0,"strokeColor":color,"backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,
            "strokeStyle":"dashed" if dashed else "solid","roughness":1,"opacity":100,"groupIds":[],"frameId":None,
            "roundness":{"type":2},"seed":_seed(),"versionNonce":_seed(),"isDeleted":False,"boundElements":[],
            "updated":1,"link":None,"locked":False,"points":[[0,0],[x2-x1,y2-y1]],"lastCommittedPoint":None,
            "startBinding":None,"endBinding":None,"startArrowhead":None,"endArrowhead":"arrow"})
    for b in bands:
        rect(b["x"],b["y"],b["w"],b["h"],BAND_STROKE,b.get("fill",BAND_FILL))
        if b.get("label"): text(b["x"]+12,b["y"]+6,b["label"],12,GREY)
    for n in nodes:
        fill,stroke = STYLES[n.get("style","box")]
        rect(n["x"],n["y"],n["w"],n["h"],stroke,fill,dashed=(n.get("style")=="ghost"))
        tcol = "#ffffff" if n.get("style")=="ink" else INK
        text(n["x"]+10,n["y"]+8,n["lines"][0],14,tcol)
        for i,ln in enumerate(n["lines"][1:]):
            text(n["x"]+10,n["y"]+28+i*15,ln,11,("#d7d7d7" if n.get("style")=="ink" else GREY))
    for e in edges:
        col = HEAT if _is_hot(e) else DARK
        arrow(e["x1"],e["y1"],e["x2"],e["y2"],col,dashed=e.get("dashed",False))
        if e.get("label"):
            text((e["x1"]+e["x2"])/2,(e["y1"]+e["y2"])/2-14,e["label"],11,col)
    for t in notes:
        text(t["x"],t["y"]-10,t["text"],t.get("size",11),t.get("color",GREY))
    return {"type":"excalidraw","version":2,"source":"https://excalidraw.com","elements":els,
            "appState":{"viewBackgroundColor":CREAM,"gridSize":None},"files":{}}

def emit(name, width, height, bands=None, nodes=None, edges=None, notes=None):
    bands=bands or []; nodes=nodes or []; edges=edges or []; notes=notes or []
    open(f"{OUT}/{name}.svg","w").write(_svg(width,height,bands,nodes,edges,notes))
    json.dump(_exc(bands,nodes,edges,notes), open(f"{OUT}/{name}.excalidraw","w"), indent=1)
    import xml.dom.minidom as m; m.parseString(open(f"{OUT}/{name}.svg").read())
    json.load(open(f"{OUT}/{name}.excalidraw"))
    print("emit", name)
