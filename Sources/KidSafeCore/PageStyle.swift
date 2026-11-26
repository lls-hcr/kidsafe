import Foundation

/// Style commun des pages locales de KidSafe (mode détaillé du moniteur et guide d'utilisation) :
/// sobre, une seule couleur d'accent (le bleu pétrole de l'icône), fonds neutres, clair et sombre.
public enum PageStyle {
    /// Icône de l'app : bouclier blanc et gecko (yamori), généré depuis GeckoShape (scripts/make-icon.swift).
    public static let logo = """
    <svg class="logo" viewBox="0 0 64 64" aria-hidden="true"><rect width="64" height="64" rx="14" fill="#3d839f"/><path d="M32 6.83C41.57 11.38 49.4 11.88 53.75 13.9C54.18 38.14 45.05 52.27 32 57.32C18.95 52.27 9.82 38.14 10.25 13.9C14.6 11.88 22.43 11.38 32 6.83Z" fill="#fff"/><g fill="#3d839f" stroke="#3d839f" stroke-linecap="round"><circle cx="32" cy="13.48" r="1.2"/><circle cx="32" cy="13.6" r="1.3"/><circle cx="32" cy="13.77" r="1.56"/><circle cx="32" cy="13.96" r="1.9"/><circle cx="32" cy="14.18" r="2.24"/><circle cx="32" cy="14.42" r="2.5"/><circle cx="32" cy="14.68" r="2.6"/><circle cx="32" cy="14.97" r="2.67"/><circle cx="32" cy="15.3" r="2.84"/><circle cx="32" cy="15.64" r="3.05"/><circle cx="32" cy="16" r="3.27"/><circle cx="32" cy="16.35" r="3.44"/><circle cx="32" cy="16.69" r="3.5"/><circle cx="32" cy="17.01" r="3.47"/><circle cx="32.01" cy="17.34" r="3.37"/><circle cx="32.02" cy="17.66" r="3.25"/><circle cx="32.03" cy="17.98" r="3.13"/><circle cx="32.04" cy="18.29" r="3.04"/><circle cx="32.05" cy="18.59" r="3"/><circle cx="32.06" cy="18.87" r="2.94"/><circle cx="32.08" cy="19.14" r="2.8"/><circle cx="32.1" cy="19.39" r="2.6"/><circle cx="32.11" cy="19.65" r="2.41"/><circle cx="32.13" cy="19.91" r="2.26"/><circle cx="32.15" cy="20.19" r="2.2"/><circle cx="32.17" cy="20.47" r="2.23"/><circle cx="32.18" cy="20.75" r="2.31"/><circle cx="32.2" cy="21.03" r="2.4"/><circle cx="32.22" cy="21.32" r="2.5"/><circle cx="32.23" cy="21.64" r="2.57"/><circle cx="32.25" cy="21.99" r="2.6"/><circle cx="32.27" cy="22.37" r="2.65"/><circle cx="32.29" cy="22.78" r="2.76"/><circle cx="32.31" cy="23.22" r="2.9"/><circle cx="32.33" cy="23.67" r="3.05"/><circle cx="32.35" cy="24.13" r="3.16"/><circle cx="32.35" cy="24.59" r="3.2"/><circle cx="32.35" cy="25.07" r="3.23"/><circle cx="32.34" cy="25.56" r="3.28"/><circle cx="32.33" cy="26.07" r="3.35"/><circle cx="32.31" cy="26.58" r="3.43"/><circle cx="32.28" cy="27.09" r="3.48"/><circle cx="32.25" cy="27.6" r="3.5"/><circle cx="32.21" cy="28.1" r="3.49"/><circle cx="32.15" cy="28.62" r="3.45"/><circle cx="32.09" cy="29.13" r="3.4"/><circle cx="32.03" cy="29.63" r="3.35"/><circle cx="31.96" cy="30.13" r="3.32"/><circle cx="31.9" cy="30.6" r="3.3"/><circle cx="31.83" cy="31.05" r="3.26"/><circle cx="31.76" cy="31.49" r="3.15"/><circle cx="31.69" cy="31.91" r="3"/><circle cx="31.62" cy="32.32" r="2.86"/><circle cx="31.56" cy="32.72" r="2.75"/><circle cx="31.5" cy="33.1" r="2.7"/><circle cx="31.45" cy="33.46" r="2.66"/><circle cx="31.4" cy="33.79" r="2.55"/><circle cx="31.36" cy="34.1" r="2.4"/><circle cx="31.33" cy="34.42" r="2.26"/><circle cx="31.3" cy="34.75" r="2.15"/><circle cx="31.3" cy="35.1" r="2.1"/><circle cx="31.31" cy="35.49" r="2.07"/><circle cx="31.32" cy="35.89" r="2"/><circle cx="31.35" cy="36.3" r="1.9"/><circle cx="31.39" cy="36.73" r="1.81"/><circle cx="31.46" cy="37.16" r="1.73"/><circle cx="31.55" cy="37.61" r="1.7"/><circle cx="31.67" cy="38.06" r="1.68"/><circle cx="31.81" cy="38.54" r="1.62"/><circle cx="31.97" cy="39.02" r="1.55"/><circle cx="32.16" cy="39.5" r="1.48"/><circle cx="32.37" cy="39.97" r="1.42"/><circle cx="32.6" cy="40.41" r="1.4"/><circle cx="32.87" cy="40.82" r="1.38"/><circle cx="33.18" cy="41.2" r="1.34"/><circle cx="33.51" cy="41.58" r="1.28"/><circle cx="33.85" cy="41.95" r="1.22"/><circle cx="34.19" cy="42.32" r="1.17"/><circle cx="34.5" cy="42.71" r="1.15"/><circle cx="34.81" cy="43.11" r="1.13"/><circle cx="35.14" cy="43.52" r="1.09"/><circle cx="35.45" cy="43.94" r="1.03"/><circle cx="35.75" cy="44.36" r="0.97"/><circle cx="36" cy="44.78" r="0.92"/><circle cx="36.2" cy="45.21" r="0.9"/><circle cx="36.35" cy="45.66" r="0.89"/><circle cx="36.47" cy="46.13" r="0.85"/><circle cx="36.54" cy="46.6" r="0.8"/><circle cx="36.57" cy="47.07" r="0.75"/><circle cx="36.56" cy="47.51" r="0.72"/><circle cx="36.5" cy="47.91" r="0.7"/><circle cx="36.39" cy="48.3" r="0.69"/><circle cx="36.21" cy="48.67" r="0.65"/><circle cx="36" cy="49.02" r="0.6"/><circle cx="35.75" cy="49.33" r="0.55"/><circle cx="35.48" cy="49.6" r="0.52"/><circle cx="35.2" cy="49.82" r="0.5"/><circle cx="34.9" cy="49.98" r="0.49"/><circle cx="34.56" cy="50.09" r="0.46"/><circle cx="34.2" cy="50.17" r="0.43"/><circle cx="33.83" cy="50.19" r="0.39"/><circle cx="33.5" cy="50.18" r="0.36"/><circle cx="33.2" cy="50.12" r="0.35"/><circle cx="32.94" cy="49.98" r="0.34"/><circle cx="32.7" cy="49.75" r="0.32"/><circle cx="32.48" cy="49.48" r="0.3"/><circle cx="32.28" cy="49.21" r="0.28"/><circle cx="32.12" cy="48.98" r="0.26"/><circle cx="27.3" cy="17.06" r="0.75"/><circle cx="26.05" cy="16.43" r="0.75"/><circle cx="24.66" cy="16.57" r="0.75"/><circle cx="23.56" cy="17.44" r="0.75"/><circle cx="23.1" cy="18.76" r="0.75"/><circle cx="42.49" cy="22" r="0.75"/><circle cx="42.27" cy="20.61" r="0.75"/><circle cx="41.33" cy="19.57" r="0.75"/><circle cx="39.99" cy="19.19" r="0.75"/><circle cx="38.64" cy="19.59" r="0.75"/><circle cx="22.51" cy="35.5" r="0.75"/><circle cx="22.74" cy="36.88" r="0.75"/><circle cx="23.67" cy="37.93" r="0.75"/><circle cx="25.02" cy="38.31" r="0.75"/><circle cx="26.36" cy="37.9" r="0.75"/><circle cx="37.24" cy="38.1" r="0.75"/><circle cx="38.58" cy="38.51" r="0.75"/><circle cx="39.93" cy="38.13" r="0.75"/><circle cx="40.86" cy="37.08" r="0.75"/><circle cx="41.09" cy="35.7" r="0.75"/><path d="M30.9 23.89L26.75 22.79" stroke-width="2.2"/><path d="M26.75 22.79L25.59 18.89" stroke-width="1.7"/><path d="M25.59 18.89L27.3 17.06" stroke-width="0.7"/><path d="M25.59 18.89L26.05 16.43" stroke-width="0.7"/><path d="M25.59 18.89L24.66 16.57" stroke-width="0.7"/><path d="M25.59 18.89L23.56 17.44" stroke-width="0.7"/><path d="M25.59 18.89L23.1 18.76" stroke-width="0.7"/><path d="M33.8 24.39L38.11 24.99" stroke-width="2.2"/><path d="M38.11 24.99L40.01 21.69" stroke-width="1.7"/><path d="M40.01 21.69L42.49 22" stroke-width="0.7"/><path d="M40.01 21.69L42.27 20.61" stroke-width="0.7"/><path d="M40.01 21.69L41.33 19.57" stroke-width="0.7"/><path d="M40.01 21.69L39.99 19.19" stroke-width="0.7"/><path d="M40.01 21.69L38.64 19.59" stroke-width="0.7"/><path d="M30.2 32.6L26.19 31.7" stroke-width="2.2"/><path d="M26.19 31.7L24.99 35.8" stroke-width="1.7"/><path d="M24.99 35.8L22.51 35.5" stroke-width="0.7"/><path d="M24.99 35.8L22.74 36.88" stroke-width="0.7"/><path d="M24.99 35.8L23.67 37.93" stroke-width="0.7"/><path d="M24.99 35.8L25.02 38.31" stroke-width="0.7"/><path d="M24.99 35.8L26.36 37.9" stroke-width="0.7"/><path d="M32.9 33L37.2 32.4" stroke-width="2.2"/><path d="M37.2 32.4L38.61 36" stroke-width="1.7"/><path d="M38.61 36L37.24 38.1" stroke-width="0.7"/><path d="M38.61 36L38.58 38.51" stroke-width="0.7"/><path d="M38.61 36L39.93 38.13" stroke-width="0.7"/><path d="M38.61 36L40.86 37.08" stroke-width="0.7"/><path d="M38.61 36L41.09 35.7" stroke-width="0.7"/></g></svg>
    """

    public static func header(title: String, meta: String) -> String {
        "<header><div class=\"brand\">\(logo)<span class=\"name\">Yamoxy</span><span class=\"sub\">\(title)</span></div><div class=\"meta\">\(meta)</div></header>"
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
    .events{margin:0;padding-left:1.2em;line-height:1.6}
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
    .hero h1{font-size:28px;margin:0 0 6px;letter-spacing:-.5px}.hero p{margin:0;color:var(--muted);font-size:15px;max-width:60ch}.hero p.origin{margin-top:8px;font-size:13px}
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
