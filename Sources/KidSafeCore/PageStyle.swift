import Foundation

/// Style commun des pages locales de KidSafe (mode détaillé du moniteur et guide d'utilisation) :
/// sobre, une seule couleur d'accent (le bleu pétrole de l'icône), fonds neutres, clair et sombre.
public enum PageStyle {
    /// Bouclier à moitié plein, comme l'icône de l'app.
    public static let logo = """
    <svg class="logo" viewBox="0 0 64 64" aria-hidden="true"><rect width="64" height="64" rx="14" fill="#3d839f"/>\
    <path d="M32 14c-5 3-10 4-15 5 0 14 4 24 15 31 11-7 15-17 15-31-5-1-10-2-15-5z" fill="none" stroke="#fff" stroke-width="3.2" stroke-linejoin="round"/>\
    <path d="M32 14c-5 3-10 4-15 5 0 14 4 24 15 31z" fill="#fff"/></svg>
    """

    public static func header(title: String, meta: String) -> String {
        "<header><div class=\"brand\">\(logo)<span class=\"name\">KidSafe</span><span class=\"sub\">\(title)</span></div><div class=\"meta\">\(meta)</div></header>"
    }

    public static let css = """
    :root{--bg:#f5f7f8;--card:#fff;--ink:#1b2428;--muted:#66767d;--line:#e2e7ea;--accent:#3d839f;--accent-ink:#2e6a82;
      --soft:rgba(61,131,159,.12);--track:#edf1f3}
    @media (prefers-color-scheme:dark){:root{--bg:#121719;--card:#1a2124;--ink:#e3eaed;--muted:#8d9ea5;--line:#283237;
      --accent:#5ea8c4;--accent-ink:#7dbad2;--soft:rgba(94,168,196,.15);--track:#232c30}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;
      -webkit-font-smoothing:antialiased}
    header{max-width:1180px;margin:0 auto;padding:26px 20px 6px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px}
    .brand{display:flex;align-items:center;gap:10px}.logo{width:30px;height:30px}
    .name{font-size:19px;font-weight:700;letter-spacing:-.2px}.sub{font-size:19px;color:var(--muted);font-weight:500}
    .meta{color:var(--muted);font-size:12px}
    main{max-width:1180px;margin:0 auto;padding:16px 20px 8px}
    section{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 20px 18px;margin-bottom:16px}
    h2{font-size:15px;margin:0 0 12px;font-weight:650;letter-spacing:-.1px}
    .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(178px,1fr));gap:14px;margin-bottom:16px}
    .tile{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px}
    .tt{font-size:12px;color:var(--muted);font-weight:600;letter-spacing:.2px;display:flex;align-items:flex-start;gap:7px;min-height:3.2em;line-height:1.55}
    .tt::before{content:"";flex:none;width:8px;height:8px;border-radius:50%;background:var(--line);margin-top:.45em}
    .tile.hl .tt::before{background:var(--accent)}
    .tv{font-size:30px;font-weight:700;letter-spacing:-.6px;margin:4px 0 2px;font-variant-numeric:tabular-nums}
    .tile.hl .tv{color:var(--accent-ink)}.ts{font-size:12px;color:var(--muted)}
    .grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:16px}
    .chart{width:100%;height:auto}.axis{stroke:var(--line);stroke-width:1}.bar{fill:var(--accent)}.bar:hover{opacity:.7}
    .lbl{fill:var(--muted);font-size:11px;text-anchor:middle}.val{fill:var(--muted);font-size:10.5px;text-anchor:middle;font-weight:600}
    table{width:100%;border-collapse:collapse}
    th{text-align:left;color:var(--muted);font-weight:600;font-size:12px;border-bottom:1px solid var(--line);padding:6px 8px}
    td{padding:7px 8px;border-bottom:1px solid var(--line)}tr:last-child td{border-bottom:0}
    .n{text-align:right;font-variant-numeric:tabular-nums}.dom{word-break:break-all}
    .time{color:var(--muted);white-space:nowrap;font-variant-numeric:tabular-nums}
    .freq{display:block;height:6px;background:var(--track);border-radius:3px;min-width:90px}
    .freq span{display:block;height:6px;background:var(--accent);border-radius:3px}
    .hb{display:flex;flex-direction:column;gap:10px}.hbr{display:grid;grid-template-columns:minmax(120px,38%) 1fr 56px;gap:12px;align-items:center}
    .hbn{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hbt{height:8px;background:var(--track);border-radius:4px}
    .hbf{display:block;height:8px;background:var(--accent);border-radius:4px}.hbv{text-align:right;font-variant-numeric:tabular-nums;color:var(--muted)}
    .empty{color:var(--muted)}
    .snap{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;background:var(--soft);
      border-radius:12px;padding:10px 14px;margin-bottom:16px;color:var(--accent-ink);font-weight:600;font-size:13px}
    .btn{display:inline-block;background:var(--accent);color:#fff;text-decoration:none;font-weight:600;font-size:13px;
      border-radius:8px;padding:6px 12px}.btn:hover{filter:brightness(1.08)}
    .src{color:var(--muted);font-size:12px;margin:-6px 4px 16px;text-align:right}
    .note{color:var(--muted);background:var(--soft);border-radius:10px;padding:10px 14px;margin:0 0 16px}
    footer{max-width:1180px;margin:0 auto;color:var(--muted);font-size:12px;padding:4px 20px 28px;text-align:center}
    /* Guide d'utilisation */
    .guide{max-width:960px}
    body.guide-page header,body.guide-page footer{max-width:960px}
    .hero{background:linear-gradient(135deg,var(--soft),transparent 70%),var(--card);border:1px solid var(--line);border-radius:18px;
      padding:28px 30px;margin-bottom:22px}
    .hero h1{font-size:28px;margin:0 0 6px;letter-spacing:-.5px}.hero p{margin:0;color:var(--muted);font-size:15px;max-width:60ch}
    .quick{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-top:20px}
    .quick div{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;font-size:13.5px}
    .quick b{display:block;color:var(--accent-ink);font-size:12px;letter-spacing:.3px;margin-bottom:2px}
    .toc{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:6px 18px;list-style:none;padding:0;margin:0;counter-reset:t}
    .toc li{counter-increment:t}.toc a{display:flex;gap:10px;align-items:center;padding:6px 8px;border-radius:8px;text-decoration:none;color:var(--ink)}
    .toc a:hover{background:var(--soft)}
    .toc a::before{content:counter(t);flex:none;width:22px;height:22px;border-radius:50%;background:var(--soft);color:var(--accent-ink);
      font-size:12px;font-weight:700;display:grid;place-items:center}
    .guide section{padding:24px 28px 24px;counter-increment:sec}
    .guide main,.guide{counter-reset:sec}
    .sec-head{display:flex;align-items:center;gap:12px;margin:0 0 4px}
    .num{flex:none;width:32px;height:32px;border-radius:10px;background:var(--accent);color:#fff;font-weight:700;display:grid;place-items:center}
    .guide h2{font-size:20px;margin:0;letter-spacing:-.3px;scroll-margin-top:16px}
    .lead{color:var(--muted);margin:2px 0 16px 44px;font-size:14.5px}
    .guide h3{font-size:14px;margin:18px 0 6px;color:var(--accent-ink);text-transform:uppercase;letter-spacing:.6px}
    .guide p,.guide li{max-width:70ch}.guide ul{padding-left:20px;margin:6px 0 10px}.guide li{margin:4px 0}
    .guide a{color:var(--accent-ink)}
    .split.narrow{grid-template-columns:minmax(0,1.3fr) minmax(0,.9fr)}
    .steps{list-style:none;padding:0;margin:8px 0 12px;counter-reset:s}
    .steps li{counter-increment:s;position:relative;padding:2px 0 10px 40px;margin:0}
    .steps li::before{content:counter(s);position:absolute;left:0;top:0;width:26px;height:26px;border-radius:50%;
      background:var(--soft);color:var(--accent-ink);font-weight:700;font-size:13px;display:grid;place-items:center}
    figure.shot{margin:6px 0 10px;text-align:center}
    figure.shot img{max-width:min(100%,440px);height:auto;border-radius:10px;border:1px solid var(--line);
      box-shadow:0 1px 2px rgba(0,0,0,.05),0 6px 18px rgba(0,0,0,.08);background:#fff;cursor:zoom-in;transition:transform .15s}
    figure.shot img:hover{transform:scale(1.015)}
    .split figure.shot img{max-width:min(100%,420px)}
    figure.shot.small img{max-width:min(100%,280px)}
    figure.shot.wide img{max-width:min(100%,620px)}
    .split{display:grid;grid-template-columns:minmax(0,1.15fr) minmax(0,1fr);gap:28px;align-items:start;margin:6px 0 4px}
    #zoom{position:fixed;inset:0;z-index:50;background:rgba(8,12,14,.84);display:grid;place-items:center;padding:3vh 3vw;cursor:zoom-out}
    #zoom[hidden]{display:none}
    #zoom figure{margin:0;text-align:center;max-width:94vw}
    #zoom img{max-width:94vw;max-height:86vh;width:auto;height:auto;border-radius:12px;background:#fff;box-shadow:0 20px 60px rgba(0,0,0,.5)}
    .split .kv{grid-template-columns:minmax(0,42%) 1fr}
    #zoom p{color:#e3eaed;font-size:13px;margin:10px 0 0;text-align:center}
    figcaption{color:var(--muted);font-size:12px;margin-top:8px}
    .box{border-radius:12px;padding:12px 16px 12px 16px;margin:14px 0;border-left:4px solid}
    .box b.tag{display:block;font-size:11px;letter-spacing:.6px;text-transform:uppercase;margin-bottom:3px}
    .tip{background:var(--soft);border-color:var(--accent)}.tip b.tag{color:var(--accent-ink)}
    .warn{background:rgba(214,146,34,.12);border-color:#d69222}.warn b.tag{color:#b37712}
    .ok{background:rgba(52,150,96,.11);border-color:#349660}.ok b.tag{color:#2a7d50}
    @media (prefers-color-scheme:dark){.warn b.tag{color:#e3a94a}.ok b.tag{color:#5cc28a}}
    .kv{display:grid;grid-template-columns:max-content 1fr;gap:0;margin:10px 0;border:1px solid var(--line);border-radius:12px;overflow:hidden}
    .kv dt,.kv dd{margin:0;padding:9px 14px;border-bottom:1px solid var(--line)}.kv dt{font-weight:600;background:var(--track)}
    .kv dt:nth-last-of-type(1),.kv dd:last-of-type{border-bottom:0}
    .check{list-style:none;padding:0}.check li{padding-left:28px;position:relative}
    .check li::before{content:"✓";position:absolute;left:4px;color:#349660;font-weight:800}
    .faq{border:1px solid var(--line);border-radius:12px;padding:12px 16px;margin:10px 0}
    .faq b{display:block;margin-bottom:3px}
    hr.sep{border:0;height:1px;background:var(--line);margin:22px 0}
    kbd,.ui{font:600 12.5px/1 -apple-system,BlinkMacSystemFont,sans-serif;background:var(--track);border:1px solid var(--line);
      border-radius:6px;padding:3px 7px;white-space:nowrap}
    code{font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--track);border-radius:5px;padding:1px 5px}
    @media (max-width:760px){.split,.split.narrow{grid-template-columns:1fr}.lead{margin-left:0}}
    @media (max-width:560px){.grid2{grid-template-columns:1fr}.tv{font-size:26px}}
    """
}
