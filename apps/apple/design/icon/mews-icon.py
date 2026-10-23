from mews_icon_base import SQ, DM, RIM, bloom
# bolt centred on the icon; m in the same place, cut through the bolt with a gap that shows the field
BOLT = "M548 500 L476 500 L432 756 L496 756 L474 910 L582 700 L520 700 Z"   # centroid ~ (507,705)

def centred(mode, scale=1.0, gap=22, size=None, mac=False, square=False):
    k = f"c{mode}{int(scale*100)}{gap}{'m' if mac else ''}{'s' if square else ''}"
    dark = mode == "dark"; tint = mode == "tinted"
    if tint:
        bgdef = ""; bg = ""
        m_paint, bolt_top, bolt_bot, glow = "#D7DEE8", "#FFFFFF", "#B9C4D2", "#C9D3E0"; pool = ""
    else:
        bgdef = (f'<radialGradient id="{k}bg" cx="50%" cy="16%" r="95%"><stop offset="0" stop-color="#17304A"/><stop offset=".55" stop-color="#0C1D30"/><stop offset="1" stop-color="#0A1727"/></radialGradient>' if dark else
                 f'<radialGradient id="{k}bg" cx="50%" cy="16%" r="95%"><stop offset="0" stop-color="#244566"/><stop offset=".5" stop-color="#11273D"/><stop offset="1" stop-color="#0D1F33"/></radialGradient>')
        bg = f'<rect width="1024" height="1024" fill="url(#{k}bg)"/>'
        m_paint, bolt_top, bolt_bot, glow = f"url(#{k}m)", "#EAFDFF", "#3FD9F7", "#4FE3FF"
        pool = f'<rect y="560" width="1024" height="464" fill="url(#{k}pool)"/>'
    tb = f"translate(512,512) scale({scale}) translate(-507,-705)"
    defs = f'''<clipPath id="{k}sq"><path d="{SQ}"/></clipPath>{bgdef}
    <linearGradient id="{k}m" x1="0" y1="0" x2="0" y2="1"><stop offset=".3" stop-color="#F8FBFF"/><stop offset="1" stop-color="#8CA2BB"/></linearGradient>
    <linearGradient id="{k}bf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{bolt_top}"/><stop offset="1" stop-color="{bolt_bot}"/></linearGradient>
    <radialGradient id="{k}pool" cx="50%" cy="100%" r="56%"><stop offset="0" stop-color="#4FE3FF" stop-opacity="{'.3' if dark else '.36'}"/><stop offset="1" stop-color="#4FE3FF" stop-opacity="0"/></radialGradient>
    <radialGradient id="{k}rl" cx="512" cy="560" r="360" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></radialGradient>
    <mask id="{k}rm"><rect width="1024" height="1024" fill="url(#{k}rl)"/></mask>
    <mask id="{k}gapm"><rect width="1024" height="1024" fill="#fff"/><path d="{DM}" fill="none" stroke="#000" stroke-width="{72+2*gap}" stroke-linecap="round" stroke-linejoin="round"/></mask>
    <linearGradient id="{k}gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="{'.06' if dark else '.16'}"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
    {bloom(k+"sh",22)}{bloom(k+"b1",34)}{bloom(k+"b2",9)}'''
    boltsvg = f'''<g mask="url(#{k}gapm)">
      <g transform="{tb}">
       <path d="{BOLT}" fill="{glow}" opacity=".55" filter="url(#{k}b1)" transform="translate(0,10)"/>
       <path d="{BOLT}" fill="{glow}" opacity=".9" filter="url(#{k}b2)"/>
       <path d="{BOLT}" fill="url(#{k}bf)" stroke="url(#{k}bf)" stroke-width="12" stroke-linejoin="round"/>
       <path d="M484 520 L446 740" stroke="#fff" stroke-opacity=".55" stroke-width="6" stroke-linecap="round"/>
      </g></g>'''
    rim = "" if tint else f'''<g mask="url(#{k}rm)"><path d="{DM}" fill="none" stroke="#4FE3FF" stroke-width="72" stroke-linecap="round" stroke-linejoin="round" opacity=".34"/></g>'''
    body = f'''{bg}{pool}{boltsvg}
    <path d="{DM}" fill="none" stroke="#000" stroke-opacity="{'0' if tint else '.55'}" stroke-width="84" stroke-linecap="round" stroke-linejoin="round" filter="url(#{k}sh)" transform="translate(0,26)" mask="url(#{k}gapm)"/>
    <path d="{DM}" fill="none" stroke="{m_paint}" stroke-width="72" stroke-linecap="round" stroke-linejoin="round"/>
    {rim}
    <path d="{RIM}" fill="none" stroke="#fff" stroke-opacity="{'.3' if tint else '.5'}" stroke-width="5" stroke-linecap="round"/>
    {"" if tint else f'<rect width="1024" height="520" fill="url(#{k}gloss)"/>'}
    {"" if (tint or square) else f'<path d="{SQ}" fill="none" stroke="#fff" stroke-opacity=".09" stroke-width="6"/>'}'''
    a = f' width="{size}" height="{size}"' if size else ""
    if mac:
        return f'''<svg viewBox="0 0 1024 1024"{a} xmlns="http://www.w3.org/2000/svg"><defs>{defs}<filter id="{k}ms" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity=".45"/></filter></defs>
        <g transform="translate(100,100) scale(0.8046875)" filter="url(#{k}ms)"><g clip-path="url(#{k}sq)">{body}</g></g></svg>'''
    clip = "" if square else f' clip-path="url(#{k}sq)"'
    return f'<svg viewBox="0 0 1024 1024"{a} xmlns="http://www.w3.org/2000/svg"><defs>{defs}</defs><g{clip}>{body}</g></svg>'

if __name__ == "__main__":
    CSS='''body{margin:0;background:#0B0F14;font-family:-apple-system,Helvetica;color:#EAF0F6}
    .grid{display:grid;grid-template-columns:repeat(3,400px);gap:36px;padding:34px;width:max-content}
    .cell{display:flex;flex-direction:column;align-items:center;gap:10px}.big svg{width:400px;height:400px;filter:drop-shadow(0 18px 30px rgba(0,0,0,.45))}
    .row{display:flex;gap:14px;align-items:flex-end}.t{font-size:16px;font-weight:600}.s{font-size:13px;color:#7D8A99;text-align:center;max-width:380px}'''
    opts=[(1.0,22,"A · bolt at its current size, centred, 22px gap"),(1.25,22,"B · bolt 25% larger, centred, 22px gap"),(1.25,34,"C · 25% larger, wider 34px gap")]
    cells="".join(f'<div class="cell"><div class="big">{centred("default",sc,g)}</div><div class="row">{centred("dark",sc,g,120)}{centred("tinted",sc,g,120)}{centred("default",sc,g,60)}</div><div class="t">{t}</div></div>' for sc,g,t in opts)
    open("centred.html","w").write(f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body><div class="grid">{cells}</div></body></html>')
    print("ok")
