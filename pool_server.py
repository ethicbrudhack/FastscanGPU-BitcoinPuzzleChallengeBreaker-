#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
# pool_server.py - koordynator poola / pool coordinator
# ------------------------------------------------------------
# [PL] Serwer rozdaje rozlaczne segmenty chunkow (round, from, to) workerom,
#      pilnuje dzierzawy (lease/timeout), liczy wklad kazdego workera i
#      sklada pelny klucz k=(d+s) mod n gdy przyjdzie share d.
# [EN] Server hands out disjoint chunk segments (round, from, to) to workers,
#      manages leases/timeouts, tracks each worker's contribution and
#      combines the full key k=(d+s) mod n when a share d arrives.
#
# [PL] Czysta biblioteka standardowa Pythona - ZERO zaleznosci pip.
# [EN] Pure Python standard library - ZERO pip dependencies.
#
# [PL] UCZCIWOSC: split-key (share d) to FILTR na naiwnych, NIE gwarancja.
#      Kto trafi, technicznie ma klucz publiczny (P=d*G+S) i moze uzyc
#      kangaroo. Podzial 40/5/55 opiera sie na zaufaniu do operatora.
# [EN] FAIRNESS: split-key (share d) is a FILTER against naive users, NOT a
#      guarantee. A finder technically holds the public key (P=d*G+S) and can
#      run kangaroo. The 40/5/55 split relies on trust in the operator.
# ============================================================
import json
import os
import sqlite3
import sys
import time
import secrets
import hashlib
import argparse
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.parse

import splitkey_tool as sk  # nasze narzedzie krypto / our crypto helper
try:
    import notify  # [PL] alerty Telegram (opcjonalne) / [EN] Telegram alerts (optional)
except Exception:
    notify = None

DB_PATH = os.environ.get("POOL_DB_PATH", "pool.db")

# ============================================================
# [PL] System banowania / anti-spam pustych kluczy
# [EN] Ban system / anti-spam for empty keys
# ============================================================
# [PL] Ile pustych/nieprawidlowych share'y z rzedu -> BAN
# [EN] Consecutive empty/invalid shares -> BAN
EMPTY_SHARE_BAN_THRESHOLD = 5
# [PL] Po ilu pustych share'ach oznaczamy segment do ponownego przeszukania
# [EN] After how many empty shares we mark segment for re-scan
EMPTY_SHARE_REASSIGN_THRESHOLD = 3
# [PL] Maksymalna liczba share'ow w krotkim oknie czasowym (anty-spam)
# [EN] Max shares in short time window (anti-spam burst)
SHARE_BURST_MAX = 50
SHARE_BURST_WINDOW = 10  # seconds

# [PL] GLOBALNA BLOKADA zapisow do bazy. ThreadingHTTPServer obsluguje kazdego
#      kopacza w osobnym watku. Sekcje "przeczytaj-zmien-zapisz" (przydzial
#      segmentu, /done, /found) MUSZA byc atomowe, inaczej przy 100+ kopaczach
#      dwoch dostaloby TEN SAM zakres (duble) albo policzylibysmy zly wklad.
#      SQLite i tak serializuje zapisy; ta blokada gwarantuje spojnosc logiki
#      na poziomie Pythona (read-modify-write) i eliminuje wyscigi.
# [EN] GLOBAL write lock. ThreadingHTTPServer serves each miner in its own
#      thread. Read-modify-write sections (segment assignment, /done, /found)
#      MUST be atomic, otherwise with 100+ miners two could get the SAME range
#      (duplicates) or contribution could be miscounted. This lock guarantees
#      logic consistency at the Python level and removes races.
DB_LOCK = threading.Lock()

# --- Parametry rozdzialu / distribution parameters ---
INITIAL_CHUNKS = 3563          # jak w main_optimized.cu (runda 1) / round 1
SEGMENT_SIZE   = 200           # domyslny rozmiar (pierwszy segment / default first segment)
SEGMENT_MIN    = 50            # minimalny rozmiar (slaba karta) / minimum (weak GPU)
SEGMENT_MAX    = 5000          # maksymalny rozmiar (mocna karta) / maximum (strong GPU)
SEGMENT_TARGET = 60.0          # docelowy czas segmentu w sekundach / target segment time in seconds
LEASE_SECONDS  = 1800          # 30 min: potem segment wraca do puli / then returns

# --- Podzial nagrody / reward split (suma = 100) ---
SPLIT_FINDER = 40              # [PL] znalazca / [EN] finder
SPLIT_OWNER  = 5               # [PL] operator (Ty) / [EN] operator (you)
SPLIT_MINERS = 55              # [PL] reszta wg wkladu / [EN] rest by contribution


# ============================================================
# Dashboard HTML (jeden plik, ZERO zaleznosci - czysty HTML+CSS+JS)
# Pobiera dane z /stats co 3s. Pasek postepu, leaderboard, ETA, live.
# ============================================================
_DASH_HEAD = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GPU Puzzle Pool</title>
<style>
  :root{--bg:#0b0e14;--card:#141a24;--acc:#f7931a;--acc2:#00d68f;--txt:#e6edf3;--dim:#8b98a5;--red:#e74c3c;}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--txt);font-family:'Segoe UI',system-ui,sans-serif;min-height:100vh}
  .container{max-width:1100px;margin:0 auto;padding:20px}
  .hero{background:linear-gradient(135deg,#141a24 0%,#1a2332 100%);border-radius:20px;
        padding:30px;border:1px solid #1f2733;margin-bottom:20px;text-align:center}
  .hero h1{font-size:2.2rem;margin-bottom:4px}
  .hero h1 .btc{color:var(--acc)}
  .hero .sub{color:var(--dim);font-size:.9rem;margin-bottom:16px}
  .hero .big{font-size:2.8rem;font-weight:800;color:var(--acc);margin:8px 0 4px}
  .hero .big2{font-size:2.2rem;font-weight:700;color:var(--acc2);margin:4px 0}
  .hero .lbl{color:var(--dim);font-size:.85rem;text-transform:uppercase;letter-spacing:1px}
  .barwrap{background:#0b0e14;border-radius:12px;height:28px;overflow:hidden;border:1px solid #1f2733;position:relative;margin:10px 0}
  .bar{background:linear-gradient(90deg,var(--acc),#ffb84d);height:100%;width:0;transition:width .6s ease}
  .bartext{position:absolute;left:10px;top:50%;transform:translateY(-50%);font-weight:700;font-size:.8rem;
           color:var(--txt);text-shadow:0 0 4px #000}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:16px}
  .card{background:var(--card);border-radius:14px;padding:16px 18px;border:1px solid #1f2733}
  .card .lbl{color:var(--dim);font-size:.75rem;text-transform:uppercase;letter-spacing:.5px}
  .card .val{font-size:1.5rem;font-weight:700;margin-top:4px}
  .card .val.acc{color:var(--acc)}
  .card .val.acc2{color:var(--acc2)}
  table{width:100%;border-collapse:collapse;background:var(--card);border-radius:14px;overflow:hidden;margin-bottom:16px}
  th,td{padding:10px 12px;text-align:left;border-bottom:1px solid #1f2733;font-size:.9rem}
  th{color:var(--dim);font-size:.72rem;text-transform:uppercase;letter-spacing:.5px}
  td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
  tr:last-child td{border-bottom:none}
  .rank{color:var(--acc);font-weight:700}
  .section-title{font-size:1.1rem;margin:18px 0 10px;display:flex;align-items:center;gap:10px}
  .split{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0}
  .chip{background:#0b0e14;border:1px solid #1f2733;border-radius:20px;padding:4px 12px;font-size:.8rem}
  .chip b{color:var(--acc)}
  .live{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--acc2);margin-right:5px;
        animation:pulse 1.4s infinite}
  @keyframes pulse{0%{opacity:1}50%{opacity:.3}100%{opacity:1}}
  .gold{background:linear-gradient(90deg,#f7931a,#ffd700,#fff3c4,#ffd700,#f7931a);
        background-size:200% auto;-webkit-background-clip:text;background-clip:text;
        -webkit-text-fill-color:transparent;color:transparent;animation:shine 3s linear infinite;font-weight:800}
  @keyframes shine{to{background-position:200% center}}
  .keyspct{font-size:1.3rem;font-weight:700;color:var(--acc2);margin-top:2px}
  .probbig{font-size:1.7rem;margin-top:4px}
  .hit{background:#0d2b1e;border:1px solid var(--acc2);color:var(--acc2);padding:12px 16px;border-radius:12px;
       margin-bottom:16px;font-weight:700;display:none;font-size:.9rem}
  .ticker{background:var(--card);border:1px solid #1f2733;border-radius:12px;padding:10px 16px;margin:16px 0;
          overflow:hidden;white-space:nowrap;position:relative}
  .ticker-inner{display:inline-block;animation:scroll 30s linear infinite;color:var(--dim);font-size:.8rem;
                font-family:monospace}
  @keyframes scroll{0%{transform:translateX(0)}100%{transform:translateX(-50%)}}
  .foot{color:var(--dim);font-size:.8rem;margin-top:20px;line-height:1.6;text-align:center}
  code{background:#0b0e14;padding:2px 7px;border-radius:6px;color:var(--acc);font-size:.85rem}
  .btn{display:inline-block;padding:8px 20px;border-radius:10px;border:none;cursor:pointer;
       font-weight:600;font-size:.85rem;text-decoration:none}
  .btn.acc{background:var(--acc);color:#000}
  .btn.dim{background:#1f2733;color:var(--txt)}
  .btn.outline{background:transparent;border:1px solid #1f2733;color:var(--txt)}
  .tab-bar{display:flex;gap:6px;margin-bottom:12px}
  .tab{background:var(--card);border:1px solid #1f2733;border-radius:10px;padding:8px 16px;cursor:pointer;
       font-size:.85rem;color:var(--dim);transition:.2s}
  .tab.active{background:var(--acc);color:#000;border-color:var(--acc);font-weight:600}
  .tab:hover{background:#1f2733;color:var(--txt)}
  .modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.7);
         z-index:100;align-items:center;justify-content:center}
  .modal.show{display:flex}
  .modal-box{background:var(--card);border-radius:16px;padding:28px;max-width:400px;width:90%;border:1px solid #1f2733}
  .modal-box h2{margin-bottom:16px}
  .modal-box input{width:100%;padding:10px 14px;border-radius:10px;border:1px solid #1f2733;
                   background:#0b0e14;color:var(--txt);font-size:.9rem;margin-bottom:10px;outline:none}
  .modal-box input:focus{border-color:var(--acc)}
  .modal-box .err{color:var(--red);font-size:.8rem;margin-bottom:8px;display:none}
  .panel{background:var(--card);border-radius:14px;padding:20px;border:1px solid #1f2733;margin-bottom:16px;display:none}
  .panel .row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #1f2733}
  .panel .row:last-child{border:none}
  .panel .row .l{color:var(--dim);font-size:.85rem}
  .panel .row .r{font-weight:600;font-size:.85rem;text-align:right}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
  .dot.green{background:var(--acc2)}
  .dot.red{background:var(--red)}
</style>
</head>
"""

_DASH_BODY = r"""<body>
<div class="container">

  <div class="hero">
    <div class="sub"><span class="live"></span><span id="mode">...</span> &middot; auto-refresh 3s</div>
    <h1><span class="btc">&#8383;</span> GPU Puzzle Pool</h1>
    <div class="lbl" style="margin-top:12px">Keys searched</div>
    <div class="big" id="keys">0</div>
    <div class="keyspct" id="keyspct">0%</div>
    <div class="lbl" style="margin-top:10px">Round progress</div>
    <div class="barwrap"><div class="bartext" id="bartext"></div><div class="bar" id="bar"></div></div>
    <div class="lbl" style="margin-top:12px">Probability of finding the key this second</div>
    <div class="gold probbig" id="prob">calculating...</div>
  </div>

  <div class="hit" id="hit">&#127881; ADDRESS FOUND!</div>

  <div class="grid">
    <div class="card"><div class="lbl">Active miners</div><div class="val acc2" id="workers">0</div></div>
    <div class="card"><div class="lbl">Speed</div><div class="val" id="rate">0</div></div>
    <div class="card"><div class="lbl">ETA (this round)</div><div class="val" id="eta">-</div></div>
    <div class="card"><div class="lbl">Total mining time</div><div class="val" id="uptime">-</div></div>
  </div>
  <div class="split" id="split"></div>

  <div style="display:flex;gap:10px;margin-bottom:16px;justify-content:flex-end">
    <button class="btn outline" id="btnLogin" onclick="showModal('loginModal')">Login</button>
    <button class="btn acc" id="btnRegister" onclick="showModal('regModal')">Register</button>
    <button class="btn dim" id="btnLogout" style="display:none" onclick="doLogout()">Logout</button>
  </div>

  <div class="panel" id="panel">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
      <h2 style="font-size:1.1rem">&#128100; <span id="pNick">-</span></h2>
      <span class="dot" id="pStatus"></span>
    </div>
    <div class="row"><span class="l">Bitcoin address</span><span class="r" id="pAddr">-</span></div>
    <div class="row"><span class="l">Total keys scanned</span><span class="r" id="pKeys">0</span></div>
    <div class="row"><span class="l">Pool share</span><span class="r" id="pShare">0%</span></div>
    <div class="row"><span class="l">Speed</span><span class="r" id="pSpeed">0</span></div>
    <div class="row"><span class="l">Worker</span><span class="r" id="pWorkerCfg" style="font-size:.75rem;font-family:monospace">-</span></div>
  </div>

  <div class="section-title">&#127942; Leaderboard <span style="font-size:.8rem;color:var(--dim);font-weight:400">(<span id="lbCount">0</span> miners)</span></div>

  <table>
    <thead><tr><th>#</th><th>Miner</th><th class="num">Keys</th><th class="num">Segments</th><th class="num">Share</th><th class="num">Reward</th></tr></thead>
    <tbody id="lb"><tr><td colspan="6" style="color:var(--dim)">Loading...</td></tr></tbody>
  </table>

  <div class="ticker"><div class="ticker-inner" id="ticker">Loading events...</div></div>

  <div class="foot" id="foot"></div>
</div>

<div class="modal" id="loginModal">
  <div class="modal-box"><h2>Login</h2><div class="err" id="loginErr"></div>
    <input id="loginNick" placeholder="Nickname" autocomplete="off">
    <input id="loginPass" type="password" placeholder="Password">
    <button class="btn acc" style="width:100%;margin-top:6px" onclick="doLogin()">Login</button>
    <button class="btn outline" style="width:100%;margin-top:6px" onclick="closeModal('loginModal')">Cancel</button>
  </div>
</div>

<div class="modal" id="regModal">
  <div class="modal-box"><h2>Register</h2><div class="err" id="regErr"></div>
    <input id="regNick" placeholder="Nickname (public)" autocomplete="off">
    <input id="regAddr" placeholder="Bitcoin address (for rewards)" autocomplete="off">
    <input id="regPass" type="password" placeholder="Password">
    <input id="regPass2" type="password" placeholder="Confirm password">
    <button class="btn acc" style="width:100%;margin-top:6px" onclick="doRegister()">Register</button>
    <button class="btn outline" style="width:100%;margin-top:6px" onclick="closeModal('regModal')">Cancel</button>
  </div>
</div>
"""

_DASH_JS = r"""<script>
var T=localStorage.getItem('pool_token')||null,W=localStorage.getItem('pool_worker')||null;
function fmt(n){if(n>=1e12)return(n/1e12).toFixed(2)+' T';if(n>=1e9)return(n/1e9).toFixed(2)+' G';
  if(n>=1e6)return(n/1e6).toFixed(2)+' M';if(n>=1e3)return(n/1e3).toFixed(2)+' k';return(n||0).toFixed(0);}
function eta(s){if(s==null)return'&mdash;';if(s<60)return s+'s';var m=Math.floor(s/60),h=Math.floor(m/60),d=Math.floor(h/24);
  if(d>0)return d+'d '+(h%24)+'h';if(h>0)return h+'h '+(m%60)+'m';return m+'m';}
function showModal(i){document.getElementById(i).classList.add('show');}
function closeModal(i){document.getElementById(i).classList.remove('show');}
function switchMode(m){
  var t=document.querySelectorAll('.tab');
  for(var i=0;i<t.length;i++){t[i].classList.toggle('active',t[i].dataset.mode===m);}
  var labels={'puzzle':'Puzzle #71 (70-71 bits)','wallets':'Forgotten wallets (253-256 bits)'};
  document.getElementById('mode').textContent=labels[m]||m;}
function se(id,m){var e=document.getElementById(id);e.textContent=m;e.style.display='block';setTimeout(function(){e.style.display='none';},4000);}
async function doRegister(){
  var n=document.getElementById('regNick').value.trim(),a=document.getElementById('regAddr').value.trim(),
      p1=document.getElementById('regPass').value,p2=document.getElementById('regPass2').value;
  if(!n||!a||!p1)return se('regErr','All fields required');if(p1!==p2)return se('regErr','Passwords mismatch');
  try{var r=await fetch('/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nick:n,addr:a,pass:p1})});
  var d=await r.json();if(d.ok){closeModal('regModal');alert('Account created! You can now login.');}
  else se('regErr',d.error||'Failed');}catch(e){se('regErr','Network error');}}
async function doLogin(){
  var n=document.getElementById('loginNick').value.trim(),p=document.getElementById('loginPass').value;
  if(!n||!p)return se('loginErr','All fields required');
  try{var r=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nick:n,pass:p})});
  var d=await r.json();if(d.ok){T=d.token;W=n;localStorage.setItem('pool_token',T);localStorage.setItem('pool_worker',W);closeModal('loginModal');}
  else se('loginErr',d.error||'Failed');}catch(e){se('loginErr','Network error');}}
function doLogout(){T=null;W=null;localStorage.removeItem('pool_token');localStorage.removeItem('pool_worker');
  document.getElementById('panel').style.display='none';document.getElementById('btnLogin').style.display='';
  document.getElementById('btnRegister').style.display='';document.getElementById('btnLogout').style.display='none';}
async function tick(){
  try{
    var r=await fetch('/stats',{cache:'no-store'});var d=await r.json();
    if(window._firstTick){switchMode(d.mode);window._firstTick=false;}
    var p=d.round_progress_pct||0;
    document.getElementById('keys').textContent=fmt(d.total_keys_done||0);
    document.getElementById('keyspct').textContent=p.toFixed(4)+'%';
    document.getElementById('bar').style.width=Math.max(p,0.5)+'%';
    document.getElementById('bartext').innerHTML=fmt(d.round_done_chunks)+' / '+fmt(d.round_total_chunks)+' chunks';
    document.getElementById('workers').textContent=d.active_workers||0;
    document.getElementById('rate').innerHTML=fmt(d.keys_per_sec||0)+' <span style="font-size:.9rem;color:var(--dim)">kl/s</span>';
    document.getElementById('eta').innerHTML=eta(d.eta_seconds);
    var tr=Math.pow(2,d.end_bit)-Math.pow(2,d.start_bit),sk=d.total_keys_done||0;
    var pb=tr>0?(sk/tr)*100:0;
    document.getElementById('prob').textContent=pb.toFixed(10)+' %';
    var sp=d.split||{};document.getElementById('split').innerHTML=
      '<div class="chip">Finder <b>'+sp.finder_pct+'%</b></div><div class="chip">Miners <b>'+sp.miners_pool_pct+'%</b></div>'+
      '<div class="chip">Operator <b>'+sp.owner_pct+'%</b></div><div class="chip">Segments <b>'+d.segments_done+'</b></div><div class="chip">Hits <b>'+d.hits+'</b></div>';
    var lb=document.getElementById('lb');
    if(!d.miners||!d.miners.length){lb.innerHTML='<tr><td colspan="6" style="color:var(--dim)">No miners yet</td></tr>';}
    else{lb.innerHTML=d.miners.map(function(m,i){return '<tr><td class="rank">'+(i+1)+'</td><td>'+
      String(m.worker).replace(/[<>]/g,'')+'</td><td class="num">'+fmt(m.keys_done)+'</td><td class="num">'+m.segments+'</td><td class="num">'+
      m.share_of_miners_pct.toFixed(2)+'%</td><td class="num">'+m.reward_pct_of_total.toFixed(2)+'%</td></tr>';}).join('');}
    document.getElementById('lbCount').textContent=d.miners?d.miners.length:0;
    if(d.hits&&d.hits>0){var h=document.getElementById('hit');h.style.display='block';
      var hl='&#127881; ADDRESS FOUND! ('+d.hits+')<br>';
      if(d.recent_hits&&d.recent_hits.length)hl+=d.recent_hits.map(function(x){
        return 'Addr: <code>'+String(x.addr).replace(/[<>]/g,'')+'</code>';}).join('<br>');
      h.innerHTML=hl+'<br><span style="font-size:.85rem">Key safe (not shown).</span>';}
    document.getElementById('foot').innerHTML='Join: <code>python3 pool_worker --server '+location.origin+' --worker YOUR_NICK --binary ./fastscan</code>'+
    '<br><a href="https://t.me/+39k4WcVDfYhiMWFk" target="_blank" style="color:var(--acc);text-decoration:none">&#128172; TG Group</a>';
    if(T&&W){
      try{
        var r2=await fetch('/miner?token='+T,{cache:'no-store'});var d2=await r2.json();
        if(d2.ok){var pn=document.getElementById('panel');pn.style.display='block';
          document.getElementById('pNick').textContent=d2.nick;
          document.getElementById('pAddr').textContent=d2.addr||'';
          document.getElementById('pKeys').textContent=fmt(d2.keys_done||0);
          document.getElementById('pShare').textContent=(d2.share_pct||0).toFixed(3)+'%';
          document.getElementById('pSpeed').textContent=fmt(d2.speed||0)+' kl/s';
          document.getElementById('pWorkerCfg').innerHTML='Rank: #'+d2.rank+' / '+d2.total_miners+'<br>Active: '+eta(d2.active_secs)+'<br>Registered: '+(d2.registered_at?new Date(d2.registered_at*1000).toISOString().split('T')[0]:'-');
          var s=document.getElementById('pStatus');s.className='dot '+(d2.online?'green':'red');
          document.getElementById('btnLogin').style.display='none';
          document.getElementById('btnRegister').style.display='none';
          document.getElementById('btnLogout').style.display='';
        }else{doLogout();}
      }catch(e){}
    }
  }catch(e){}
}
window._firstTick=true;tick();setInterval(tick,3000);
</script></body></html>"""

DASHBOARD_HTML = _DASH_HEAD + _DASH_BODY + _DASH_JS


# ============================================================
# Baza danych / database
# ============================================================
def db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db(mode, puzzle_addr, scan_target, scan_mode, start_bit, end_bit, secret_hex, Sx, Sy):
    conn = db(); c = conn.cursor()
    c.execute("CREATE TABLE IF NOT EXISTS config (k TEXT PRIMARY KEY, v TEXT)")
    c.execute("""CREATE TABLE IF NOT EXISTS segments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        round INTEGER, chunk_from INTEGER, chunk_to INTEGER,
        status TEXT, worker TEXT, leased_at REAL, done_at REAL,
        keys_done INTEGER DEFAULT 0)""")
    c.execute("""CREATE TABLE IF NOT EXISTS contrib (
        worker TEXT PRIMARY KEY, keys_done INTEGER DEFAULT 0, segments INTEGER DEFAULT 0)""")
    c.execute("""CREATE TABLE IF NOT EXISTS shares (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        worker TEXT, share_d TEXT, full_key TEXT, addr TEXT, match INTEGER, ts REAL)""")
    c.execute("""CREATE TABLE IF NOT EXISTS miners (
        nick TEXT PRIMARY KEY, addr TEXT, pass_hash TEXT, salt TEXT,
        token TEXT, registered_at REAL, last_seen REAL)""")
    c.execute("""CREATE TABLE IF NOT EXISTS banned (
        worker TEXT PRIMARY KEY, reason TEXT, banned_at REAL, banned_until REAL)""")
    # [PL] Tabela do sledzenia pustych share'y per worker (anty-spam)
    # [EN] Table for tracking empty shares per worker (anti-spam)
    c.execute("""CREATE TABLE IF NOT EXISTS empty_share_log (
        worker TEXT, ts REAL, segment_id INTEGER)""")
    c.execute("""CREATE INDEX IF NOT EXISTS idx_empty_ts ON empty_share_log(ts)""")

    def setcfg(k, v):
        c.execute("INSERT OR REPLACE INTO config (k,v) VALUES (?,?)", (k, str(v)))

    # [PL] mode: "puzzle" (jeden adres) lub "wallets" (baza .bin, tysiace adresow)
    # [EN] mode: "puzzle" (single address) or "wallets" (.bin DB, thousands of addresses)
    setcfg("mode", mode)
    setcfg("puzzle_addr", puzzle_addr)   # [PL] puzzle: adres celu; wallets: "" / [EN] puzzle: target addr; wallets: ""
    setcfg("scan_target", scan_target)   # [PL] argv[1] binarki: adres (puzzle) lub nazwa .bin (wallets)
                                         # [EN] binary argv[1]: address (puzzle) or .bin filename (wallets)
    setcfg("scan_mode", scan_mode)       # [PL] comp|uncomp|both / [EN] comp|uncomp|both
    setcfg("start_bit", start_bit)
    setcfg("end_bit", end_bit)
    setcfg("secret_s", secret_hex)   # [PL] TAJNE! / [EN] SECRET!
    setcfg("offset_sx", Sx)
    setcfg("offset_sy", Sy)
    setcfg("next_round", 1)
    setcfg("next_chunk", 0)
    conn.commit(); conn.close()


def getcfg(c, k):
    r = c.execute("SELECT v FROM config WHERE k=?", (k,)).fetchone()
    return r["v"] if r else None


def chunks_in_round(round_idx):
    # [PL] runda r ma 3563*2^(r-1) chunkow / [EN] round r has 3563*2^(r-1) chunks
    return INITIAL_CHUNKS * (2 ** (round_idx - 1))


# ============================================================
# Logika rozdzialu / distribution logic
# ============================================================
def reclaim_expired(c):
    # [PL] segmenty z wygasla dzierzawa wracaja do puli
    # [EN] segments with expired lease return to the pool
    now = time.time()
    c.execute("""UPDATE segments SET status='PENDING', worker=NULL, leased_at=NULL
                 WHERE status='ASSIGNED' AND leased_at IS NOT NULL AND (? - leased_at) > ?""",
              (now, LEASE_SECONDS))


def _adaptive_size(c, worker, default_size):
    # [PL] Oblicza ile chunkow dac temu workerowi na podstawie czasu ostatniego
    #      ukonczonego segmentu. Cel: kazdy segment trwa ~SEGMENT_TARGET s.
    #      Dla RTX 4090 (szybki) da wiecej, dla GTX 1050 (wolny) mniej.
    # [EN] Calculates how many chunks to give this worker based on their last
    #      completed segment time. Goal: each segment takes ~SEGMENT_TARGET s.
    #      RTX 4090 (fast) gets more, GTX 1050 (slow) gets less.
    row = c.execute("""SELECT chunk_to, chunk_from, done_at, leased_at FROM segments
                       WHERE worker=? AND status='DONE' AND done_at IS NOT NULL
                       AND leased_at IS NOT NULL AND done_at > leased_at
                       ORDER BY id DESC LIMIT 1""", (worker,)).fetchone()
    if not row:
        return default_size  # [PL] brak historii -> domyslny / [EN] no history -> default
    duration = row["done_at"] - row["leased_at"]
    if duration <= 0:
        return default_size
    # [PL] chunkow w ostatnim segmencie / [EN] chunks in last segment
    chunks_done = row["chunk_to"] - row["chunk_from"]
    # [PL] ekstrapolacja: tyle chunkow zeby trwalo SEGMENT_TARGET sekund
    # [EN] extrapolate: chunk count to hit SEGMENT_TARGET seconds
    opt = int(chunks_done * SEGMENT_TARGET / duration)
    opt = max(SEGMENT_MIN, min(SEGMENT_MAX, opt))
    return opt


def next_segment(c, worker):
    reclaim_expired(c)
    # 1) [PL] najpierw wznow porzucone / [EN] first resume abandoned
    row = c.execute("SELECT * FROM segments WHERE status='PENDING' ORDER BY round, chunk_from LIMIT 1").fetchone()
    if row:
        c.execute("UPDATE segments SET status='ASSIGNED', worker=?, leased_at=? WHERE id=?",
                  (worker, time.time(), row["id"]))
        return dict(row)
    # 2) [PL] nowy segment z biezacej rundy / [EN] new segment from current round
    nr = int(getcfg(c, "next_round"))
    ncur = int(getcfg(c, "next_chunk"))
    total = chunks_in_round(nr)
    if ncur >= total:
        nr += 1; ncur = 0; total = chunks_in_round(nr)
        c.execute("INSERT OR REPLACE INTO config (k,v) VALUES ('next_round',?)", (str(nr),))
    # [PL] adaptacyjny rozmiar wg mocy GPU / [EN] adaptive size by GPU power
    seg_size = _adaptive_size(c, worker, SEGMENT_SIZE)
    cfrom = ncur
    cto = min(ncur + seg_size, total)
    c.execute("INSERT OR REPLACE INTO config (k,v) VALUES ('next_chunk',?)", (str(cto),))
    c.execute("""INSERT INTO segments (round, chunk_from, chunk_to, status, worker, leased_at)
                 VALUES (?,?,?,'ASSIGNED',?,?)""", (nr, cfrom, cto, worker, time.time()))
    return {"id": c.lastrowid, "round": nr, "chunk_from": cfrom, "chunk_to": cto}


# ============================================================
# [PL] System banowania i walidacji share'y / Ban & share validation
# [EN] Ban system and share validation
# ============================================================
def is_worker_banned(c, worker):
    """[PL] Sprawdza czy worker jest zbanowany (ban nie wygasl).
    [EN] Checks if worker is banned (ban not expired)."""
    now = time.time()
    row = c.execute("SELECT reason, banned_until FROM banned WHERE worker=?", (worker,)).fetchone()
    if not row:
        return False
    if row["banned_until"] and row["banned_until"] > now:
        return True
    # ban wygasl -> usun / expired -> remove
    if row["banned_until"] and row["banned_until"] <= now:
        c.execute("DELETE FROM banned WHERE worker=?", (worker,))
        return False
    return True  # permanent ban (banned_until = NULL)


def ban_worker(c, worker, reason, duration_hours=24):
    """[PL] Banuje workera na X godzin (lub permanentnie jesli 0).
    [EN] Bans worker for X hours (or permanently if 0)."""
    until = time.time() + duration_hours * 3600 if duration_hours > 0 else None
    c.execute("INSERT OR REPLACE INTO banned (worker, reason, banned_at, banned_until) VALUES (?,?,?,?)",
              (worker, reason, time.time(), until))
    print(f"[PL] ZBANOWANO: {worker} | powod: {reason} | do: {until or 'PERMANENTNIE'}")
    print(f"[EN] BANNED: {worker} | reason: {reason} | until: {until or 'PERMANENTLY'}")


def validate_share_d(share_d):
    """[PL] Waliduje share_d: niepusty, tylko hex (0-9a-fA-F), nie zero, >0
    [EN] Validates share_d: non-empty, hex-only (0-9a-fA-F), non-zero, >0."""
    if share_d is None:
        return False, "share_d is null"
    if not isinstance(share_d, str):
        return False, "share_d is not a string"
    share_d = share_d.strip()
    if not share_d:
        return False, "Empty share_d"
    # [PL] Jawna walidacja tylko znakow hex / [EN] Explicit hex-only validation
    import re
    if not re.fullmatch(r'[0-9a-fA-F]+', share_d):
        return False, f"Non-hex characters in share_d: {share_d[:30]}"
    try:
        d = int(share_d, 16)
    except ValueError:
        return False, f"Invalid hex: {share_d[:30]}"
    if d == 0:
        return False, "Zero share_d (invalid)"
    if len(share_d) > 128:  # max 64 bajty = 128 znakow hex
        return False, f"Share too long: {len(share_d)} chars"
    return True, None


def log_empty_share(c, worker, segment_id):
    """[PL] Loguje pusty/nieprawidlowy share i sprawdza progi.
    Zwraca liste krotek (trigger, count). Moze byc wiele naraz (reassign + ban).
    [EN] Logs empty/invalid share and checks thresholds.
    Returns list of (trigger, count) tuples. Multiple triggers possible at once."""
    now = time.time()
    c.execute("INSERT INTO empty_share_log (worker, ts, segment_id) VALUES (?,?,?)",
              (worker, now, segment_id))

    triggers = []

    # [PL] sprawdz burst (krotkie okno) / [EN] check burst (short window)
    cutoff = now - SHARE_BURST_WINDOW
    burst_count = c.execute(
        "SELECT COUNT(*) n FROM empty_share_log WHERE worker=? AND ts > ?",
        (worker, cutoff)).fetchone()["n"]
    if burst_count >= SHARE_BURST_MAX:
        triggers.append(("burst", burst_count))

    # [PL] sprawdz ile pustych z rzedu od tego workera (do bana)
    # [EN] check consecutive empties from this worker (for ban)
    consec = c.execute(
        "SELECT COUNT(*) n FROM (SELECT 1 FROM empty_share_log WHERE worker=? "
        "ORDER BY ts DESC LIMIT ?)",
        (worker, EMPTY_SHARE_BAN_THRESHOLD + 1)).fetchone()["n"]
    if consec >= EMPTY_SHARE_BAN_THRESHOLD:
        triggers.append(("consecutive", consec))

    # [PL] sprawdz ile pustych dla TEGO segmentu od TEGO workera (do reassign)
    # [EN] check empties for THIS segment from THIS worker (for reassign)
    if segment_id:
        segment_empties = c.execute(
            "SELECT COUNT(*) n FROM empty_share_log WHERE worker=? AND segment_id=?",
            (worker, segment_id)).fetchone()["n"]
        if segment_empties >= EMPTY_SHARE_REASSIGN_THRESHOLD:
            triggers.append(("reassign", segment_empties))

    return triggers
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # cichy / quiet

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n).decode()) if n else {}

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            return self.handle_dashboard()
        if self.path.startswith("/work"):   return self.handle_work()
        if self.path.startswith("/stats"):  return self.handle_stats()
        if self.path.startswith("/config"): return self.handle_config()
        if self.path.startswith("/miner"):   return self.handle_miner()
        if self.path.startswith("/miners"):  return self.handle_miners()
        if self.path.startswith("/hits"):    return self.handle_hits()
        return self._send(404, {"error": "not found / nie znaleziono"})

    # --- /hits : lista wszystkich trafien (dla operatora) / all hits (operator) ---
    def handle_hits(self):
        conn = db(); c = conn.cursor()
        rows = c.execute("""SELECT s.worker, s.share_d, s.addr, s.match, s.ts
                            FROM shares s WHERE s.match=1
                            ORDER BY s.ts DESC""").fetchall()
        out = []
        for r in rows:
            # adres BTC kopacza / miner's BTC address
            m = c.execute("SELECT addr FROM miners WHERE nick=?", (r["worker"],)).fetchone()
            btc = m["addr"] if m else ""
            out.append({
                "worker": r["worker"],
                "miner_btc_addr": btc,
                "addr_found": r["addr"],
                "ts": r["ts"],
            })
        conn.close()
        self._send(200, {"hits": out})

    # --- /miners : lista wszystkich kopaczy (dla operatora) / all miners list (operator) ---
    def handle_miners(self):
        conn = db(); c = conn.cursor()
        rows = c.execute("SELECT nick, addr, registered_at FROM miners ORDER BY registered_at").fetchall()
        out = []
        for r in rows:
            cr = c.execute("SELECT keys_done, segments FROM contrib WHERE worker=?", (r["nick"],)).fetchone()
            keys = cr["keys_done"] if cr else 0
            segs = cr["segments"] if cr else 0
            # czy znalazl cos / found anything?
            hits = c.execute("SELECT COUNT(*) n FROM shares WHERE match=1 AND worker=?", (r["nick"],)).fetchone()["n"]
            out.append({
                "nick": r["nick"],
                "addr": r["addr"],
                "keys_done": keys,
                "segments": segs,
                "hits": hits or 0,
            })
        conn.close()
        self._send(200, {"miners": out})

    # --- /miner?token= : panel indywidualny / individual miner panel ---
    def handle_miner(self):
        qs = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(qs)
        token = params.get("token", [None])[0]
        if not token: return self._send(400, {"ok": False, "error": "No token"})
        conn = db(); c = conn.cursor()
        row = c.execute("SELECT nick, addr, registered_at FROM miners WHERE token=?", (token,)).fetchone()
        if not row: conn.close(); return self._send(200, {"ok": False})
        nick = row["nick"]
        cr = c.execute("SELECT keys_done, segments FROM contrib WHERE worker=?", (nick,)).fetchone()
        keys_done = int(float(cr["keys_done"])) if cr else 0
        segments = cr["segments"] if cr else 0
        total = sum(int(float(r[0] or 0)) for r in c.execute("SELECT keys_done FROM contrib").fetchall()) or 1
        share_pct = keys_done / total * 100
        # ostatni segment
        spd = c.execute("""SELECT chunk_to, chunk_from, done_at, leased_at FROM segments
                           WHERE worker=? AND status='DONE' AND done_at>leased_at
                           ORDER BY id DESC LIMIT 1""", (nick,)).fetchone()
        speed = 0.0; online = False
        if spd:
            dur = spd["done_at"] - spd["leased_at"]
            if dur > 0: speed = (spd["chunk_to"] - spd["chunk_from"]) * 5_000_000 / dur
            online = (time.time() - spd["done_at"]) < 600
        # rank
        rank_row = c.execute("""SELECT COUNT(*)+1 rnk FROM contrib
                                WHERE keys_done > ?""", (keys_done,)).fetchone()
        rank = rank_row["rnk"] if rank_row else 1
        total_miners = c.execute("SELECT COUNT(*) n FROM contrib").fetchone()["n"] or 0
        # active time
        first = c.execute("""SELECT MIN(leased_at) t FROM segments
                             WHERE worker=? AND leased_at IS NOT NULL""", (nick,)).fetchone()
        active_secs = int(time.time() - first["t"]) if first and first["t"] else 0
        ad = row["addr"]; addr_short = ad[:8]+"..."+ad[-6:] if len(ad) > 16 else ad
        reg_ts = row["registered_at"] or 0
        conn.close()
        self._send(200, {
            "ok": True, "nick": nick, "addr": addr_short,
            "keys_done": keys_done, "segments": segments,
            "share_pct": share_pct, "speed": int(speed), "online": online,
            "rank": rank, "total_miners": total_miners,
            "active_secs": active_secs, "registered_at": reg_ts,
        })

    def _send_html(self, code, html):
        body = html.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # --- / : dashboard HTML (pasek postepu, leaderboard, ETA) ---
    def handle_dashboard(self):
        self._send_html(200, DASHBOARD_HTML)

    def do_POST(self):
        if self.path.startswith("/done"):     return self.handle_done()
        if self.path.startswith("/found"):    return self.handle_found()
        if self.path.startswith("/register"): return self.handle_register()
        if self.path.startswith("/login"):    return self.handle_login()
        return self._send(404, {"error": "not found / nie znaleziono"})

    # --- /register : rejestracja kopacza / miner registration ---
    def handle_register(self):
        data = self._read_json()
        nick = data.get("nick", "").strip()
        addr = data.get("addr", "").strip()
        password = data.get("pass", "")
        if not nick or not addr or not password:
            return self._send(400, {"ok": False, "error": "All fields required"})
        # prosta walidacja adresu BTC / basic BTC address validation
        def _valid_btc(a):
            if a[0] == "1" and 26 <= len(a) <= 35: return True
            if a[0] == "3" and 26 <= len(a) <= 35: return True
            if a.startswith("bc1") and len(a) in (42, 62): return True
            return False
        if not _valid_btc(addr):
            return self._send(400, {"ok": False, "error": "Invalid Bitcoin address"})
        with DB_LOCK:
            conn = db(); c = conn.cursor()
            exists = c.execute("SELECT nick FROM miners WHERE nick=? OR addr=?", (nick, addr)).fetchone()
            if exists:
                conn.close(); return self._send(400, {"ok": False, "error": "Nick or address already registered"})
            import hashlib, secrets
            salt = secrets.token_hex(8)
            pass_hash = hashlib.sha256((salt + password).encode()).hexdigest()
            c.execute("INSERT INTO miners (nick, addr, pass_hash, salt, registered_at, last_seen) VALUES (?,?,?,?,?,?)",
                      (nick, addr, pass_hash, salt, time.time(), 0))
            conn.commit(); conn.close()
        self._send(200, {"ok": True})

    # --- /login : logowanie (zwraca token) / login (returns token) ---
    def handle_login(self):
        data = self._read_json()
        nick = data.get("nick", "").strip()
        password = data.get("pass", "")
        if not nick or not password:
            return self._send(400, {"ok": False, "error": "All fields required"})
        import hashlib, secrets
        conn = db(); c = conn.cursor()
        row = c.execute("SELECT * FROM miners WHERE nick=?", (nick,)).fetchone()
        if not row:
            conn.close(); return self._send(400, {"ok": False, "error": "Invalid credentials"})
        h = hashlib.sha256((row["salt"] + password).encode()).hexdigest()
        if h != row["pass_hash"]:
            conn.close(); return self._send(400, {"ok": False, "error": "Invalid credentials"})
        if not row["token"]:
            token = secrets.token_hex(16)
            c.execute("UPDATE miners SET token=?, last_seen=? WHERE nick=?", (token, time.time(), nick))
        else:
            token = row["token"]
        conn.commit(); conn.close()
        self._send(200, {"ok": True, "token": token})

    # --- /config : dane publiczne dla workera / public data for the worker ---
    def handle_config(self):
        conn = db(); c = conn.cursor()
        sb = int(getcfg(c, "start_bit"))
        eb = int(getcfg(c, "end_bit"))
        secret_s_hex = getcfg(c, "secret_s")
        s = int(secret_s_hex, 16) if secret_s_hex else 0
        
        # [PL] Przesuniety zakres dla split-key: [2^sb - s, 2^eb - 1 - s] mod N
        # [EN] Shifted range for split-key: [2^sb - s, 2^eb - 1 - s] mod N
        R0_orig = (1 << sb)
        R1_orig = (1 << eb) - 1
        shifted_lo = (R0_orig - s) % sk.N
        shifted_hi = (R1_orig - s) % sk.N
        
        out = {
            "mode": getcfg(c, "mode") or "puzzle",
            "puzzle_addr": getcfg(c, "puzzle_addr"),
            "scan_target": getcfg(c, "scan_target"),   # [PL] argv[1] binarki / [EN] binary argv[1]
            "scan_mode": getcfg(c, "scan_mode") or "comp",
            "start_bit": sb,
            "end_bit": eb,
            "offset_sx": getcfg(c, "offset_sx"),   # publiczny / public
            "offset_sy": getcfg(c, "offset_sy"),   # publiczny / public
            # [PL] Przesuniety zakres (split-key fix): worker skanuje d w [shifted_lo, shifted_hi]
            # [EN] Shifted range (split-key fix): worker scans d in [shifted_lo, shifted_hi]
            "shifted_lo": "%064x" % shifted_lo,
            "shifted_hi": "%064x" % shifted_hi,
        }
        conn.close(); self._send(200, out)

    # --- /work : przydziel segment / assign a segment ---
    def handle_work(self):
        from urllib.parse import urlparse, parse_qs
        q = parse_qs(urlparse(self.path).query)
        worker = q.get("worker", ["anon"])[0]
        token = q.get("token", [None])[0]
        # [PL] Autoryzacja: jesli worker jest ZAREJESTROWANY, musi podac wazny token.
        #      Niezarejestrowane nicki dzialaja bez tokenu (kompatybilnosc).
        # [EN] Auth: if the worker nick IS registered, a valid token is required.
        #      Unregistered nicks work without a token (backward compatible).
        conn0 = db(); c0 = conn0.cursor()
        reg = c0.execute("SELECT token FROM miners WHERE nick=?", (worker,)).fetchone()
        # [PL] Sprawdz czy worker jest zbanowany / [EN] Check if worker is banned
        banned = is_worker_banned(c0, worker)
        if banned:
            reason = c0.execute("SELECT reason FROM banned WHERE worker=?", (worker,)).fetchone()
            reason_str = reason["reason"] if reason else "Spam / empty shares"
            conn0.close()
            return self._send(403, {
                "error": f"BANNED: {reason_str}. / ZBANOWANY: {reason_str}.",
                "banned": True
            })
        conn0.close()
        if reg is not None:
            # nick zarejestrowany -> token MUSI pasowac / registered -> token MUST match
            if not token or token != reg["token"]:
                return self._send(403, {"error": "Auth required: this nick is registered. "
                                        "Use --password to log in. / Nick zarejestrowany - uzyj --password."})
        # [PL] BLOKADA: przydzial segmentu to read-modify-write na next_chunk.
        #      Bez tego dwoch kopaczy moglaby dostac ten sam zakres (duble).
        # [EN] LOCK: assignment is a read-modify-write on next_chunk. Without it
        #      two miners could receive the same range (duplicates).
        with DB_LOCK:
            conn = db(); c = conn.cursor()
            seg = next_segment(c, worker)
            conn.commit(); conn.close()
        self._send(200, {
            "segment_id": seg["id"], "round": seg["round"],
            "chunk_from": seg["chunk_from"], "chunk_to": seg["chunk_to"],
            "msg_pl": "Przydzielono segment. Skanuj i zglos /done.",
            "msg_en": "Segment assigned. Scan and report /done.",
        })

    # --- /done : segment zakonczony / segment finished ---
    def handle_done(self):
        data = self._read_json()
        sid = data.get("segment_id")
        worker = data.get("worker", "anon")
        keys_done = int(data.get("keys_done", 0))
        # [PL] BLOKADA: aktualizacja wkladu (contrib) to read-modify-write.
        # [EN] LOCK: contribution update is a read-modify-write.
        with DB_LOCK:
            conn = db(); c = conn.cursor()
            keys_str = str(int(keys_done))  # bez notacji naukowej
            c.execute("""UPDATE segments SET status='DONE', done_at=?, keys_done=?
                         WHERE id=? AND worker=?""", (time.time(), keys_str, sid, worker))
            c.execute("""INSERT INTO contrib (worker, keys_done, segments) VALUES (?,?,1)
                         ON CONFLICT(worker) DO UPDATE SET
                            keys_done=keys_done+?, segments=segments+1""",
                      (worker, keys_str, keys_str))
            conn.commit(); conn.close()
        self._send(200, {"ok": True, "msg_pl": "Zapisano wklad.", "msg_en": "Contribution recorded."})

    # --- /found : share d -> sklad klucza / share -> combine ---
    def handle_found(self):
        data = self._read_json()
        worker = data.get("worker", "anon")
        # [PL] Bezpieczne pobranie share_d (moze byc None/null)
        # [EN] Safe extraction of share_d (may be None/null)
        raw_share = data.get("share_d", "")
        share_d = raw_share.strip() if isinstance(raw_share, str) else ""
        segment_id = data.get("segment_id")

        # [PL] === WALIDACJA SHARE_D (anty-spam pustych kluczy) ===
        # [EN] === SHARE_D VALIDATION (anti-spam for empty keys) ===
        is_valid, err_msg = validate_share_d(share_d if share_d else None)
        if not is_valid:
            print(f"[PL] ODRZUCONO pusty/nieprawidlowy share od '{worker}': {err_msg}")
            print(f"[EN] REJECTED empty/invalid share from '{worker}': {err_msg}")
            with DB_LOCK:
                conn = db(); c = conn.cursor()
                triggers = log_empty_share(c, worker, segment_id)
                for trigger, count in triggers:
                    if trigger in ("burst", "consecutive"):
                        ban_worker(c, worker, f"Spam: {count} empty/invalid shares ({trigger})", duration_hours=24)
                    if trigger == "reassign" and segment_id:
                        c.execute("UPDATE segments SET status='PENDING', worker=NULL, leased_at=NULL WHERE id=?",
                                  (segment_id,))
                        print(f"[PL] Segment #{segment_id} wrocil do puli (puste share od {worker})")
                        print(f"[EN] Segment #{segment_id} returned to pool (empty shares from {worker})")
                conn.commit(); conn.close()
            return self._send(400, {
                "error": f"Invalid share: {err_msg}",
                "error_pl": f"Nieprawidlowy share: {err_msg}. Jesli to sie powtarza, zostaniesz zbanowany.",
                "error_en": f"Invalid share: {err_msg}. If this repeats, you will be banned."
            })

        # [PL] BLOKADA: zapis share do bazy + skladanie klucza (spojnosc).
        # [EN] LOCK: share DB write + key assembly (consistency).
        with DB_LOCK:
            conn = db(); c = conn.cursor()
            if is_worker_banned(c, worker):
                conn.close()
                return self._send(403, {"error": "BANNED / ZBANOWANY"})

            s_hex = getcfg(c, "secret_s")
            mode = getcfg(c, "mode") or "puzzle"
            puzzle_addr = getcfg(c, "puzzle_addr")
            try:
                d = int(share_d, 16); s = int(s_hex, 16)
                k = (d + s) % sk.N
                full_key = "%064x" % k
                addr_c = sk.priv_to_address(k, compressed=True)
                addr_u = sk.priv_to_address(k, compressed=False)
                if mode == "wallets":
                    match = 1
                else:
                    match = 1 if (addr_c == puzzle_addr or addr_u == puzzle_addr) else 0
            except Exception as e:
                conn.close(); return self._send(400, {"error": str(e)})

            # [PL] DEDUPLIKACJA share_d
            # [EN] DEDUP share_d
            existing = c.execute(
                "SELECT id, match FROM shares WHERE share_d=?", (share_d,)).fetchone()
            if existing:
                conn.commit(); conn.close()
                print(f"[PL] Duplikat share_d od {worker}, ignoruje. / [EN] Duplicate share_d from {worker}, ignored.")
                return self._send(200, {
                    "ok": True, "match": bool(existing["match"]), "duplicate": True,
                    "msg_pl": "Share juz zarejestrowany wczesniej.",
                    "msg_en": "Share already registered earlier."
                })

            c.execute("""INSERT INTO shares (worker, share_d, full_key, addr, match, ts)
                         VALUES (?,?,?,?,?,?)""",
                      (worker, share_d, full_key, addr_c, match, time.time()))
            conn.commit(); conn.close()
        if match:
            banner = ("!!! TRAFIENIE PORTFELA (wallets) / WALLET HIT !!!" if mode == "wallets"
                      else "!!! TRAFIENIE ZLOZONE / KEY MATCH !!!")
            print("\n" + "=" * 60)
            print("[PL/EN] " + banner)
            print(f"  worker   = {worker}")
            print(f"  share d  = {share_d}")
            print(f"  FULL KEY = {full_key}")
            print(f"  addr(c)  = {addr_c}")
            print(f"  addr(u)  = {addr_u}")
            print("=" * 60 + "\n")
            # [PL] ZAPIS TRWALY do pliku - TU SZUKASZ TRAFIENIA (obok pool.db).
            #      Plik jest dopisywany (append) i fsync-owany, by nic nie zginelo.
            # [EN] DURABLE FILE write - THIS is where you look for a hit (next to pool.db).
            try:
                with open("FOUND_KEYS.txt", "a") as fk:
                    fk.write("=" * 60 + "\n")
                    fk.write(banner + "\n")
                    fk.write(f"time     = {time.strftime('%Y-%m-%d %H:%M:%S')} UTC\n")
                    fk.write(f"mode     = {mode}\n")
                    fk.write(f"worker   = {worker}\n")
                    fk.write(f"share d  = {share_d}\n")
                    fk.write(f"FULL KEY = {full_key}   <-- [PL] PELNY KLUCZ PRYWATNY / [EN] FULL PRIVATE KEY\n")
                    fk.write(f"addr(c)  = {addr_c}\n")
                    fk.write(f"addr(u)  = {addr_u}\n")
                    fk.write("=" * 60 + "\n\n")
                    fk.flush()
                    os.fsync(fk.fileno())
            except Exception as e:
                print(f"[PL] UWAGA: nie zapisano do FOUND_KEYS.txt: {e} (klucz jest w pool.db i logu)")
            # [PL] ALERT TELEGRAM z DEDUPLIKACJA (nie spamuj tym samym adresem)
            # [EN] TELEGRAM ALERT with DEDUP (don't spam the same address)
            if notify is not None:
                try:
                    conn2 = db(); c2 = conn2.cursor()
                    dup_check = c2.execute(
                        "SELECT COUNT(*) n FROM shares WHERE addr=? AND match=1 AND id < (SELECT MAX(id) FROM shares WHERE addr=?)",
                        (addr_c, addr_c)).fetchone()["n"]
                    # Pobierz adres BTC workera do wyplaty
                    miner_btc = c2.execute("SELECT addr FROM miners WHERE nick=?", (worker,)).fetchone()
                    btc_addr = miner_btc["addr"] if miner_btc else "NIEZNANY"
                    conn2.close()
                    if dup_check == 0:
                        kind = "portfela (wallets)" if mode == "wallets" else "Puzzle"
                        notify.send(
                            f"\U0001F389 <b>TRAFIENIE {kind}!</b>\n"
                            f"worker: <code>{worker}</code>\n"
                            f"adres BTC workera: <code>{btc_addr}</code>\n"
                            f"adres (c): <code>{addr_c}</code>\n"
                            f"adres (u): <code>{addr_u}</code>\n"
                            f"tryb: {mode}\n"
                            f"\u26A0\uFE0F Klucz prywatny jest bezpieczny na serwerze "
                            f"(FOUND_KEYS.txt) - NIE wysylam go przez Telegram."
                        )
                    else:
                        print(f"[PL] Alert TG pominiety - duplikat adresu {addr_c}")
                        print(f"[EN] TG alert skipped - duplicate address {addr_c}")
                except Exception as e:
                    print(f"[PL] Alert Telegram nieudany: {e}")
        self._send(200, {
            "ok": True, "match": bool(match),
            "msg_pl": "Share odebrany." + (" TRAFIENIE!" if match else ""),
            "msg_en": "Share received." + (" MATCH!" if match else ""),
        })

    # --- /stats : ranking + podzial + postep/ETA / leaderboard + split + progress/ETA ---
    def handle_stats(self):
        conn = db(); c = conn.cursor()
        rows = c.execute("SELECT worker, keys_done, segments FROM contrib ORDER BY CAST(keys_done AS REAL) DESC").fetchall()
        total_keys = sum(int(float(r["keys_done"])) for r in rows) or 1
        active_workers = 0
        now = time.time()
        miners = []
        for r in rows:
            frac = int(float(r["keys_done"])) / total_keys
            miners.append({
                "worker": r["worker"], "keys_done": r["keys_done"], "segments": r["segments"],
                "share_of_miners_pct": round(frac * 100, 4),
                "reward_pct_of_total": round(frac * SPLIT_MINERS, 4),
            })
        done = c.execute("SELECT COUNT(*) n FROM segments WHERE status='DONE'").fetchone()["n"]
        assigned = c.execute("SELECT COUNT(*) n FROM segments WHERE status='ASSIGNED'").fetchone()["n"]
        # [PL] aktywni workerzy = maja segment ASSIGNED w ostatnich LEASE_SECONDS
        # [EN] active workers = have an ASSIGNED segment within the last LEASE_SECONDS
        aw = c.execute("""SELECT COUNT(DISTINCT worker) n FROM segments
                          WHERE status='ASSIGNED' AND leased_at IS NOT NULL AND (?-leased_at) < ?""",
                       (now, LEASE_SECONDS)).fetchone()["n"]
        active_workers = aw or 0
        # [PL] Liczba zbanowanych workerow / [EN] Banned worker count
        banned_count = c.execute("SELECT COUNT(*) n FROM banned WHERE banned_until IS NULL OR banned_until > ?",
                                 (now,)).fetchone()["n"]

        # --- postep w BIEZACEJ rundzie / progress in the CURRENT round ---
        nr = int(getcfg(c, "next_round") or 1)
        ncur = int(getcfg(c, "next_chunk") or 0)
        round_total = chunks_in_round(nr)
        round_progress_pct = round(min(ncur / round_total, 1.0) * 100, 4) if round_total else 0.0

        # --- tempo i ETA (na podstawie znacznikow czasu ukonczonych segmentow) ---
        # [PL] liczymy klucze/sekunde z ostatnich ukonczonych segmentow (okno 5 min)
        #      Minimalny czas okna: 30 sekund, zeby uniknac sztucznie zawyzonej predkosci
        # [EN] compute keys/sec from recently finished segments (5-min window)
        #      Minimum window: 30 seconds to avoid artificially inflated speed
        window = 300
        MIN_SPEED_WINDOW = 30  # [PL] minimalny czas do liczenia predkosci / [EN] min time for speed calc
        rr = c.execute("""SELECT COALESCE(SUM(keys_done),0) k,
                                 MIN(done_at) a, MAX(done_at) b, COUNT(*) n
                          FROM segments WHERE status='DONE' AND done_at IS NOT NULL AND done_at > ?""",
                       (now - window,)).fetchone()
        keys_per_sec = 0.0
        if rr and rr["n"] and rr["a"] and rr["b"] and rr["b"] > rr["a"]:
            elapsed = rr["b"] - rr["a"]
            if elapsed >= MIN_SPEED_WINDOW:
                keys_per_sec = rr["k"] / elapsed
            elif rr["k"] > 0:
                # [PL] Okno za krotkie - uzyj min 30s dla bezpiecznej estymacji
                # [EN] Window too short - use at least 30s for safe estimate
                keys_per_sec = rr["k"] / max(elapsed, MIN_SPEED_WINDOW)
        # [PL] pozostale klucze w tej rundzie (szacunek) / [EN] remaining keys this round (estimate)
        keys_per_chunk = 5_000_000
        remaining_chunks = max(round_total - ncur, 0)
        eta_seconds = int(remaining_chunks * keys_per_chunk / keys_per_sec) if keys_per_sec > 0 else None

        start_bit = int(getcfg(c, "start_bit") or 0)
        end_bit = int(getcfg(c, "end_bit") or 0)
        mode = getcfg(c, "mode") or "puzzle"
        puzzle_addr = getcfg(c, "puzzle_addr") or ""
        hits = c.execute("SELECT COUNT(*) n FROM shares WHERE match=1").fetchone()["n"]
        # [PL] Czas od pierwszego segmentu (uptime) / [EN] time since first segment
        first = c.execute("""SELECT MIN(leased_at) t FROM segments
                             WHERE status='DONE' AND leased_at IS NOT NULL""").fetchone()
        uptime_str = "-"
        if first and first["t"]:
            secs = int(now - first["t"])
            d = secs // 86400; h = (secs % 86400) // 3600; m = (secs % 3600) // 60
            if d > 0: uptime_str = f"{d}d {h}h"
            elif h > 0: uptime_str = f"{h}h {m}m"
            else: uptime_str = f"{m}m"
        # [PL] Ostatnie trafienia - TYLKO adresy (NIGDY klucz!) na strone.
        # [EN] Recent hits - ONLY addresses (NEVER the key!) for the page.
        hit_rows = c.execute("""SELECT addr, worker, ts FROM shares WHERE match=1
                                ORDER BY ts DESC LIMIT 10""").fetchall()
        recent_hits = [{"addr": r["addr"], "worker": r["worker"], "ts": r["ts"]} for r in hit_rows]
        conn.close()
        self._send(200, {
            "split": {"finder_pct": SPLIT_FINDER, "owner_pct": SPLIT_OWNER, "miners_pool_pct": SPLIT_MINERS},
            "mode": mode, "puzzle_addr": puzzle_addr,
            "start_bit": start_bit, "end_bit": end_bit,
            "round": nr, "round_total_chunks": round_total, "round_done_chunks": ncur,
            "round_progress_pct": round_progress_pct,
            "segments_done": done, "segments_assigned": assigned,
            "active_workers": active_workers,
            "banned_workers": banned_count,
            "total_keys_done": total_keys,
            "keys_per_sec": round(keys_per_sec, 1),
            "eta_seconds": eta_seconds,
            "hits": hits,
            "recent_hits": recent_hits,   # [PL] TYLKO adresy (bez klucza) / [EN] addresses ONLY (no key)
            "uptime": uptime_str,   # [PL] czas od pierwszego segmentu / [EN] time since first segment
            "miners": miners,
            "note_pl": "Pula 55% dzielona proporcjonalnie do wkladu. 40% znalazca, 5% operator.",
            "note_en": "The 55% pool is split proportionally to contribution. 40% finder, 5% operator.",
        })


# ============================================================
# CLI
# ============================================================
def cmd_init(args):
    if args.secret:
        s = int(args.secret, 16)
    else:
        s = secrets.randbelow(sk.N - 1) + 1
    Sx, Sy = sk.scalar_mul(s)

    # [PL] Ustal tryb + argv[1] (scan_target) dla binarki GPU:
    #      - puzzle : scan_target = adres celu (binarka auto-wykrywa: nie-plik => adres)
    #      - wallets: scan_target = nazwa pliku .bin z baza adresow (binarka: plik => baza + bloom)
    # [EN] Determine mode + binary argv[1] (scan_target):
    #      - puzzle : scan_target = target address (binary auto-detects: not-a-file => address)
    #      - wallets: scan_target = .bin database filename (binary: file => DB + bloom)
    if args.mode == "wallets":
        if not args.db:
            print("[PL] Tryb wallets wymaga --db <plik.bin>. / [EN] wallets mode needs --db <file.bin>.")
            sys.exit(1)
        scan_target = args.db
        puzzle_addr = ""            # [PL] brak jednego celu / [EN] no single target
        # [PL] Domyslnie 'both': stare portfele miningowe (2009-2011) sa
        #      UNCOMPRESSED, ale w bazie moga byc tez adresy compressed ->
        #      szukamy obu typow, chyba ze operator wymusi inny.
        # [EN] Default 'both': old mining wallets (2009-2011) are UNCOMPRESSED,
        #      but the DB may also hold compressed ones -> scan both types
        #      unless the operator overrides it.
        scan_mode = args.scan_mode or "both"
    else:
        if not args.address:
            print("[PL] Tryb puzzle wymaga --address <ADRES>. / [EN] puzzle mode needs --address <ADDR>.")
            sys.exit(1)
        scan_target = args.address
        puzzle_addr = args.address
        # [PL] Puzzle: domyslnie 'comp' (adresy puzzli sa compressed).
        # [EN] Puzzle: default 'comp' (puzzle addresses are compressed).
        scan_mode = args.scan_mode or "comp"

    init_db(args.mode, puzzle_addr, scan_target, scan_mode,
            args.start_bit, args.end_bit, "%064x" % s, "%064x" % Sx, "%064x" % Sy)
    print("=" * 60)
    print("[PL] Pool zainicjalizowany.  [EN] Pool initialized.")
    print(f"  mode           : {args.mode}")
    if args.mode == "wallets":
        print(f"  address DB     : {scan_target}   ([PL] tysiace adresow / [EN] thousands of addresses)")
    else:
        print(f"  puzzle address : {scan_target}")
    print(f"  scan mode      : {scan_mode}")
    print(f"  range bits     : {args.start_bit}..{args.end_bit}")
    print(f"  SECRET s       : {'%064x' % s}   <-- [PL] TRZYMAJ W TAJEMNICY / [EN] KEEP SECRET")
    print(f"  offset Sx      : {'%064x' % Sx}")
    print(f"  offset Sy      : {'%064x' % Sy}")
    print(f"  DB             : {DB_PATH}")
    print("=" * 60)


def cmd_serve(args):
    if not os.path.exists(DB_PATH):
        print("[PL] Brak pool.db - uruchom 'init'. / [EN] No pool.db - run 'init' first.")
        sys.exit(1)

    # [PL] Watek periodycznych podsumowan TG (co 4h)
    # [EN] Periodic TG summary thread (every 4h)
    def tg_summary_loop():
        SUMMARY_INTERVAL = 4 * 3600  # 4 godziny / 4 hours
        while True:
            time.sleep(SUMMARY_INTERVAL)
            if notify is None or not notify.enabled():
                continue
            try:
                conn = db(); c = conn.cursor()
                now = time.time()
                # aktywne workery / active workers
                aw = c.execute("""SELECT COUNT(DISTINCT worker) n FROM segments
                    WHERE leased_at IS NOT NULL AND (?-leased_at) < ?""",
                    (now, LEASE_SECONDS)).fetchone()["n"]
                # postep rundy / round progress
                done_cnt = c.execute("SELECT COUNT(*) n FROM segments WHERE status='DONE'").fetchone()["n"]
                assigned_cnt = c.execute("SELECT COUNT(*) n FROM segments WHERE status='ASSIGNED'").fetchone()["n"]
                total_chunks = c.execute("SELECT total_chunks FROM cfg").fetchone()
                total_chunks = total_chunks[0] if total_chunks else 1
                pct = round((done_cnt + assigned_cnt) / max(total_chunks, 1) * 100, 1)
                # trafienia w ostatnich 4h / hits in last 4h
                recent = c.execute(
                    "SELECT COUNT(*) n FROM shares WHERE match=1 AND ts > ?",
                    (now - SUMMARY_INTERVAL,)).fetchone()["n"]
                conn.close()
                msg = (
                    f"\U0001F4CA <b>Pool Status (ostatnie 4h / last 4h)</b>\n"
                    f"Aktywne workery / Active workers: <b>{aw}</b>\n"
                    f"Postep / Progress: <b>{pct}%</b> (done={done_cnt}, assigned={assigned_cnt})\n"
                    f"Trafienia / Hits: <b>{recent}</b>\n"
                )
                notify.send(msg)
            except Exception as e:
                print(f"[PL] Blad podsumowania TG: {e} / [EN] TG summary error: {e}")

    if notify and notify.enabled():
        t = threading.Thread(target=tg_summary_loop, daemon=True)
        t.start()
        print("[PL] Periodyczne podsumowania TG wlaczone (co 4h). / [EN] Periodic TG summaries enabled (every 4h).")

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"[PL] Serwer poola na http://{args.host}:{args.port}  [EN] Pool server up")
    print("  endpoints: GET /config /work /stats | POST /done /found")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[PL] Zatrzymano. / [EN] Stopped.")


def main():
    ap = argparse.ArgumentParser(description="Pool coordinator / koordynator poola (split-key)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("init", help="[PL] inicjalizuj pool / [EN] initialize pool")
    p.add_argument("--mode", choices=["puzzle", "wallets"], default="puzzle",
                   help="[PL] puzzle=jeden adres; wallets=baza .bin / [EN] puzzle=single addr; wallets=.bin DB")
    p.add_argument("--address", default=None,
                   help="[PL] adres celu (tryb puzzle) / [EN] target address (puzzle mode)")
    p.add_argument("--db", default=None,
                   help="[PL] plik bazy adresow .bin (tryb wallets) / [EN] address DB .bin file (wallets mode)")
    p.add_argument("--scan-mode", choices=["comp", "uncomp", "both"], default=None, dest="scan_mode",
                   help="[PL] comp|uncomp|both (typ adresu). Domyslnie: wallets->both (stare portfele "
                        "sa uncompressed), puzzle->comp. / [EN] comp|uncomp|both. Default: wallets->both "
                        "(old wallets are uncompressed), puzzle->comp.")
    p.add_argument("--start-bit", type=int, required=True, dest="start_bit")
    p.add_argument("--end-bit", type=int, required=True, dest="end_bit")
    p.add_argument("--secret", default=None, help="[PL] opcjonalny sekret hex / [EN] optional secret hex")
    p.set_defaults(func=cmd_init)
    p = sub.add_parser("serve", help="[PL] uruchom serwer / [EN] run server")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8080)
    p.set_defaults(func=cmd_serve)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
