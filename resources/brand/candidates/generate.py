# Bars in a 1024 box, mirroring the Wispr construction: 5 capsules, pitch 125, width 80.
W = 80; PITCH = 125; CX = 512
xs = [CX + (i-2)*PITCH for i in range(5)]
variants = {
  # name: [(top, bottom)] for bars 1..5 (symmetric)
  "wispr-w":  [(215,780),(480,720),(310,690),(480,720),(215,780)],
  "murmr-m":[(215,780),(320,600),(410,690),(320,600),(215,780)],
  "stroke":[(215,780),(280,560),(500,780),(280,560),(215,780)],
  "stroke-lifted":[(215,780),(300,580),(480,760),(300,580),(215,780)],
  "m1-mirror":[(215,780),(340,720),(480,720),(340,720),(215,780)],
  "m2-centred":[(215,785),(320,680),(400,600),(320,680),(215,785)],
  "m3-baseline":[(215,780),(380,780),(520,780),(380,780),(215,780)],
  "m4-soft":  [(215,780),(360,740),(470,710),(360,740),(215,780)],
}
palettes = {"cream-black":("#1c1c1c","#fbfbea"), "cream-navy":("#04101F","#EDF4FB"), "gold-navy":("#04101F","#EBCE83")}
def svg(bars, bg, fg, rounded=True, size=1024):
    out=[f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="{size}" height="{size}">']
    if bg: out.append(f'<rect width="1024" height="1024" rx="{230 if rounded else 0}" fill="{bg}"/>')
    for x,(t,b) in zip(xs,bars):
        out.append(f'<rect x="{x-W/2}" y="{t}" width="{W}" height="{b-t}" rx="{W/2}" fill="{fg}"/>')
    out.append('</svg>'); return "\n".join(out)
for name,bars in variants.items():
    for pname,(bg,fg) in palettes.items():
        open(f"{name}--{pname}.svg","w").write(svg(bars,bg,fg))
    open(f"{name}--glyph.svg","w").write(svg(bars,None,"#000000"))
