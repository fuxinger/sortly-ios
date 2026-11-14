"""Albumist app icon "Glass Stack": three album cards, the front one frosted glass with a
landscape. Writes full-bleed 1024 SVGs for light, dark and tinted, plus flat layers for
Icon Composer (the system adds the glass itself there)."""
import sys, os
out = sys.argv[1]; layers = sys.argv[2]

def rr(x, y, w, h, r):
    return (f"M {x+r} {y} H {x+w-r} A {r} {r} 0 0 1 {x+w} {y+r} V {y+h-r} A {r} {r} 0 0 1 {x+w-r} {y+h} "
            f"H {x+r} A {r} {r} 0 0 1 {x} {y+h-r} V {y+r} A {r} {r} 0 0 1 {x+r} {y} Z")

BACK = rr(338, 214, 492, 392, 92)
MID = rr(266, 316, 492, 392, 92)
FRONT = rr(194, 418, 492, 392, 92)
# Landscape inside the front card (follows its rounded bottom corners).
HILLS = "M 194 744 L 326 606 L 424 694 L 494 636 L 686 766 L 686 718 A 92 92 0 0 1 594 810 H 286 A 92 92 0 0 1 194 718 Z"
SUN = (566, 528, 46)

THEMES = {
    "light": dict(bg=("#FFFFFF", "#DCEDEF"), back=("#1BA6B1", "#0A5F6B"), mid=("#9BDDF4", "#3FAFDC"), mid_a=0.84,
                  front="#FFFFFF", front_a=0.5, hills="#0A6E7A", sun=("#FFD66B", "#FFAE2B"), shadow=0.26, rim=0.95),
    "dark":  dict(bg=("#24292B", "#0C0F10"), back=("#2CC0CB", "#0E7682"), mid=("#86D4F0", "#2E98C6"), mid_a=0.78,
                  front="#FFFFFF", front_a=0.24, hills="#3CC3CC", sun=("#FFD66B", "#FFAE2B"), shadow=0.6, rim=0.7),
    "tinted":dict(bg=("#000000", "#000000"), back=("#5A5A5A", "#3C3C3C"), mid=("#9A9A9A", "#7A7A7A"), mid_a=0.8,
                  front="#FFFFFF", front_a=0.32, hills="#E6E6E6", sun=("#FFFFFF", "#F0F0F0"), shadow=0.5, rim=0.8),
}

def svg(t):
    c = THEMES[t]
    defs = f'''
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c['bg'][0]}"/><stop offset="1" stop-color="{c['bg'][1]}"/></linearGradient>
<linearGradient id="back" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c['back'][0]}"/><stop offset="1" stop-color="{c['back'][1]}"/></linearGradient>
<linearGradient id="mid" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c['mid'][0]}"/><stop offset="1" stop-color="{c['mid'][1]}"/></linearGradient>
<linearGradient id="sun" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c['sun'][0]}"/><stop offset="1" stop-color="{c['sun'][1]}"/></linearGradient>
<linearGradient id="rim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="{c['rim']}"/><stop offset="0.42" stop-color="#FFFFFF" stop-opacity="0.12"/><stop offset="0.8" stop-color="#FFFFFF" stop-opacity="0.04"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="{c['rim']*0.55}"/></linearGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.38"/><stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0.04"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
<filter id="blur" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="24"/></filter>
<filter id="sh" x="-40%" y="-40%" width="180%" height="180%"><feDropShadow dx="0" dy="22" stdDeviation="28" flood-color="#06343A" flood-opacity="{c['shadow']}"/></filter>
<clipPath id="cm"><path d="{MID}"/></clipPath><clipPath id="cf"><path d="{FRONT}"/></clipPath>'''
    body = f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<g id="L1"><path d="{BACK}" fill="url(#back)" filter="url(#sh)"/></g>
<g id="L2">
  <use href="#L1"/>
  <path d="{MID}" fill="#000" fill-opacity="0.02" filter="url(#sh)"/>
  <g clip-path="url(#cm)"><use href="#L1" filter="url(#blur)"/><path d="{MID}" fill="url(#mid)" fill-opacity="{c['mid_a']}"/><path d="{MID}" fill="url(#sheen)"/></g>
  <path d="{MID}" fill="none" stroke="url(#rim)" stroke-width="7"/>
</g>
<path d="{FRONT}" fill="#000" fill-opacity="0.02" filter="url(#sh)"/>
<g clip-path="url(#cf)"><use href="#L2" filter="url(#blur)"/><path d="{FRONT}" fill="{c['front']}" fill-opacity="{c['front_a']}"/><path d="{FRONT}" fill="url(#sheen)"/></g>
<circle cx="{SUN[0]}" cy="{SUN[1]}" r="{SUN[2]}" fill="url(#sun)"/>
<path d="{HILLS}" fill="{c['hills']}" fill-opacity="0.94"/>
<path d="{FRONT}" fill="none" stroke="url(#rim)" stroke-width="7"/>'''
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><defs>{defs}</defs>{body}</svg>'

for t in THEMES:
    open(os.path.join(out, f"icon-{t}.svg"), "w").write(svg(t))

# Flat layers for Icon Composer (back to front). Icon Composer adds glass, shadows and the
# dark/tinted looks itself, so these are plain shapes on a transparent canvas.
def layer(name, content):
    open(os.path.join(layers, name), "w").write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{content}</svg>')
layer("0-background.svg", '<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#DCEDEF"/></linearGradient></defs><rect width="1024" height="1024" fill="url(#g)"/>')
layer("1-back-card.svg", f'<path d="{BACK}" fill="#0F8792"/>')
layer("2-middle-card.svg", f'<path d="{MID}" fill="#5CC4E8"/>')
layer("3-front-card.svg", f'<path d="{FRONT}" fill="#FFFFFF"/>')
layer("4-sun.svg", f'<circle cx="{SUN[0]}" cy="{SUN[1]}" r="{SUN[2]}" fill="#FFC24D"/>')
layer("5-hills.svg", f'<path d="{HILLS}" fill="#0A6E7A"/>')
print("ok")
