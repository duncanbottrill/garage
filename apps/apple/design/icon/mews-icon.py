import os, sys
SQ = "M0 512C0 150 150 0 512 0S1024 150 1024 512 874 1024 512 1024 0 874 0 512Z"
DM = "M172 1100 V520 C172 400 250 330 342 330 C434 330 512 400 512 520 C512 400 590 330 682 330 C774 330 852 400 852 520 V1100"
RIM = "M190 1100 V520 C190 410 262 348 342 348 C422 348 494 410 494 520 M530 520 C530 410 602 348 682 348 C762 348 834 410 834 520 V1100"
BOLT_A = "M548 500 L476 500 L432 756 L496 756 L474 910 L582 700 L520 700 Z"       # leg-width polygon
BOLT_B = "M512 540 L468 722 H556 L498 900"                                         # thick stroked zig
def bloom(i, sd): return f'<filter id="{i}" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="{sd}"/></filter>'

def night(mode, bolt="A", size=None, mac=False, square=False):
    """mode: default | dark | tinted"""
    k = f"n{mode}{bolt}{'m' if mac else ''}"
    dark = mode == "dark"; tint = mode == "tinted"
    if tint:
        bg = '<rect width="1024" height="1024" fill="none"/>'   # transparent; system supplies the background
        m_paint, bolt_top, bolt_bot, glow = "#D7DEE8", "#FFFFFF", "#B9C4D2", "#C9D3E0"
        pool = ""
    else:
        bgdef = (f'<radialGradient id="{k}bg" cx="50%" cy="16%" r="95%"><stop offset="0" stop-color="#17304A"/><stop offset=".55" stop-color="#0C1D30"/><stop offset="1" stop-color="#0A1727"/></radialGradient>' if dark else
                 f'<radialGradient id="{k}bg" cx="50%" cy="16%" r="95%"><stop offset="0" stop-color="#244566"/><stop offset=".5" stop-color="#11273D"/><stop offset="1" stop-color="#0D1F33"/></radialGradient>')
        bg = f'<rect width="1024" height="1024" fill="url(#{k}bg)"/>'
        m_paint, bolt_top, bolt_bot, glow = f"url(#{k}m)", "#EAFDFF", "#3FD9F7", "#4FE3FF"
        pool = f'<rect y="540" width="1024" height="484" fill="url(#{k}pool)"/>'
    defs = f'''<clipPath id="{k}sq"><path d="{SQ}"/></clipPath><clipPath id="{k}bc"><path d="{BOLT_A}"/></clipPath>
    {"" if tint else bgdef}
    <linearGradient id="{k}m" x1="0" y1="0" x2="0" y2="1"><stop offset=".3" stop-color="#F8FBFF"/><stop offset="1" stop-color="#8CA2BB"/></linearGradient>
    <linearGradient id="{k}bf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{bolt_top}"/><stop offset="1" stop-color="{bolt_bot}"/></linearGradient>
    <radialGradient id="{k}pool" cx="50%" cy="100%" r="56%"><stop offset="0" stop-color="#4FE3FF" stop-opacity="{'.42' if dark else '.5'}"/><stop offset="1" stop-color="#4FE3FF" stop-opacity="0"/></radialGradient>
    <radialGradient id="{k}rl" cx="512" cy="730" r="330" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></radialGradient>
    <mask id="{k}rm"><rect width="1024" height="1024" fill="url(#{k}rl)"/></mask>
    <linearGradient id="{k}gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="{'.06' if dark else '.16'}"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
    {bloom(k+"sh",22)}{bloom(k+"b1",34)}{bloom(k+"b2",9)}{bloom(k+"seam",9)}'''
    # bolt layer (behind the m)
    if bolt == "A":
        boltsvg = f'''<path d="{BOLT_A}" fill="{glow}" opacity=".6" filter="url(#{k}b1)" transform="translate(0,10)"/>
        <path d="{BOLT_A}" fill="{glow}" opacity=".9" filter="url(#{k}b2)"/>
        <path d="{BOLT_A}" fill="url(#{k}bf)" stroke="url(#{k}bf)" stroke-width="12" stroke-linejoin="round"/>
        <path d="M484 520 L446 740" stroke="#fff" stroke-opacity=".55" stroke-width="6" stroke-linecap="round"/>
        <path d="{DM}" fill="none" stroke="#000" stroke-opacity=".55" stroke-width="88" filter="url(#{k}seam)" clip-path="url(#{k}bc)" transform="translate(0,14)"/>'''
    else:
        boltsvg = f'''<path d="{BOLT_B}" fill="none" stroke="{glow}" stroke-width="110" stroke-linecap="round" stroke-linejoin="round" opacity=".7" filter="url(#{k}b1)"/>
        <path d="{BOLT_B}" fill="none" stroke="{glow}" stroke-width="80" stroke-linecap="round" stroke-linejoin="round" opacity=".9" filter="url(#{k}b2)"/>
        <path d="{BOLT_B}" fill="none" stroke="url(#{k}bf)" stroke-width="72" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M498 560 L462 714" stroke="#fff" stroke-opacity=".5" stroke-width="6" stroke-linecap="round"/>'''
    rim = "" if tint else f'''<g mask="url(#{k}rm)"><path d="{DM}" fill="none" stroke="#4FE3FF" stroke-width="72" stroke-linecap="round" stroke-linejoin="round" opacity=".38"/></g>
    <path d="M208 1100 V560 M816 1100 V560" stroke="#4FE3FF" stroke-opacity=".35" stroke-width="4" stroke-linecap="round" mask="url(#{k}rm)"/>'''
    body = f'''{bg}{pool}
    {boltsvg}
    <path d="{DM}" fill="none" stroke="#000" stroke-opacity="{'0' if tint else '.6'}" stroke-width="84" stroke-linecap="round" stroke-linejoin="round" filter="url(#{k}sh)" transform="translate(0,26)"/>
    <path d="{DM}" fill="none" stroke="{m_paint}" stroke-width="72" stroke-linecap="round" stroke-linejoin="round"/>
    {rim}
    <path d="{RIM}" fill="none" stroke="#fff" stroke-opacity="{'.3' if tint else '.5'}" stroke-width="5" stroke-linecap="round"/>
    {"" if tint else f'<rect width="1024" height="520" fill="url(#{k}gloss)"/>'}
    {"" if (tint or square) else f'<path d="{SQ}" fill="none" stroke="#fff" stroke-opacity=".09" stroke-width="6"/>'}'''
    a = f' width="{size}" height="{size}"' if size else ""
    if mac:
        # macOS: artwork inset to the 824pt grid with the system-style shadow, transparent outside
        return f'''<svg viewBox="0 0 1024 1024"{a} xmlns="http://www.w3.org/2000/svg"><defs>{defs}<filter id="{k}ms" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity=".45"/></filter></defs>
        <g transform="translate(100,100) scale(0.8046875)" filter="url(#{k}ms)"><g clip-path="url(#{k}sq)">{body}</g></g></svg>'''
    clip = "" if square else f' clip-path="url(#{k}sq)"'
    return f'<svg viewBox="0 0 1024 1024"{a} xmlns="http://www.w3.org/2000/svg"><defs>{defs}</defs><g{clip}>{body}</g></svg>'

if __name__ == "__main__":
    CSS='''body{margin:0;background:#0B0F14;font-family:-apple-system,Helvetica;color:#EAF0F6}
    .grid{display:grid;grid-template-columns:repeat(3,440px);gap:40px;padding:36px;width:max-content}
    .cell{display:flex;flex-direction:column;align-items:center;gap:12px}.cell .big svg{width:440px;height:440px}
    .row{display:flex;gap:18px;align-items:center}.t{font-size:16px;font-weight:600}'''
    cells=""
    for b,t in (("A","A · leg-width polygon bolt, m shadow seam"),("B","B · the m's own stroke bent into a bolt")):
        cells += f'<div class="cell"><div class="big">{night("default",b)}</div><div class="row">{night("default",b,120)}{night("dark",b,120)}{night("default",b,60)}</div><div class="t">{t}</div></div>'
    open("bolt-compare.html","w").write(f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body><div class="grid">{cells}</div></body></html>')
    print("ok")
