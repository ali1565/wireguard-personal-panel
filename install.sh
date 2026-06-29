#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
die()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && die "باید با root اجرا شود: sudo bash install-wg-panel.sh"

SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
info "IP سرور: $SERVER_IP"

info "نصب پیش‌نیازها..."
apt-get update -qq 2>&1 | tail -2
apt-get install -y -qq curl wget nginx wireguard wireguard-tools python3 python3-pip python3-venv iproute2 iptables 2>&1 | tail -3
ok "پیش‌نیازها نصب شد"

NODE_VER=$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v' || echo 0)
if [[ $NODE_VER -lt 18 ]]; then
  info "نصب Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | tail -3
  apt-get install -y -qq nodejs 2>&1 | tail -2
fi
ok "Node.js $(node -v) آماده"

info "نصب Flask..."
python3 -m venv /opt/wg-venv
/opt/wg-venv/bin/pip install -q flask flask-cors
ok "Flask نصب شد"

info "تنظیم WireGuard..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
grep -qx "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
mkdir -p /etc/wireguard
if [[ ! -f /etc/wireguard/server_private.key ]]; then
  wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
  chmod 600 /etc/wireguard/server_private.key
  ok "کلید جدید سرور ساخته شد"
else
  warn "کلید سرور قبلاً وجود دارد — حفظ می‌شود (کانفیگ کاربران همچنان کار می‌کند)"
fi
SRV_PRIV=$(cat /etc/wireguard/server_private.key)
SRV_PUB=$(cat /etc/wireguard/server_public.key)
MAIN_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
[[ -z "$MAIN_IF" ]] && MAIN_IF="eth0"
if [[ ! -f /etc/wireguard/wg0.conf ]]; then
cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = ${SRV_PRIV}
MTU = 1420
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${MAIN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${MAIN_IF} -j MASQUERADE
WGEOF
fi

# بهینه‌سازی شبکه برای اتصال سریع‌تر
info "بهینه‌سازی شبکه..."
cat >> /etc/sysctl.conf << SYSCTLEOF
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 67108864
net.core.wmem_default = 67108864
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
SYSCTLEOF
# فعال کردن BBR
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
sysctl -p > /dev/null 2>&1
ok "بهینه‌سازی شبکه انجام شد"
systemctl enable wg-quick@wg0 > /dev/null 2>&1
systemctl restart wg-quick@wg0 2>/dev/null && ok "WireGuard wg0 فعال شد" || warn "wg0 راه‌اندازی نشد"

info "ساخت API سرور..."
mkdir -p /opt/wg-api

cat > /opt/wg-api/app.py << 'PYEOF'
#!/usr/bin/env python3
from flask import Flask, request, jsonify
from flask_cors import CORS
import subprocess, json, os, time, threading

app = Flask(__name__)
CORS(app)

DB_FILE  = "/opt/wg-api/peers.json"
CFG_FILE = "/opt/wg-api/config.json"
WG_IF    = "wg0"
BASE_IP  = "10.8.0"

def load_cfg():
    d = {"admin_pass": "admin123"}
    if os.path.exists(CFG_FILE):
        try:
            with open(CFG_FILE) as f: return {**d, **json.load(f)}
        except: pass
    return d

def save_cfg(c):
    with open(CFG_FILE, "w") as f: json.dump(c, f, indent=2)

def load_db():
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE) as f: return json.load(f)
        except: pass
    return {"peers": []}

def save_db(db):
    with open(DB_FILE, "w") as f: json.dump(db, f, indent=2)

def next_ip():
    db   = load_db()
    used = {p["ip"] for p in db["peers"]}
    for i in range(2, 255):
        ip = f"{BASE_IP}.{i}"
        if ip not in used: return ip
    return None

def gen_keypair():
    priv = subprocess.check_output(["wg","genkey"]).decode().strip()
    pub  = subprocess.check_output(["wg","pubkey"], input=priv.encode()).decode().strip()
    return priv, pub

def wg_add_peer(pubkey, ip):
    subprocess.run(["wg","set",WG_IF,"peer",pubkey,"allowed-ips",f"{ip}/32"], check=True)
    subprocess.run(["wg-quick","save",WG_IF], check=False, capture_output=True)

def wg_remove_peer(pubkey):
    subprocess.run(["wg","set",WG_IF,"peer",pubkey,"remove"], check=False, capture_output=True)
    subprocess.run(["wg-quick","save",WG_IF], check=False, capture_output=True)

def wg_active_peers():
    try:
        out = subprocess.check_output(["wg","show",WG_IF,"peers"], stderr=subprocess.DEVNULL).decode()
        return set(out.strip().split())
    except: return set()

def wg_stats():
    try:
        out = subprocess.check_output(["wg","show",WG_IF,"transfer"], stderr=subprocess.DEVNULL).decode()
        s = {}
        for line in out.strip().splitlines():
            p = line.split()
            if len(p) >= 3: s[p[0]] = int(p[1]) + int(p[2])
        return s
    except: return {}

def wg_handshakes():
    try:
        out = subprocess.check_output(["wg","show",WG_IF,"latest-handshakes"], stderr=subprocess.DEVNULL).decode()
        h = {}
        for line in out.strip().splitlines():
            p = line.split()
            if len(p) >= 2: h[p[0]] = int(p[1])
        return h
    except: return {}

def tc_apply(ip, speed_kbps):
    if speed_kbps <= 0: return
    subprocess.run(f"tc qdisc del dev {WG_IF} root 2>/dev/null", shell=True)
    subprocess.run(f"tc qdisc add dev {WG_IF} root handle 1: htb default 999", shell=True)
    subprocess.run(f"tc class add dev {WG_IF} parent 1: classid 1:999 htb rate 10000mbit", shell=True)
    mark = sum(int(x) for x in ip.split(".")) % 200 + 10
    subprocess.run(f"tc class add dev {WG_IF} parent 1: classid 1:{mark} htb rate {speed_kbps}kbit ceil {speed_kbps}kbit", shell=True)
    subprocess.run(f"tc filter add dev {WG_IF} parent 1: protocol ip prio 1 u32 match ip dst {ip}/32 flowid 1:{mark}", shell=True)

def tc_remove(ip):
    subprocess.run(f"tc qdisc del dev {WG_IF} root 2>/dev/null", shell=True)

def is_expired(peer):
    """بررسی انقضای کاربر"""
    exp = peer.get("expiresAt", 0)
    if not exp or exp <= 0: return False   # بدون تاریخ انقضا
    return int(time.time() * 1000) > exp

def check_limits():
    """قطع کاربرانی که حجمشان تمام شده یا منقضی شدند"""
    db     = load_db()
    stats  = wg_stats()
    active = wg_active_peers()
    changed = False
    now_ms  = int(time.time() * 1000)

    for p in db["peers"]:
        # بررسی انقضا
        if is_expired(p) and not p.get("expBlocked"):
            if p["pubkey"] in active:
                wg_remove_peer(p["pubkey"])
            p["expBlocked"] = True
            changed = True

        # بررسی حجم
        max_b = p.get("maxBytes", 0)
        if max_b > 0:
            used = stats.get(p["pubkey"], 0)
            if used >= max_b and not p.get("volBlocked"):
                if p["pubkey"] in active:
                    wg_remove_peer(p["pubkey"])
                p["volBlocked"] = True
                changed = True

    if changed: save_db(db)

def bg_checker():
    """بررسی هر ۶۰ ثانیه"""
    while True:
        try: check_limits()
        except: pass
        time.sleep(60)

# ── Routes ──────────────────────────────────────────

@app.route("/api/login", methods=["POST"])
def login():
    d = request.json or {}
    if d.get("password") == load_cfg()["admin_pass"]:
        return jsonify({"ok": True})
    return jsonify({"ok": False, "error": "رمز اشتباه"}), 401

@app.route("/api/change-password", methods=["POST"])
def change_password():
    d   = request.json or {}
    cfg = load_cfg()
    if d.get("current") != cfg["admin_pass"]:
        return jsonify({"error": "رمز فعلی اشتباه است"}), 401
    nw = d.get("new","").strip()
    if len(nw) < 4:
        return jsonify({"error": "حداقل ۴ کاراکتر"}), 400
    cfg["admin_pass"] = nw
    save_cfg(cfg)
    return jsonify({"ok": True})

@app.route("/api/server", methods=["GET"])
def server_info():
    pub = open("/etc/wireguard/server_public.key").read().strip()
    return jsonify({"pubkey": pub, "ip": os.environ.get("SERVER_IP",""), "port": 51820})

@app.route("/api/peers", methods=["GET"])
def get_peers():
    check_limits()
    db     = load_db()
    stats  = wg_stats()
    hs     = wg_handshakes()
    active = wg_active_peers()
    now    = int(time.time())
    out    = []
    for p in db["peers"]:
        pk    = p["pubkey"]
        used  = stats.get(pk, 0)
        last  = hs.get(pk, 0)
        is_on = pk in active and (now - last) < 180 if last > 0 else pk in active
        exp   = is_expired(p)
        out.append({**p, "usedBytes": used, "active": is_on, "lastSeen": last*1000, "expired": exp})
    return jsonify(out)

@app.route("/api/peers", methods=["POST"])
def add_peer():
    d         = request.json or {}
    name      = d.get("name","").strip()
    max_gb    = float(d.get("maxGB", 0))
    speed_k   = int(d.get("speedKbps", 0))
    expires_at = int(d.get("expiresAt", 0))   # timestamp ms, 0=بدون انقضا

    if not name: return jsonify({"error": "نام الزامی است"}), 400
    ip = next_ip()
    if not ip: return jsonify({"error": "ظرفیت IP تمام شده"}), 500

    priv, pub = gen_keypair()
    peer = {
        "id":        f"p{int(time.time()*1000)}",
        "name":      name,
        "ip":        ip,
        "privkey":   priv,
        "pubkey":    pub,
        "maxBytes":  int(max_gb * 1024**3) if max_gb > 0 else 0,
        "speedKbps": speed_k,
        "expiresAt": expires_at,
        "volBlocked": False,
        "expBlocked": False,
        "createdAt": int(time.time()*1000),
    }
    db = load_db()
    db["peers"].append(peer)
    save_db(db)

    if not is_expired(peer):
        wg_add_peer(pub, ip)
        if speed_k > 0: tc_apply(ip, speed_k)

    return jsonify(peer), 201

@app.route("/api/peers/<pid>", methods=["PUT"])
def update_peer(pid):
    db   = load_db()
    data = request.json or {}
    for p in db["peers"]:
        if p["id"] == pid:
            if "name"      in data: p["name"]      = data["name"].strip()
            if "maxGB"     in data:
                mg = float(data["maxGB"])
                p["maxBytes"] = int(mg * 1024**3) if mg > 0 else 0
                if p.get("volBlocked") and p["maxBytes"] == 0:
                    p["volBlocked"] = False
                    if not is_expired(p): wg_add_peer(p["pubkey"], p["ip"])
            if "speedKbps" in data:
                p["speedKbps"] = int(data["speedKbps"])
                if p["speedKbps"] > 0: tc_apply(p["ip"], p["speedKbps"])
                else: tc_remove(p["ip"])
            if "expiresAt" in data:
                p["expiresAt"] = int(data["expiresAt"])
                # اگه تاریخ تمدید شد و قبلاً expBlocked بود، وصل کن
                if p.get("expBlocked") and not is_expired(p):
                    p["expBlocked"] = False
                    if not p.get("volBlocked"): wg_add_peer(p["pubkey"], p["ip"])
                # اگه تاریخ جدید منقضی شد
                if is_expired(p) and not p.get("expBlocked"):
                    wg_remove_peer(p["pubkey"])
                    p["expBlocked"] = True
            save_db(db)
            return jsonify({**p, "expired": is_expired(p)})
    return jsonify({"error": "یافت نشد"}), 404

@app.route("/api/peers/<pid>", methods=["DELETE"])
def delete_peer(pid):
    db = load_db()
    p  = next((x for x in db["peers"] if x["id"] == pid), None)
    if not p: return jsonify({"error": "یافت نشد"}), 404
    wg_remove_peer(p["pubkey"])
    tc_remove(p["ip"])
    db["peers"] = [x for x in db["peers"] if x["id"] != pid]
    save_db(db)
    return jsonify({"ok": True})

@app.route("/api/peers/<pid>/toggle", methods=["POST"])
def toggle_peer(pid):
    db     = load_db()
    active = wg_active_peers()
    p      = next((x for x in db["peers"] if x["id"] == pid), None)
    if not p: return jsonify({"error": "یافت نشد"}), 404
    if p["pubkey"] in active:
        wg_remove_peer(p["pubkey"]); tc_remove(p["ip"])
        p["volBlocked"] = True
    else:
        if not is_expired(p):
            wg_add_peer(p["pubkey"], p["ip"])
            if p.get("speedKbps",0) > 0: tc_apply(p["ip"], p["speedKbps"])
        p["volBlocked"] = False
    save_db(db)
    return jsonify({"ok": True})

@app.route("/api/peers/<pid>/reset", methods=["POST"])
def reset_usage(pid):
    db = load_db()
    p  = next((x for x in db["peers"] if x["id"] == pid), None)
    if not p: return jsonify({"error": "یافت نشد"}), 404
    wg_remove_peer(p["pubkey"])
    time.sleep(0.5)
    if not is_expired(p):
        wg_add_peer(p["pubkey"], p["ip"])
        if p.get("speedKbps",0) > 0: tc_apply(p["ip"], p["speedKbps"])
    p["volBlocked"] = False
    save_db(db)
    return jsonify({"ok": True})

@app.route("/api/backup", methods=["GET"])
def backup():
    import datetime
    db  = load_db()
    now = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    srv_priv = open("/etc/wireguard/server_private.key").read().strip()
    srv_pub  = open("/etc/wireguard/server_public.key").read().strip()
    payload = {
        "version":        1,
        "createdAt":      int(time.time()*1000),
        "serverPub":      srv_pub,
        "serverPriv":     srv_priv,   # برای restore کامل روی سرور جدید
        "peers":          db["peers"],
    }
    from flask import Response
    resp = Response(
        json.dumps(payload, indent=2, ensure_ascii=False),
        mimetype="application/json",
        headers={"Content-Disposition": f"attachment; filename=wg-backup-{now}.json"}
    )
    return resp

@app.route("/api/restore", methods=["POST"])
def restore():
    try:
        data   = request.json or {}
        peers  = data.get("peers", [])
        mode   = data.get("mode", "merge")
        restore_key = data.get("restoreServerKey", False)
        if not isinstance(peers, list):
            return jsonify({"error": "فرمت نادرست"}), 400

        # اگه کلید سرور در بکاپ بود و کاربر خواست restore کنه
        if restore_key and data.get("serverPriv"):
            priv = data["serverPriv"].strip()
            if len(priv) == 44:
                pub = subprocess.check_output(["wg","pubkey"],input=priv.encode()).decode().strip()
                with open("/etc/wireguard/server_private.key","w") as f: f.write(priv+"\n")
                with open("/etc/wireguard/server_public.key","w") as f:  f.write(pub+"\n")
                import stat, re
                os.chmod("/etc/wireguard/server_private.key", stat.S_IRUSR|stat.S_IWUSR)
                with open("/etc/wireguard/wg0.conf","r") as f: conf=f.read()
                conf=re.sub(r"PrivateKey = \S+", f"PrivateKey = {priv}", conf)
                with open("/etc/wireguard/wg0.conf","w") as f: f.write(conf)
                subprocess.run(["systemctl","restart","wg-quick@wg0"],check=False)
                time.sleep(2)
        db = load_db()
        existing_ids  = {p["id"]  for p in db["peers"]}
        existing_ips  = {p["ip"]  for p in db["peers"]}
        existing_keys = {p["pubkey"] for p in db["peers"]}
        if mode == "replace":
            for p in db["peers"]:
                wg_remove_peer(p["pubkey"])
            db["peers"] = []
            existing_ids = set(); existing_ips = set(); existing_keys = set()
        added = 0; skipped = 0
        for p in peers:
            pid    = p.get("id","")
            pubkey = p.get("pubkey","")
            ip     = p.get("ip","")
            if mode == "merge" and (pid in existing_ids or pubkey in existing_keys):
                skipped += 1
                continue
            if ip in existing_ips:
                ip = next_ip()
                if not ip:
                    skipped += 1
                    continue
                p["ip"] = ip
            db["peers"].append(p)
            existing_ids.add(pid); existing_ips.add(ip); existing_keys.add(pubkey)
            try:
                if not is_expired(p) and not p.get("volBlocked") and not p.get("expBlocked"):
                    wg_add_peer(pubkey, ip)
                    if p.get("speedKbps",0) > 0:
                        tc_apply(ip, p["speedKbps"])
            except Exception as e:
                print(f"wg_add error: {e}")
            added += 1
        save_db(db)
        return jsonify({"ok": True, "added": added, "skipped": skipped})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/server/keys", methods=["POST"])
def regenerate_keys():
    """ساخت کلید جدید سرور + آپدیت wg0.conf — برای مواقعی که کلید گم شده"""
    try:
        priv = subprocess.check_output(["wg","genkey"]).decode().strip()
        pub  = subprocess.check_output(["wg","pubkey"],input=priv.encode()).decode().strip()
        with open("/etc/wireguard/server_private.key","w") as f: f.write(priv+"\n")
        with open("/etc/wireguard/server_public.key","w") as f:  f.write(pub+"\n")
        import stat
        os.chmod("/etc/wireguard/server_private.key", stat.S_IRUSR|stat.S_IWUSR)
        # آپدیت wg0.conf
        with open("/etc/wireguard/wg0.conf","r") as f: conf=f.read()
        import re
        conf=re.sub(r"PrivateKey\s*=\s*\S+", f"PrivateKey = {priv}", conf)
        with open("/etc/wireguard/wg0.conf","w") as f: f.write(conf)
        # ری‌استارت WireGuard
        subprocess.run(["systemctl","restart","wg-quick@wg0"],check=False)
        return jsonify({"ok":True,"pubkey":pub,"message":"کلید جدید ساخته شد — کاربران باید کانفیگ جدید دریافت کنند"})
    except Exception as e:
        return jsonify({"error":str(e)}), 500

@app.route("/api/server/export-key", methods=["GET"])
def export_server_key():
    """export کلید سرور برای بکاپ"""
    try:
        priv=open("/etc/wireguard/server_private.key").read().strip()
        pub =open("/etc/wireguard/server_public.key").read().strip()
        return jsonify({"privateKey":priv,"publicKey":pub})
    except Exception as e:
        return jsonify({"error":str(e)}), 500

@app.route("/api/server/import-key", methods=["POST"])
def import_server_key():
    """import کلید قدیمی سرور — کاربران بدون کانفیگ جدید وصل میشن"""
    try:
        data=request.json or {}
        priv=data.get("privateKey","").strip()
        if len(priv) != 44:
            return jsonify({"error":"کلید نامعتبر — باید ۴۴ کاراکتر باشد"}), 400
        pub=subprocess.check_output(["wg","pubkey"],input=priv.encode()).decode().strip()
        with open("/etc/wireguard/server_private.key","w") as f: f.write(priv+"\n")
        with open("/etc/wireguard/server_public.key","w") as f:  f.write(pub+"\n")
        import stat
        os.chmod("/etc/wireguard/server_private.key", stat.S_IRUSR|stat.S_IWUSR)
        with open("/etc/wireguard/wg0.conf","r") as f: conf=f.read()
        import re
        conf=re.sub(r"PrivateKey\s*=\s*\S+", f"PrivateKey = {priv}", conf)
        with open("/etc/wireguard/wg0.conf","w") as f: f.write(conf)
        subprocess.run(["systemctl","restart","wg-quick@wg0"],check=False)
        return jsonify({"ok":True,"pubkey":pub})
    except Exception as e:
        return jsonify({"error":str(e)}), 500

# ─── Priority / QoS ──────────────────────────────────
PRIORITY_CLASSES = {
    "vip":     {"label": "VIP",    "min_kbps": 5120,  "max_kbps": 0,     "prio": 1},
    "normal":  {"label": "عادی",   "min_kbps": 1024,  "max_kbps": 0,     "prio": 2},
    "limited": {"label": "محدود",  "min_kbps": 256,   "max_kbps": 2048,  "prio": 3},
}

def tc_rebuild_qos():
    """بازسازی کامل QoS برای همه peers"""
    db   = load_db()
    iface = WG_IF
    # پاک کردن همه قوانین
    subprocess.run(f"tc qdisc del dev {iface} root 2>/dev/null", shell=True)
    # ساخت HTB root
    subprocess.run(f"tc qdisc add dev {iface} root handle 1: htb default 20", shell=True)
    # کلاس‌های اصلی اولویت
    subprocess.run(f"tc class add dev {iface} parent 1: classid 1:1  htb rate 1000mbit ceil 1000mbit prio 0", shell=True)
    subprocess.run(f"tc class add dev {iface} parent 1:1 classid 1:10 htb rate 500mbit  ceil 1000mbit prio 1", shell=True)  # VIP
    subprocess.run(f"tc class add dev {iface} parent 1:1 classid 1:20 htb rate 200mbit  ceil 800mbit  prio 2", shell=True)  # Normal
    subprocess.run(f"tc class add dev {iface} parent 1:1 classid 1:30 htb rate 50mbit   ceil 200mbit  prio 3", shell=True)  # Limited
    # اضافه کردن SFQ برای fairness داخل هر کلاس
    for cid in ["10","20","30"]:
        subprocess.run(f"tc qdisc add dev {iface} parent 1:{cid} handle {cid}: sfq perturb 10", shell=True)

    active = wg_active_peers()
    mark_counter = {}
    for p in db["peers"]:
        if p["pubkey"] not in active:
            continue
        priority = p.get("priority", "normal")
        parent_class = {"vip":"10","normal":"20","limited":"30"}.get(priority,"20")
        pc = PRIORITY_CLASSES.get(priority, PRIORITY_CLASSES["normal"])
        ip = p["ip"]

        # شناسه یکتا برای این peer
        mark = sum(int(x) for x in ip.split(".")) % 900 + 100
        while mark in mark_counter.values():
            mark += 1
        mark_counter[p["id"]] = mark

        # کلاس اختصاصی برای peer
        min_r = p.get("speedKbps", 0) if p.get("speedKbps",0) > 0 else pc["min_kbps"]
        max_r = p.get("speedKbps", 0) if p.get("speedKbps",0) > 0 else (pc["max_kbps"] if pc["max_kbps"] > 0 else 1000000)
        subprocess.run(
            f"tc class add dev {iface} parent 1:{parent_class} classid 1:{mark} "
            f"htb rate {min_r}kbit ceil {max_r}kbit prio {pc['prio']}",
            shell=True
        )
        subprocess.run(
            f"tc filter add dev {iface} parent 1: protocol ip prio 1 u32 "
            f"match ip dst {ip}/32 flowid 1:{mark}",
            shell=True
        )

@app.route("/api/peers/<pid>/priority", methods=["POST"])
def set_priority(pid):
    db   = load_db()
    data = request.json or {}
    prio = data.get("priority","normal")
    if prio not in PRIORITY_CLASSES:
        return jsonify({"error":"اولویت نامعتبر"}), 400
    for p in db["peers"]:
        if p["id"] == pid:
            p["priority"] = prio
            save_db(db)
            tc_rebuild_qos()
            return jsonify({"ok":True,"priority":prio})
    return jsonify({"error":"یافت نشد"}), 404

@app.route("/api/qos", methods=["GET"])
def get_qos():
    return jsonify(PRIORITY_CLASSES)

# ─── Real-time WireGuard Stats Monitor ───────────────
CONN_HISTORY = {}   # {pubkey: [snap, ...]}
MAX_HISTORY  = 120
_prev_bytes  = {}   # {pubkey: (rx, tx)}

def wg_full_dump():
    """خواندن همه آمار peers با یک دستور wg show dump"""
    result = {}
    try:
        out = subprocess.check_output(
            ["wg", "show", "wg0", "dump"],
            stderr=subprocess.DEVNULL
        ).decode().strip()
        for line in out.splitlines()[1:]:   # خط اول = سرور
            parts = line.split("\t")
            if len(parts) < 7:
                continue
            pub      = parts[0]
            endpoint = parts[2] if parts[2] != "(none)" else None
            last_hs  = int(parts[4])
            rx       = int(parts[5])
            tx       = int(parts[6])
            result[pub] = {"endpoint": endpoint, "last_hs": last_hs, "rx": rx, "tx": tx}
    except Exception as e:
        print(f"[wg dump] {e}")
    return result

def make_snap(pub, w, now_ms, now_s):
    last_hs  = w.get("last_hs", 0)
    rx       = w.get("rx", 0)
    tx       = w.get("tx", 0)
    prev_rx, prev_tx = _prev_bytes.get(pub, (rx, tx))
    rx_kbps  = round(max(0, rx - prev_rx) * 8 / 30 / 1000, 1)
    tx_kbps  = round(max(0, tx - prev_tx) * 8 / 30 / 1000, 1)
    _prev_bytes[pub] = (rx, tx)
    hs_age   = (now_s - last_hs) if last_hs > 0 else None
    online   = hs_age is not None and hs_age < 180
    if   not online or hs_age is None: quality = "offline"
    elif hs_age < 30:                  quality = "excellent"
    elif hs_age < 60:                  quality = "good"
    elif hs_age < 120:                 quality = "fair"
    else:                              quality = "poor"
    return {
        "t": now_ms, "online": online, "hs_age": hs_age,
        "rx": rx, "tx": tx, "rx_kbps": rx_kbps, "tx_kbps": tx_kbps,
        "quality": quality, "endpoint": w.get("endpoint"),
    }

def bg_ping_monitor():
    time.sleep(2)
    while True:
        try:
            db     = load_db()
            now_ms = int(time.time() * 1000)
            now_s  = int(time.time())
            dump   = wg_full_dump()
            for p in db.get("peers", []):
                pub  = p["pubkey"]
                snap = make_snap(pub, dump.get(pub, {}), now_ms, now_s)
                if pub not in CONN_HISTORY:
                    CONN_HISTORY[pub] = []
                CONN_HISTORY[pub].append(snap)
                if len(CONN_HISTORY[pub]) > MAX_HISTORY:
                    CONN_HISTORY[pub] = CONN_HISTORY[pub][-MAX_HISTORY:]
        except Exception as e:
            print(f"[monitor] {e}")
        time.sleep(30)

@app.route("/api/ping", methods=["GET"])
def get_ping():
    db = load_db()
    return jsonify({p["ip"]: CONN_HISTORY.get(p["pubkey"], []) for p in db.get("peers", [])})

@app.route("/api/ping/<peer_ip>", methods=["GET"])
def get_peer_ping(peer_ip):
    clean_ip = peer_ip.replace("-", ".")
    db   = load_db()
    peer = next((p for p in db.get("peers", []) if p["ip"] == clean_ip), None)
    if not peer:
        return jsonify([])
    history = CONN_HISTORY.get(peer["pubkey"], [])
    if not history:
        # snapshot لحظه‌ای اگه هنوز داده جمع نشده
        dump = wg_full_dump()
        snap = make_snap(peer["pubkey"], dump.get(peer["pubkey"], {}),
                         int(time.time()*1000), int(time.time()))
        history = [snap]
    return jsonify(history)
    return jsonify(CONN_HISTORY.get(peer["pubkey"], []))

if __name__ == "__main__":
    t1 = threading.Thread(target=bg_checker, daemon=True)
    t2 = threading.Thread(target=bg_ping_monitor, daemon=True)
    t1.start()
    t2.start()
    app.run(host="127.0.0.1", port=5000, debug=False)
PYEOF

chmod +x /opt/wg-api/app.py
ok "API ساخته شد"

cat > /etc/systemd/system/wg-api.service << SVCEOF
[Unit]
Description=WireGuard Panel API
After=network.target wg-quick@wg0.service

[Service]
ExecStart=/opt/wg-venv/bin/python3 /opt/wg-api/app.py
Restart=always
RestartSec=5
Environment="SERVER_IP=${SERVER_IP}"
WorkingDirectory=/opt/wg-api

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable wg-api > /dev/null 2>&1
systemctl restart wg-api
sleep 3
systemctl is-active --quiet wg-api && ok "API فعال (port 5000)" || { warn "API مشکل دارد:"; journalctl -u wg-api -n 10 --no-pager; }

info "آماده‌سازی React..."
mkdir -p /opt/wg-panel && cd /opt/wg-panel
if [[ ! -f package.json ]]; then
  npx --yes create-react-app . --template cra-template 2>&1 | tail -5
fi
npm install --save recharts qrcode.react 2>&1 | tail -3
ok "npm packages آماده"
rm -f src/App.js src/App.css src/App.test.js src/logo.svg src/reportWebVitals.js src/setupTests.js

cat > src/App.jsx << 'APPEOF'
import { useState, useEffect, useCallback } from "react";
import { AreaChart,Area,XAxis,YAxis,Tooltip,ResponsiveContainer,PieChart,Pie,Cell } from "recharts";
import { QRCodeSVG } from "qrcode.react";

const API=`${window.location.protocol}//${window.location.hostname}/api`;
const PIE_COLORS=["#00d4ff","#7c3aed","#00e676","#ff9100","#ec4899","#f43f5e","#06b6d4","#84cc16"];

// ── Themes ──────────────────────────────────────────
const THEMES={
  dark:{
    name:"تیره",icon:"🌙",
    bg:"#0a0e1a",surface:"#111827",surfaceHover:"#1a2235",
    border:"#1e2d45",cyan:"#00d4ff",cyanDim:"#00d4ff22",
    green:"#00e676",orange:"#ff9100",red:"#ff1744",purple:"#7c3aed",
    text:"#e8edf5",textMuted:"#6b7fa3",textDim:"#3a4a6b",
  },
  light:{
    name:"روشن",icon:"☀️",
    bg:"#f0f4f8",surface:"#ffffff",surfaceHover:"#e8eef5",
    border:"#d1dce8",cyan:"#0284c7",cyanDim:"#0284c722",
    green:"#16a34a",orange:"#d97706",red:"#dc2626",purple:"#7c3aed",
    text:"#0f172a",textMuted:"#64748b",textDim:"#94a3b8",
  },
  midnight:{
    name:"نیمه‌شب",icon:"🌌",
    bg:"#000000",surface:"#0d0d0d",surfaceHover:"#1a1a1a",
    border:"#2a2a2a",cyan:"#a855f7",cyanDim:"#a855f722",
    green:"#4ade80",orange:"#fb923c",red:"#f87171",purple:"#c084fc",
    text:"#f1f5f9",textMuted:"#71717a",textDim:"#3f3f46",
  },
  ocean:{
    name:"اقیانوس",icon:"🌊",
    bg:"#0c1a2e",surface:"#0f2744",surfaceHover:"#163459",
    border:"#1e4080",cyan:"#38bdf8",cyanDim:"#38bdf822",
    green:"#34d399",orange:"#fbbf24",red:"#f87171",purple:"#818cf8",
    text:"#e0f2fe",textMuted:"#7fb3d3",textDim:"#2d5986",
  },
  sunset:{
    name:"غروب",icon:"🌅",
    bg:"#1a0a0a",surface:"#2d1515",surfaceHover:"#3d1f1f",
    border:"#5c2d2d",cyan:"#fb923c",cyanDim:"#fb923c22",
    green:"#4ade80",orange:"#fbbf24",red:"#ef4444",purple:"#e879f9",
    text:"#fef2f2",textMuted:"#d4a0a0",textDim:"#5c3333",
  },
  forest:{
    name:"جنگل",icon:"🌿",
    bg:"#0a1a0a",surface:"#0f2d0f",surfaceHover:"#163d16",
    border:"#1e5c1e",cyan:"#4ade80",cyanDim:"#4ade8022",
    green:"#86efac",orange:"#fbbf24",red:"#f87171",purple:"#a78bfa",
    text:"#f0fdf4",textMuted:"#86a886",textDim:"#2d5c2d",
  },
};

const THEME_STORAGE_KEY="wg-panel-theme";
let _currentTheme=localStorage.getItem(THEME_STORAGE_KEY)||"dark";
const getC=()=>THEMES[_currentTheme]||THEMES.dark;
let C=getC();

const fmt={
  bytes:(b)=>{if(!b||b<=0)return"0 B";if(b>=1e12)return(b/1e12).toFixed(2)+" TB";if(b>=1e9)return(b/1e9).toFixed(2)+" GB";if(b>=1e6)return(b/1e6).toFixed(2)+" MB";return(b/1e3).toFixed(1)+" KB";},
  pct:(u,m)=>m>0?Math.min(100,Math.round((u/m)*100)):0,
  time:(ts)=>ts>0?new Date(ts).toLocaleTimeString("fa-IR"):"—",
  vol:(b)=>b>0?fmt.bytes(b):"∞ بینهایت",
  speed:(k)=>k>0?`${(k/1024).toFixed(1)} Mbps`:"∞ بینهایت",
  date:(ms)=>{
    if(!ms||ms<=0)return"بدون انقضا";
    const d=new Date(ms);
    return d.toLocaleDateString("fa-IR",{year:"numeric",month:"long",day:"numeric"});
  },
  daysLeft:(ms)=>{
    if(!ms||ms<=0)return null;
    const diff=ms-Date.now();
    if(diff<=0)return"منقضی شده";
    const days=Math.ceil(diff/86400000);
    if(days===1)return"فردا منقضی میشه";
    return `${days} روز مانده`;
  },
};

function genHistory(){return Array.from({length:24},(_,i)=>({t:`${i}:00`,rx:Math.random()*800+100,tx:Math.random()*400+50}));}

// ── Helpers ──────────────────────────────────────────
function PulseRing({active,blocked,expired}){
  const color=blocked||expired?C.red:active?C.green:C.textDim;
  return(<span style={{position:"relative",display:"inline-block",width:12,height:12}}><span style={{display:"block",width:12,height:12,borderRadius:"50%",background:color,opacity:(blocked||expired)?1:active?1:0.3}}/>{active&&!blocked&&!expired&&<span style={{position:"absolute",inset:-4,borderRadius:"50%",border:`2px solid ${color}`,animation:"pulse 1.8s ease-out infinite"}}/>}</span>);
}

function UsageBar({used,max,compact}){
  const inf=max<=0;const pct=inf?0:fmt.pct(used,max);
  const color=pct>=100?C.red:pct>=85?C.orange:C.cyan;
  return(<div><div style={{height:compact?4:6,background:C.border,borderRadius:99,overflow:"hidden"}}><div style={{width:inf?"100%":`${pct}%`,height:"100%",borderRadius:99,background:inf?`linear-gradient(90deg,${C.cyan}33,${C.cyan}11)`:`linear-gradient(90deg,${color}88,${color})`,transition:"width .6s"}}/></div>
  {!compact&&<div style={{display:"flex",justifyContent:"space-between",marginTop:4}}><span style={{fontSize:11,color:C.textMuted}}>{fmt.bytes(used)}</span>{inf?<span style={{fontSize:11,color:C.textMuted}}>∞</span>:<span style={{fontSize:11,color,fontWeight:700}}>{pct}%</span>}<span style={{fontSize:11,color:C.textMuted}}>{fmt.vol(max)}</span></div>}</div>);
}

function Card({label,value,sub,color,icon}){
  return(<div style={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:12,padding:"18px 22px",display:"flex",flexDirection:"column",gap:6}}><div style={{fontSize:11,color:C.textMuted,letterSpacing:"0.08em",textTransform:"uppercase"}}>{icon} {label}</div><div style={{fontSize:28,fontWeight:800,color:color||C.text,fontFamily:"monospace",letterSpacing:"-1px"}}>{value}</div>{sub&&<div style={{fontSize:12,color:C.textMuted}}>{sub}</div>}</div>);
}

function Btn({onClick,color,title,children,disabled}){
  return(<button onClick={onClick} title={title} disabled={disabled} style={{width:32,height:32,borderRadius:8,border:`1px solid ${color}33`,background:color+"18",color,cursor:disabled?"not-allowed":"pointer",fontSize:14,display:"flex",alignItems:"center",justifyContent:"center",opacity:disabled?0.4:1}}>{children}</button>);
}

function Field({label,children}){return(<label style={{display:"block"}}><div style={{fontSize:12,color:C.textMuted,marginBottom:6}}>{label}</div>{children}</label>);}

function ModalWrap({onClose,children,width=420}){
  return(<div style={{position:"fixed",inset:0,background:"#000c",zIndex:200,display:"flex",alignItems:"center",justifyContent:"center"}} onClick={onClose}><div style={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:18,padding:28,width,maxHeight:"92vh",overflowY:"auto",boxShadow:`0 0 80px ${C.cyanDim}`}} onClick={e=>e.stopPropagation()}>{children}</div></div>);
}

// ── Limit Fields (حجم + سرعت + تاریخ انقضا) ─────────
const QUICK_PRESETS=[
  {label:"۷ روز",  days:7},
  {label:"۱ ماه",  days:30},
  {label:"۳ ماه",  days:90},
  {label:"۶ ماه",  days:180},
  {label:"۱ سال",  days:365},
];

function LimitFields({maxGB,setMaxGB,speedKbps,setSpeedKbps,expiresAt,setExpiresAt}){
  const [volMode,setVolMode]=useState(maxGB>0?"custom":"inf");
  const [spMode,setSpMode]=useState(speedKbps>0?"custom":"inf");
  const [expMode,setExpMode]=useState(expiresAt>0?"custom":"inf");
  const [volVal,setVolVal]=useState(maxGB>0?maxGB:50);
  const [spVal,setSpVal]=useState(speedKbps>0?speedKbps:10240);

  // واحد: روز یا ماه
  const [expUnit,setExpUnit]=useState("day");   // "day" | "month"
  const [expNum,setExpNum]=useState(30);

  // محاسبه timestamp از روز/ماه
  const calcExpiry=(num,unit)=>{
    const d=new Date();
    if(unit==="day") d.setDate(d.getDate()+num);
    else d.setMonth(d.getMonth()+num);
    d.setHours(23,59,59,0);
    return d.getTime();
  };

  // اگه expiresAt از بیرون داده شده (حالت ویرایش)، نمایشش کن
  const [editTs,setEditTs]=useState(expiresAt>0?expiresAt:0);

  useEffect(()=>{setMaxGB(volMode==="inf"?0:volVal);},[volMode,volVal]);
  useEffect(()=>{setSpeedKbps(spMode==="inf"?0:spVal);},[spMode,spVal]);
  useEffect(()=>{
    if(expMode==="inf"){setExpiresAt(0);setEditTs(0);}
    else{
      const ts=calcExpiry(expNum,expUnit);
      setExpiresAt(ts);setEditTs(ts);
    }
  },[expMode,expNum,expUnit]);

  const toggleBtn=(cur,setVal)=>["inf","custom"].map(m=>(
    <button key={m} type="button" onClick={()=>setVal(m)} style={{flex:1,padding:"7px 0",borderRadius:7,border:`1px solid ${cur===m?C.cyan:C.border}`,background:cur===m?C.cyan+"22":"transparent",color:cur===m?C.cyan:C.textMuted,cursor:"pointer",fontSize:12,fontFamily:"inherit"}}>
      {m==="inf"?"∞ بینهایت":"محدود"}
    </button>
  ));

  const applyPreset=(days)=>{
    if(days>=30&&days%30===0){setExpUnit("month");setExpNum(days/30);}
    else{setExpUnit("day");setExpNum(days);}
  };

  const inputStyle={background:C.bg,border:`1px solid ${C.border}`,color:C.text,borderRadius:8,padding:"10px 14px",fontSize:15,outline:"none",boxSizing:"border-box",fontFamily:"monospace"};
  const daysLeft=editTs>0?fmt.daysLeft(editTs):null;

  return(<>
    <Field label="📦 حجم مجاز">
      <div style={{display:"flex",gap:8,marginBottom:8}}>{toggleBtn(volMode,setVolMode)}</div>
      {volMode==="custom"&&<><input type="number" min={1} value={volVal} onChange={e=>setVolVal(+e.target.value)} placeholder="مثلاً 50" style={{...inputStyle,width:"100%"}}/><div style={{fontSize:11,color:C.textMuted,marginTop:4}}>{fmt.bytes(volVal*1024**3)}</div></>}
      {volMode==="inf"&&<div style={{fontSize:11,color:C.textMuted}}>بدون محدودیت حجم</div>}
    </Field>

    <Field label="⚡ سرعت مجاز">
      <div style={{display:"flex",gap:8,marginBottom:8}}>{toggleBtn(spMode,setSpMode)}</div>
      {spMode==="custom"&&<><input type="number" min={0.1} step={0.1} value={Math.round(spVal/1024*10)/10} onChange={e=>setSpVal(Math.round(+e.target.value*1024))} placeholder="مثلاً 10" style={{...inputStyle,width:"100%"}}/><div style={{fontSize:11,color:C.textMuted,marginTop:4}}>{spVal.toLocaleString()} kbps</div></>}
      {spMode==="inf"&&<div style={{fontSize:11,color:C.textMuted}}>بدون محدودیت سرعت</div>}
    </Field>

    <Field label="📅 تاریخ انقضا">
      <div style={{display:"flex",gap:8,marginBottom:10}}>{toggleBtn(expMode,setExpMode)}</div>
      {expMode==="custom"&&(
        <div style={{display:"flex",flexDirection:"column",gap:10}}>
          {/* دکمه‌های سریع */}
          <div style={{display:"flex",gap:6,flexWrap:"wrap"}}>
            {QUICK_PRESETS.map(({label,days})=>(
              <button key={days} type="button" onClick={()=>applyPreset(days)} style={{padding:"5px 12px",borderRadius:7,border:`1px solid ${C.border}`,background:C.bg,color:C.textMuted,cursor:"pointer",fontSize:12,fontFamily:"inherit"}}>
                {label}
              </button>
            ))}
          </div>
          {/* ورود دستی عدد + واحد */}
          <div style={{display:"flex",gap:8,alignItems:"center"}}>
            <input type="number" min={1} max={expUnit==="day"?3650:120} value={expNum}
              onChange={e=>setExpNum(Math.max(1,+e.target.value))}
              style={{...inputStyle,width:90,textAlign:"center"}}/>
            <div style={{display:"flex",gap:4}}>
              {[["day","روز"],["month","ماه"]].map(([u,l])=>(
                <button key={u} type="button" onClick={()=>setExpUnit(u)} style={{padding:"8px 14px",borderRadius:7,border:`1px solid ${expUnit===u?C.cyan:C.border}`,background:expUnit===u?C.cyan+"22":"transparent",color:expUnit===u?C.cyan:C.textMuted,cursor:"pointer",fontSize:13,fontFamily:"inherit",fontWeight:expUnit===u?700:400}}>
                  {l}
                </button>
              ))}
            </div>
          </div>
          {/* نمایش تاریخ محاسبه‌شده */}
          {editTs>0&&(
            <div style={{background:C.bg,border:`1px solid ${C.border}`,borderRadius:8,padding:"8px 14px",display:"flex",justifyContent:"space-between",alignItems:"center"}}>
              <span style={{fontSize:12,color:C.textMuted}}>📅 انقضا در:</span>
              <span style={{fontSize:13,color:C.cyan,fontFamily:"monospace",fontWeight:700}}>{fmt.date(editTs)}</span>
              <span style={{fontSize:11,color:C.orange}}>({daysLeft})</span>
            </div>
          )}
        </div>
      )}
      {expMode==="inf"&&<div style={{fontSize:11,color:C.textMuted}}>بدون تاریخ انقضا</div>}
    </Field>
  </>);
}

// ── Priority Badge ───────────────────────────────────
const PRIO_CFG={
  vip:    {label:"VIP",    icon:"⭐", color:"#f59e0b", bg:"#f59e0b22"},
  normal: {label:"عادی",   icon:"👤", color:"#6b7fa3", bg:"#6b7fa322"},
  limited:{label:"محدود",  icon:"🔻", color:"#94a3b8", bg:"#94a3b822"},
};

function PriorityBadge({priority="normal",onClick,small}){
  const cfg=PRIO_CFG[priority]||PRIO_CFG.normal;
  return(
    <span onClick={onClick} title="تغییر اولویت" style={{display:"inline-flex",alignItems:"center",gap:4,padding:small?"2px 7px":"4px 10px",borderRadius:99,fontSize:small?10:11,fontWeight:700,background:cfg.bg,color:cfg.color,border:`1px solid ${cfg.color}44`,cursor:onClick?"pointer":"default",userSelect:"none"}}>
      {cfg.icon} {cfg.label}
    </span>
  );
}

function PriorityModal({peer,onClose,onSave}){
  const [prio,setPrio]=useState(peer.priority||"normal");
  const save=async()=>{
    try{
      const r=await fetch(`${API}/peers/${peer.id}/priority`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({priority:prio})});
      if(r.ok){onSave(prio);onClose();}
    }catch{}
  };
  return(<ModalWrap onClose={onClose} width={360}>
    <div style={{fontSize:18,fontWeight:700,color:C.text,marginBottom:20}}>⚡ اولویت‌بندی — {peer.name}</div>
    <div style={{display:"flex",flexDirection:"column",gap:10,marginBottom:20}}>
      {Object.entries(PRIO_CFG).map(([key,cfg])=>(
        <button key={key} onClick={()=>setPrio(key)} style={{padding:"14px 16px",borderRadius:10,border:`2px solid ${prio===key?cfg.color:C.border}`,background:prio===key?cfg.bg:C.bg,cursor:"pointer",fontFamily:"inherit",display:"flex",alignItems:"center",gap:12,textAlign:"right",transition:"all .15s"}}>
          <span style={{fontSize:24}}>{cfg.icon}</span>
          <div style={{flex:1}}>
            <div style={{fontSize:14,fontWeight:700,color:prio===key?cfg.color:C.text}}>{cfg.label}</div>
            <div style={{fontSize:11,color:C.textMuted,marginTop:2}}>
              {key==="vip"?"حداقل ۵ Mbps تضمین‌شده — بالاترین اولویت":key==="normal"?"حداقل ۱ Mbps — اولویت معمولی":"حداکثر ۲ Mbps — پایین‌ترین اولویت"}
            </div>
          </div>
          {prio===key&&<span style={{color:cfg.color,fontSize:16}}>✓</span>}
        </button>
      ))}
    </div>
    <div style={{background:C.bg,border:`1px solid ${C.border}`,borderRadius:8,padding:"10px 14px",fontSize:11,color:C.textMuted,marginBottom:16}}>
      ⚡ اولویت‌بندی با tc HTB اعمال میشه — تغییر فوری و بدون قطعی
    </div>
    <div style={{display:"flex",gap:10}}>
      <button onClick={onClose} style={{flex:1,padding:"11px 0",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:14,fontFamily:"inherit"}}>انصراف</button>
      <button onClick={save} style={{flex:2,padding:"11px 0",borderRadius:8,border:"none",background:C.cyan,color:C.bg,cursor:"pointer",fontSize:14,fontWeight:700,fontFamily:"inherit"}}>اعمال اولویت</button>
    </div>
  </ModalWrap>);
}

// ── Ping / Stats Modal ───────────────────────────────
const QUALITY_CFG={
  excellent:{label:"عالی",   color:"#00e676",icon:"🟢",desc:"اتصال کاملاً پایدار"},
  good:     {label:"خوب",    color:"#69f0ae",icon:"🟢",desc:"اتصال پایدار"},
  fair:     {label:"متوسط",  color:"#ff9100",icon:"🟡",desc:"تأخیر متوسط"},
  poor:     {label:"ضعیف",   color:"#ff5252",icon:"🔴",desc:"تأخیر بالا"},
  offline:  {label:"آفلاین", color:"#6b7fa3",icon:"⚫",desc:"متصل نیست"},
};

function PingModal({peer,onClose}){
  const [snaps,setSnaps]=useState([]);
  const [loading,setLoading]=useState(true);

  const load=useCallback(async()=>{
    try{
      const r=await fetch(`${API}/ping/${peer.ip.replace(/\./g,"-")}`);
      if(r.ok){const d=await r.json();setSnaps(Array.isArray(d)?d:[]);}
    }catch{}
    setLoading(false);
  },[peer.ip]);

  useEffect(()=>{load();const t=setInterval(load,15000);return()=>clearInterval(t);},[load]);

  const last  = snaps.length>0?snaps[snaps.length-1]:null;
  const qcfg  = QUALITY_CFG[last?.quality||"offline"];
  const online= last?.online||false;
  const onSn  = snaps.filter(s=>s.online);
  const uptime= snaps.length>0?Math.round((onSn.length/snaps.length)*100):0;
  const avgRx = onSn.length>0?Math.round(onSn.reduce((s,x)=>s+(x.rx_kbps||0),0)/onSn.length):0;
  const avgTx = onSn.length>0?Math.round(onSn.reduce((s,x)=>s+(x.tx_kbps||0),0)/onSn.length):0;

  const fmtB=(b)=>{if(!b)return"0 B";if(b>=1e9)return(b/1e9).toFixed(2)+" GB";if(b>=1e6)return(b/1e6).toFixed(2)+" MB";return(b/1e3).toFixed(1)+" KB";};
  const fmtAge=(s)=>{if(!s&&s!==0)return"هرگز";if(s<60)return`${s}ث پیش`;if(s<3600)return`${Math.floor(s/60)}د پیش`;return`${Math.floor(s/3600)}س پیش`;};

  const chart=snaps.map((s,i)=>({
    t:new Date(s.t).toLocaleTimeString("fa-IR",{hour:"2-digit",minute:"2-digit"}),
    rx:s.rx_kbps||0, tx:s.tx_kbps||0,
  }));

  return(<ModalWrap onClose={onClose} width={580}>
    <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",marginBottom:16}}>
      <div>
        <div style={{fontSize:12,color:C.textMuted}}>آمار اتصال WireGuard</div>
        <div style={{fontSize:18,fontWeight:700,color:C.text}}>{peer.name}</div>
        <div style={{fontSize:11,color:C.textMuted,fontFamily:"monospace"}}>{peer.ip}</div>
      </div>
      <div style={{display:"flex",gap:8,alignItems:"center"}}>
        <div style={{padding:"8px 14px",borderRadius:10,background:qcfg.color+"22",border:`1px solid ${qcfg.color}44`,textAlign:"center"}}>
          <div style={{fontSize:18}}>{qcfg.icon}</div>
          <div style={{fontSize:11,color:qcfg.color,fontWeight:700}}>{qcfg.label}</div>
        </div>
        <button onClick={onClose} style={{background:"transparent",border:`1px solid ${C.border}`,color:C.textMuted,borderRadius:8,width:32,height:32,cursor:"pointer",fontSize:16}}>✕</button>
      </div>
    </div>

    {/* آمار */}
    <div style={{display:"grid",gridTemplateColumns:"repeat(4,1fr)",gap:8,marginBottom:14}}>
      {[
        {l:"handshake",v:last?.hs_age!=null?fmtAge(last.hs_age):"—",c:online?C.green:C.textMuted},
        {l:"آپتایم",v:snaps.length>0?`${uptime}%`:"—",c:uptime>90?C.green:uptime>50?C.orange:C.red},
        {l:"دانلود میانگین",v:avgRx>0?`${avgRx}k`:"—",c:C.cyan},
        {l:"آپلود میانگین",v:avgTx>0?`${avgTx}k`:"—",c:C.purple},
      ].map(({l,v,c})=>(
        <div key={l} style={{background:C.bg,border:`1px solid ${C.border}`,borderRadius:8,padding:"10px 8px",textAlign:"center"}}>
          <div style={{fontSize:10,color:C.textMuted,marginBottom:4}}>{l}</div>
          <div style={{fontSize:16,fontWeight:800,color:c,fontFamily:"monospace"}}>{v}</div>
        </div>
      ))}
    </div>

    {/* endpoint + ترافیک کل */}
    {last&&(
      <div style={{background:C.bg,border:`1px solid ${C.border}`,borderRadius:8,padding:"10px 14px",marginBottom:14,display:"flex",gap:16,flexWrap:"wrap",fontSize:11}}>
        <div><span style={{color:C.textMuted}}>Endpoint: </span><span style={{fontFamily:"monospace",color:C.text}}>{last.endpoint||"نامشخص"}</span></div>
        <div><span style={{color:C.textMuted}}>↓ کل: </span><span style={{color:C.cyan}}>{fmtB(last.rx)}</span></div>
        <div><span style={{color:C.textMuted}}>↑ کل: </span><span style={{color:C.purple}}>{fmtB(last.tx)}</span></div>
      </div>
    )}

    {/* نمودار */}
    {loading?(
      <div style={{height:160,display:"flex",alignItems:"center",justifyContent:"center",color:C.textMuted}}>⏳ بارگذاری...</div>
    ):chart.length<=1?(
      <div style={{height:160,background:C.bg,borderRadius:10,border:`1px solid ${C.border}`,display:"flex",flexDirection:"column",alignItems:"center",justifyContent:"center",gap:6,color:C.textMuted}}>
        <div style={{fontSize:28}}>📡</div>
        <div style={{fontSize:13,fontWeight:600}}>در حال جمع‌آوری داده...</div>
        <div style={{fontSize:11}}>هر ۳۰ ثانیه یک نقطه — کمی صبر کنید</div>
        {last&&<div style={{fontSize:11,color:qcfg.color,marginTop:4}}>{qcfg.icon} {qcfg.desc}</div>}
      </div>
    ):(
      <div>
        <div style={{fontSize:11,color:C.textMuted,marginBottom:6}}>نرخ ترافیک kbps — {chart.length} نقطه</div>
        <ResponsiveContainer width="100%" height={160}>
          <AreaChart data={chart} margin={{top:4,right:4,left:0,bottom:4}}>
            <defs>
              <linearGradient id="rxG" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor={C.cyan} stopOpacity={0.4}/><stop offset="95%" stopColor={C.cyan} stopOpacity={0}/></linearGradient>
              <linearGradient id="txG" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor={C.purple} stopOpacity={0.4}/><stop offset="95%" stopColor={C.purple} stopOpacity={0}/></linearGradient>
            </defs>
            <XAxis dataKey="t" tick={{fill:C.textDim,fontSize:9}} axisLine={false} tickLine={false} interval="preserveStartEnd"/>
            <YAxis tick={{fill:C.textDim,fontSize:9}} axisLine={false} tickLine={false} unit="k"/>
            <Tooltip contentStyle={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:8,color:C.text,fontSize:11}} formatter={(v,n)=>[`${v} kbps`,n==="rx"?"↓ دانلود":"↑ آپلود"]}/>
            <Area type="monotone" dataKey="rx" stroke={C.cyan}   fill="url(#rxG)" strokeWidth={2} name="rx"/>
            <Area type="monotone" dataKey="tx" stroke={C.purple} fill="url(#txG)" strokeWidth={2} name="tx"/>
          </AreaChart>
        </ResponsiveContainer>
      </div>
    )}
    <div style={{marginTop:8,fontSize:10,color:C.textDim,textAlign:"center"}}>داده از wg dump — بدون ping — هر ۳۰ ثانیه</div>
  </ModalWrap>);
}

// ── Theme Switcher ───────────────────────────────────
function ThemeModal({onClose,currentTheme,onThemeChange}){
  return(<ModalWrap onClose={onClose} width={480}>
    <div style={{fontSize:18,fontWeight:700,color:C.text,marginBottom:24}}>🎨 انتخاب تم</div>
    <div style={{display:"grid",gridTemplateColumns:"1fr 1fr 1fr",gap:10}}>
      {Object.entries(THEMES).map(([key,th])=>{
        const isActive=currentTheme===key;
        return(
          <button key={key} onClick={()=>{onThemeChange(key);onClose();}} style={{
            padding:"16px 12px",borderRadius:12,cursor:"pointer",fontFamily:"inherit",
            border:`2px solid ${isActive?th.cyan:th.border}`,
            background:th.bg, transition:"all .2s",
            boxShadow:isActive?`0 0 20px ${th.cyan}44`:"none",
          }}>
            <div style={{fontSize:28,marginBottom:8}}>{th.icon}</div>
            <div style={{fontSize:13,fontWeight:700,color:th.text,marginBottom:6}}>{th.name}</div>
            {/* Color preview dots */}
            <div style={{display:"flex",gap:4,justifyContent:"center",marginBottom:8}}>
              {[th.bg,th.surface,th.cyan,th.green,th.purple].map((col,i)=>(
                <div key={i} style={{width:10,height:10,borderRadius:"50%",background:col,border:`1px solid ${th.border}`}}/>
              ))}
            </div>
            {isActive&&<div style={{fontSize:10,color:th.cyan,fontWeight:700}}>✓ فعال</div>}
          </button>
        );
      })}
    </div>
    <div style={{marginTop:16,fontSize:11,color:C.textMuted,textAlign:"center"}}>تم انتخابی در مرورگر ذخیره می‌شود</div>
  </ModalWrap>);
}

// ── Login ─────────────────────────────────────────────
function LoginPage({onLogin}){
  const [pass,setPass]=useState("");const [err,setErr]=useState("");const [loading,setLoading]=useState(false);
  const submit=async()=>{
    if(!pass.trim())return;setLoading(true);setErr("");
    try{const r=await fetch(`${API}/login`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({password:pass})});
    if(r.ok){onLogin();}else{setErr("رمز عبور اشتباه است");}}
    catch{setErr("خطا در اتصال به سرور");}setLoading(false);
  };
  return(
    <div style={{minHeight:"100vh",background:C.bg,display:"flex",alignItems:"center",justifyContent:"center"}}>
      <div style={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:20,padding:44,width:340,boxShadow:`0 0 80px ${C.cyanDim}`}}>
        <div style={{textAlign:"center",marginBottom:32}}><div style={{fontSize:40,marginBottom:12}}>🔒</div><div style={{fontSize:22,fontWeight:800,color:C.text}}>WireGuard Panel</div></div>
        <Field label="رمز عبور مدیریت">
          <input type="password" value={pass} onChange={e=>setPass(e.target.value)} onKeyDown={e=>e.key==="Enter"&&submit()} placeholder="رمز عبور" autoFocus
            style={{width:"100%",background:C.bg,border:`1px solid ${err?C.red:C.border}`,color:C.text,borderRadius:10,padding:"12px 16px",fontSize:15,outline:"none",boxSizing:"border-box"}}/>
          {err&&<div style={{fontSize:12,color:C.red,marginTop:6}}>{err}</div>}
        </Field>
        <button onClick={submit} disabled={loading} style={{width:"100%",padding:"13px 0",borderRadius:10,border:"none",background:`linear-gradient(135deg,${C.cyan},${C.purple})`,color:C.bg,cursor:"pointer",fontSize:15,fontWeight:800,fontFamily:"inherit",marginTop:16,opacity:loading?0.7:1}}>
          {loading?"در حال ورود...":"ورود به پنل"}
        </button>
      </div>
    </div>
  );
}

// ── Change Password ───────────────────────────────────
function ChangePassModal({onClose,showToast}){
  const [cur,setCur]=useState("");const [nw,setNw]=useState("");const [nw2,setNw2]=useState("");const [err,setErr]=useState("");const [loading,setLoading]=useState(false);
  const submit=async()=>{
    if(nw!==nw2){setErr("رمزهای جدید یکسان نیستند");return;}
    if(nw.length<4){setErr("حداقل ۴ کاراکتر");return;}
    setLoading(true);setErr("");
    try{const r=await fetch(`${API}/change-password`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({current:cur,new:nw})});
    const d=await r.json();if(r.ok){showToast("رمز تغییر کرد ✓");onClose();}else{setErr(d.error||"خطا");}}
    catch{setErr("خطا در اتصال");}setLoading(false);
  };
  const inp={width:"100%",background:C.bg,border:`1px solid ${C.border}`,color:C.text,borderRadius:8,padding:"10px 14px",fontSize:14,outline:"none",boxSizing:"border-box"};
  return(<ModalWrap onClose={onClose} width={360}>
    <div style={{fontSize:18,fontWeight:700,color:C.text,marginBottom:24}}>🔑 تغییر رمز عبور</div>
    <div style={{display:"flex",flexDirection:"column",gap:14}}>
      <Field label="رمز فعلی"><input type="password" value={cur} onChange={e=>setCur(e.target.value)} style={inp}/></Field>
      <Field label="رمز جدید"><input type="password" value={nw} onChange={e=>setNw(e.target.value)} style={inp}/></Field>
      <Field label="تکرار رمز جدید"><input type="password" value={nw2} onChange={e=>setNw2(e.target.value)} onKeyDown={e=>e.key==="Enter"&&submit()} style={{...inp,border:`1px solid ${err?C.red:C.border}`}}/></Field>
      {err&&<div style={{fontSize:12,color:C.red}}>{err}</div>}
    </div>
    <div style={{display:"flex",gap:10,marginTop:20}}>
      <button onClick={onClose} style={{flex:1,padding:"11px 0",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:14,fontFamily:"inherit"}}>انصراف</button>
      <button onClick={submit} disabled={loading} style={{flex:2,padding:"11px 0",borderRadius:8,border:"none",background:C.cyan,color:C.bg,cursor:"pointer",fontSize:14,fontWeight:700,fontFamily:"inherit"}}>ذخیره</button>
    </div>
  </ModalWrap>);
}

// ── Add User ──────────────────────────────────────────
function AddUserModal({onClose,onAdd}){
  const [name,setName]=useState("");const [maxGB,setMaxGB]=useState(0);const [speed,setSpeed]=useState(0);const [expiresAt,setExpiresAt]=useState(0);const [loading,setLoading]=useState(false);const [err,setErr]=useState("");
  const submit=async()=>{
    if(!name.trim()){setErr("نام الزامی است");return;}setLoading(true);setErr("");
    try{const r=await fetch(`${API}/peers`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:name.trim(),maxGB,speedKbps:speed,expiresAt})});
    const d=await r.json();if(r.ok){onAdd(d);onClose();}else{setErr(d.error||"خطا");}}
    catch{setErr("خطا در اتصال");}setLoading(false);
  };
  return(<ModalWrap onClose={onClose} width={440}>
    <div style={{fontSize:18,fontWeight:700,color:C.text,marginBottom:24}}>➕ افزودن کاربر جدید</div>
    <div style={{display:"flex",flexDirection:"column",gap:16}}>
      <Field label="نام کاربر">
        <input value={name} onChange={e=>setName(e.target.value)} onKeyDown={e=>e.key==="Enter"&&submit()} placeholder="مثلاً: علی رضایی" autoFocus
          style={{width:"100%",background:C.bg,border:`1px solid ${err?C.red:C.border}`,color:C.text,borderRadius:8,padding:"10px 14px",fontSize:14,outline:"none",boxSizing:"border-box"}}/>
        {err&&<div style={{fontSize:11,color:C.red,marginTop:4}}>{err}</div>}
      </Field>
      <LimitFields maxGB={maxGB} setMaxGB={setMaxGB} speedKbps={speed} setSpeedKbps={setSpeed} expiresAt={expiresAt} setExpiresAt={setExpiresAt}/>
    </div>
    <div style={{background:C.bg,border:`1px solid ${C.border}`,borderRadius:8,padding:"10px 14px",marginTop:12,fontSize:11,color:C.textMuted}}>🔑 IP و کلیدها خودکار توسط سرور ساخته می‌شوند</div>
    <div style={{display:"flex",gap:10,marginTop:20}}>
      <button onClick={onClose} style={{flex:1,padding:"11px 0",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:14,fontFamily:"inherit"}}>انصراف</button>
      <button onClick={submit} disabled={loading} style={{flex:2,padding:"11px 0",borderRadius:8,border:"none",background:C.cyan,color:C.bg,cursor:loading?"not-allowed":"pointer",fontSize:14,fontWeight:700,fontFamily:"inherit",opacity:loading?0.7:1}}>
        {loading?"در حال ساخت...":"➕ افزودن"}
      </button>
    </div>
  </ModalWrap>);
}

// ── Config Modal ──────────────────────────────────────
function ConfigModal({peer,serverInfo,onClose}){
  const [tab,setTab]=useState("qr");
  const cfg=`[Interface]\nPrivateKey = ${peer.privkey}\nAddress = ${peer.ip}/24\nDNS = 1.1.1.1, 8.8.8.8\nMTU = 1420\n\n[Peer]\nPublicKey = ${serverInfo?.pubkey||""}\nEndpoint = ${serverInfo?.ip||""}:${serverInfo?.port||51820}\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 15`;
  const dl=()=>{const b=new Blob([cfg],{type:"text/plain"});const u=URL.createObjectURL(b);const a=document.createElement("a");a.href=u;a.download=`${peer.name.replace(/\s+/g,"-")}-wg.conf`;a.click();URL.revokeObjectURL(u);};
  return(<ModalWrap onClose={onClose}>
    <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",marginBottom:20}}>
      <div><div style={{fontSize:12,color:C.textMuted}}>کانفیگ اتصال</div><div style={{fontSize:18,fontWeight:700,color:C.text}}>{peer.name}</div></div>
      <button onClick={onClose} style={{background:"transparent",border:`1px solid ${C.border}`,color:C.textMuted,borderRadius:8,width:32,height:32,cursor:"pointer",fontSize:16}}>✕</button>
    </div>
    <div style={{display:"flex",gap:4,background:C.bg,borderRadius:10,padding:4,marginBottom:20}}>
      {[["qr","📷 QR Code"],["conf","📄 کانفیگ"]].map(([k,l])=>(<button key={k} onClick={()=>setTab(k)} style={{flex:1,padding:"8px 0",borderRadius:7,border:"none",cursor:"pointer",fontSize:13,fontFamily:"inherit",background:tab===k?C.cyan:"transparent",color:tab===k?C.bg:C.textMuted,fontWeight:tab===k?700:400}}>{l}</button>))}
    </div>
    {tab==="qr"&&(
      <div style={{display:"flex",flexDirection:"column",alignItems:"center",gap:16}}>
        <div style={{background:"#fff",padding:16,borderRadius:14}}><QRCodeSVG value={cfg} size={210} bgColor="#ffffff" fgColor="#000000" level="M"/></div>
        <div style={{fontSize:12,color:C.textMuted,textAlign:"center"}}>با اپ WireGuard یا Netmod اسکن کنید</div>
        {peer.expiresAt>0&&<div style={{background:C.orange+"22",border:`1px solid ${C.orange}44`,borderRadius:8,padding:"8px 14px",fontSize:11,color:C.orange,textAlign:"center",width:"100%"}}>⏰ انقضا: {fmt.date(peer.expiresAt)}</div>}
      </div>
    )}
    {tab==="conf"&&(
      <div style={{display:"flex",flexDirection:"column",gap:12}}>
        <pre style={{background:C.bg,border:`1px solid ${C.border}`,borderRadius:10,padding:16,fontSize:11,fontFamily:"monospace",color:"#a0c4ff",lineHeight:1.8,overflowX:"auto",margin:0,whiteSpace:"pre-wrap",wordBreak:"break-all"}}>{cfg}</pre>
        <div style={{display:"flex",gap:8}}>
          <button onClick={()=>navigator.clipboard.writeText(cfg).catch(()=>{})} style={{flex:1,padding:"10px 0",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:13,fontFamily:"inherit"}}>📋 کپی</button>
          <button onClick={dl} style={{flex:2,padding:"10px 0",borderRadius:8,border:"none",background:C.cyan,color:C.bg,cursor:"pointer",fontSize:13,fontWeight:700,fontFamily:"inherit"}}>⬇ دانلود .conf</button>
        </div>
      </div>
    )}
  </ModalWrap>);
}

// ── Backup / Restore Modal ───────────────────────────
function BackupModal({onClose,showToast,onRestore}){
  const [tab,setTab]=useState("backup");
  const [restoreMode,setRestoreMode]=useState("merge");
  const [restoreServerKey,setRestoreServerKey]=useState(true);
  const [file,setFile]=useState(null);
  const [fileData,setFileData]=useState(null);
  const [loading,setLoading]=useState(false);
  const [preview,setPreview]=useState(null);

  const doBackup=async()=>{
    try{
      const r=await fetch(`${API}/backup`);
      if(!r.ok){showToast("خطا در بکاپ",C.red);return;}
      const blob=await r.blob();
      const url=URL.createObjectURL(blob);
      const a=document.createElement("a");
      a.href=url;
      const now=new Date().toISOString().slice(0,10).replace(/-/g,"");
      a.download=`wg-backup-${now}.json`;
      a.click();
      URL.revokeObjectURL(url);
      showToast("بکاپ دانلود شد ✓");
    }catch{showToast("خطا در بکاپ",C.red);}
  };

  const onFileChange=async(e)=>{
    const f=e.target.files[0];
    if(!f){setFile(null);setFileData(null);setPreview(null);return;}
    setFile(f);
    try{
      const text=await f.text();
      const json=JSON.parse(text);
      setFileData(json);
      setPreview({count:json.peers?.length||0,date:json.createdAt?new Date(json.createdAt).toLocaleDateString("fa-IR"):"نامشخص",server:json.serverPub?.slice(0,20)+"..."});
    }catch{showToast("فایل نامعتبر است",C.red);setFile(null);setFileData(null);}
  };

  const doRestore=async()=>{
    if(!fileData?.peers){showToast("فایل بکاپ معتبر نیست",C.red);return;}
    setLoading(true);
    try{
      const r=await fetch(`${API}/restore`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({peers:fileData.peers,mode:restoreMode,restoreServerKey,serverPriv:fileData.serverPriv||null})});
      const d=await r.json();
      if(r.ok){
        showToast(`✓ ${d.added} کاربر بازیابی شد${d.skipped>0?` (${d.skipped} رد شد)`:""}`);
        onRestore();onClose();
      }else{showToast(d.error||"خطا در بازیابی",C.red);}
    }catch{showToast("خطا در اتصال",C.red);}
    setLoading(false);
  };

  const btnStyle=(active)=>({flex:1,padding:"8px 0",borderRadius:7,border:`1px solid ${active?C.cyan:C.border}`,background:active?C.cyan+"22":"transparent",color:active?C.cyan:C.textMuted,cursor:"pointer",fontSize:13,fontFamily:"inherit",fontWeight:active?700:400});

  return(<ModalWrap onClose={onClose} width={460}>
    <div style={{fontSize:18,fontWeight:700,color:C.text,marginBottom:20}}>💾 بکاپ و بازیابی</div>

    {/* Tabs */}
    <div style={{display:"flex",gap:4,background:C.bg,borderRadius:10,padding:4,marginBottom:20}}>
      <button onClick={()=>setTab("backup")} style={btnStyle(tab==="backup")}>⬇ دریافت بکاپ</button>
      <button onClick={()=>setTab("restore")} style={btnStyle(tab==="restore")}>⬆ بازیابی</button>
    </div>

    {/* Backup Tab */}
    {tab==="backup"&&(
      <div style={{display:"flex",flexDirection:"column",gap:16}}>
        <div style={{background:C.bg,border:`1px solid ${C.border}`,borderRadius:12,padding:20,textAlign:"center"}}>
          <div style={{fontSize:40,marginBottom:12}}>📦</div>
          <div style={{fontSize:14,color:C.text,fontWeight:600,marginBottom:6}}>بکاپ کامل کاربران</div>
          <div style={{fontSize:12,color:C.textMuted,marginBottom:16,lineHeight:1.6}}>
            تمام اطلاعات کاربران شامل کلیدها، IP، محدودیت‌ها و تاریخ انقضا در یک فایل JSON ذخیره می‌شود
          </div>
          <button onClick={doBackup} style={{padding:"11px 28px",borderRadius:9,border:"none",background:`linear-gradient(135deg,${C.cyan},${C.purple})`,color:C.bg,cursor:"pointer",fontSize:14,fontWeight:700,fontFamily:"inherit"}}>
            ⬇ دانلود فایل بکاپ
          </button>
        </div>
        <div style={{background:C.bg,border:`1px solid ${C.border}`,borderRadius:10,padding:"12px 16px"}}>
          <div style={{fontSize:11,color:C.textMuted,marginBottom:8}}>فایل بکاپ شامل:</div>
          {["کلید خصوصی و عمومی هر کاربر","آدرس IP هر کاربر","محدودیت حجم و سرعت","تاریخ انقضا","وضعیت مسدود/فعال"].map(i=>(
            <div key={i} style={{fontSize:11,color:C.textMuted,padding:"2px 0"}}>✓ {i}</div>
          ))}
        </div>
      </div>
    )}

    {/* Restore Tab */}
    {tab==="restore"&&(
      <div style={{display:"flex",flexDirection:"column",gap:16}}>
        {/* آپلود فایل */}
        <div>
          <div style={{fontSize:12,color:C.textMuted,marginBottom:8}}>فایل بکاپ JSON را انتخاب کنید</div>
          <label style={{display:"block",border:`2px dashed ${file?C.cyan:C.border}`,borderRadius:10,padding:"20px",textAlign:"center",cursor:"pointer",background:file?C.cyan+"08":C.bg,transition:"all .2s"}}>
            <input type="file" accept=".json" onChange={onFileChange} style={{display:"none"}}/>
            <div style={{fontSize:28,marginBottom:8}}>{file?"✅":"📂"}</div>
            <div style={{fontSize:13,color:file?C.cyan:C.textMuted}}>{file?file.name:"کلیک کنید یا فایل را بکشید"}</div>
          </label>
        </div>

        {/* پیش‌نمایش */}
        {preview&&(
          <div style={{background:C.bg,border:`1px solid ${C.cyan}44`,borderRadius:10,padding:"14px 16px"}}>
            <div style={{fontSize:12,color:C.cyan,fontWeight:700,marginBottom:10}}>📋 اطلاعات فایل بکاپ</div>
            <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:8}}>
              {[["تعداد کاربران",preview.count+" نفر"],["تاریخ بکاپ",preview.date],["کلید سرور",preview.server]].map(([l,v])=>(
                <div key={l}><div style={{fontSize:10,color:C.textMuted}}>{l}</div><div style={{fontSize:12,fontFamily:"monospace",color:C.text,marginTop:2}}>{v}</div></div>
              ))}
            </div>
          </div>
        )}

        {/* حالت بازیابی */}
        {preview&&(
          <div>
            <div style={{fontSize:12,color:C.textMuted,marginBottom:8}}>حالت بازیابی</div>
            <div style={{display:"flex",gap:8}}>
              {[["merge","ادغام با کاربران فعلی"],["replace","جایگزینی کامل"]].map(([m,l])=>(
                <button key={m} onClick={()=>setRestoreMode(m)} style={{flex:1,padding:"9px 0",borderRadius:8,border:`1px solid ${restoreMode===m?C.cyan:C.border}`,background:restoreMode===m?C.cyan+"22":"transparent",color:restoreMode===m?C.cyan:C.textMuted,cursor:"pointer",fontSize:12,fontFamily:"inherit",fontWeight:restoreMode===m?700:400}}>
                  {m==="merge"?"🔀 ادغام":"🔄 جایگزینی"}
                  <div style={{fontSize:10,opacity:.7,marginTop:2}}>{l}</div>
                </button>
              ))}
            </div>
            {restoreMode==="replace"&&(
              <div style={{background:C.red+"11",border:`1px solid ${C.red}44`,borderRadius:8,padding:"10px 14px",marginTop:10,fontSize:11,color:C.red}}>
                ⚠️ تمام کاربران فعلی حذف و با کاربران بکاپ جایگزین می‌شوند
              </div>
            )}
          </div>
        )}

        {/* گزینه restore کلید سرور */}
        {preview&&fileData?.serverPriv&&(
          <div style={{background:C.orange+"11",border:`1px solid ${C.orange}44`,borderRadius:10,padding:"12px 14px"}}>
            <label style={{display:"flex",alignItems:"flex-start",gap:10,cursor:"pointer"}}>
              <input type="checkbox" checked={restoreServerKey} onChange={e=>setRestoreServerKey(e.target.checked)}
                style={{marginTop:2,accentColor:C.orange,width:16,height:16,flexShrink:0}}/>
              <div>
                <div style={{fontSize:13,color:C.orange,fontWeight:700}}>🔑 بازیابی کلید سرور</div>
                <div style={{fontSize:11,color:C.textMuted,marginTop:3,lineHeight:1.5}}>
                  کاربران با همان کانفیگ قدیمی وصل میشن — بدون نیاز به کانفیگ جدید
                </div>
              </div>
            </label>
          </div>
        )}
        {preview&&!fileData?.serverPriv&&(
          <div style={{background:C.red+"11",border:`1px solid ${C.red}33`,borderRadius:8,padding:"10px 14px",fontSize:11,color:C.textMuted}}>
            ⚠️ این بکاپ کلید سرور ندارد — کاربران باید کانفیگ جدید دریافت کنند
          </div>
        )}
        <div style={{display:"flex",gap:10,marginTop:4}}>
          <button onClick={onClose} style={{flex:1,padding:"11px 0",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:14,fontFamily:"inherit"}}>انصراف</button>
          <button onClick={doRestore} disabled={!file||loading} style={{flex:2,padding:"11px 0",borderRadius:8,border:"none",background:file?C.cyan:"#333",color:file?C.bg:C.textDim,cursor:file&&!loading?"pointer":"not-allowed",fontSize:14,fontWeight:700,fontFamily:"inherit",opacity:loading?0.7:1}}>
            {loading?"در حال بازیابی...":"⬆ بازیابی کاربران"}
          </button>
        </div>
      </div>
    )}
  </ModalWrap>);
}

// ── Edit Modal ────────────────────────────────────────
function EditModal({peer,onClose,onSave}){
  const [name,setName]=useState(peer.name);
  const [maxGB,setMaxGB]=useState(peer.maxBytes>0?peer.maxBytes/1024**3:0);
  const [speed,setSpeed]=useState(peer.speedKbps||0);
  const [expiresAt,setExpiresAt]=useState(peer.expiresAt||0);
  const [loading,setLoading]=useState(false);
  const submit=async()=>{
    setLoading(true);
    try{const r=await fetch(`${API}/peers/${peer.id}`,{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({name,maxGB,speedKbps:speed,expiresAt})});
    const d=await r.json();if(r.ok){onSave(d);onClose();}}catch{}setLoading(false);
  };
  return(<ModalWrap onClose={onClose} width={440}>
    <div style={{fontSize:18,fontWeight:700,color:C.text,marginBottom:24}}>✏️ ویرایش {peer.name}</div>
    <div style={{display:"flex",flexDirection:"column",gap:16}}>
      <Field label="نام کاربر"><input value={name} onChange={e=>setName(e.target.value)} style={{width:"100%",background:C.bg,border:`1px solid ${C.border}`,color:C.text,borderRadius:8,padding:"10px 14px",fontSize:14,outline:"none",boxSizing:"border-box"}}/></Field>
      <LimitFields maxGB={maxGB} setMaxGB={setMaxGB} speedKbps={speed} setSpeedKbps={setSpeed} expiresAt={expiresAt} setExpiresAt={setExpiresAt}/>
    </div>
    <div style={{display:"flex",gap:10,marginTop:20}}>
      <button onClick={onClose} style={{flex:1,padding:"11px 0",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:14,fontFamily:"inherit"}}>انصراف</button>
      <button onClick={submit} disabled={loading} style={{flex:2,padding:"11px 0",borderRadius:8,border:"none",background:C.cyan,color:C.bg,cursor:"pointer",fontSize:14,fontWeight:700,fontFamily:"inherit"}}>ذخیره تغییرات</button>
    </div>
  </ModalWrap>);
}

// ── Main ──────────────────────────────────────────────
export default function App(){
  const [loggedIn,setLoggedIn]=useState(false);
  const [peers,setPeers]=useState([]);
  const [serverInfo,setServerInfo]=useState(null);
  const [history]=useState(genHistory());
  const [selected,setSelected]=useState(null);
  const [editing,setEditing]=useState(null);
  const [configPeer,setConfigPeer]=useState(null);
  const [addingUser,setAddingUser]=useState(false);
  const [changingPass,setChangingPass]=useState(false);
  const [backupModal,setBackupModal]=useState(false);
  const [themeModal,setThemeModal]=useState(false);
  const [priorityPeer,setPriorityPeer]=useState(null);
  const [pingPeer,setPingPeer]=useState(null);
  const [theme,setTheme]=useState(_currentTheme);

  const applyTheme=(key)=>{
    _currentTheme=key;
    C=getC();
    localStorage.setItem(THEME_STORAGE_KEY,key);
    setTheme(key);
  };
  const [confirmDel,setConfirmDel]=useState(null);
  const [toast,setToast]=useState(null);
  const [tab,setTab]=useState("peers");
  const [loading,setLoading]=useState(false);

  const showToast=(msg,color=C.green)=>{setToast({msg,color});setTimeout(()=>setToast(null),3500);};
  const fetchPeers=useCallback(async()=>{try{const r=await fetch(`${API}/peers`);if(r.ok)setPeers(await r.json());}catch{}},[] );

  useEffect(()=>{
    if(!loggedIn)return;
    setLoading(true);
    Promise.all([
      fetch(`${API}/peers`).then(r=>r.json()).then(setPeers).catch(()=>{}),
      fetch(`${API}/server`).then(r=>r.json()).then(setServerInfo).catch(()=>{}),
    ]).finally(()=>setLoading(false));
    const t=setInterval(fetchPeers,10000);
    return()=>clearInterval(t);
  },[loggedIn,fetchPeers]);

  const deletePeer=async(id)=>{try{await fetch(`${API}/peers/${id}`,{method:"DELETE"});setPeers(p=>p.filter(x=>x.id!==id));setConfirmDel(null);showToast("کاربر حذف شد",C.red);}catch{showToast("خطا",C.red);}};
  const togglePeer=async(id)=>{const p=peers.find(x=>x.id===id);try{await fetch(`${API}/peers/${id}/toggle`,{method:"POST"});fetchPeers();showToast(p?.active?`${p.name} قطع شد`:`${p.name} وصل شد`,p?.active?C.orange:C.green);}catch{showToast("خطا",C.red);}};
  const resetPeer=async(id)=>{try{await fetch(`${API}/peers/${id}/reset`,{method:"POST"});fetchPeers();showToast("مصرف ریست شد");}catch{showToast("خطا",C.red);}};

  const activePeers=peers.filter(p=>p.active).length;
  const expiredPeers=peers.filter(p=>p.expired).length;
  const totalUsed=peers.reduce((s,p)=>s+(p.usedBytes||0),0);
  const totalMax=peers.reduce((s,p)=>s+(p.maxBytes||0),0);
  const pieData=peers.map(p=>({name:p.name,value:p.usedBytes||1}));

  if(!loggedIn)return <LoginPage onLogin={()=>setLoggedIn(true)}/>;

  return(
    <div key={theme} dir="rtl" style={{minHeight:"100vh",background:C.bg,color:C.text,fontFamily:"'Vazirmatn','Segoe UI',sans-serif",paddingBottom:40}}>
      <style>{`@keyframes pulse{0%{opacity:.8;transform:scale(1)}100%{opacity:0;transform:scale(2.4)}}*{box-sizing:border-box;margin:0;padding:0}::-webkit-scrollbar{width:6px}::-webkit-scrollbar-track{background:${C.bg}}::-webkit-scrollbar-thumb{background:${C.border};border-radius:3px}button:hover{opacity:.85}input[type=date]::-webkit-calendar-picker-indicator{filter:${theme==="light"?"none":"invert(1)"}}body{background:${C.bg}}`}</style>

      {/* Header */}
      <div style={{borderBottom:`1px solid ${C.border}`,padding:"16px 32px",display:"flex",alignItems:"center",justifyContent:"space-between",background:`${C.surface}dd`,backdropFilter:"blur(10px)",position:"sticky",top:0,zIndex:50}}>
        <div style={{display:"flex",alignItems:"center",gap:12}}>
          <div style={{width:36,height:36,borderRadius:10,background:`linear-gradient(135deg,${C.cyan},${C.purple})`,display:"flex",alignItems:"center",justifyContent:"center",fontSize:18}}>🔒</div>
          <div><div style={{fontWeight:800,fontSize:16}}>WireGuard Panel</div><div style={{fontSize:11,color:C.textMuted,fontFamily:"monospace"}}>{serverInfo?.ip}:{serverInfo?.port||51820}</div></div>
        </div>
        <div style={{display:"flex",gap:8,alignItems:"center"}}>
          <button onClick={()=>setAddingUser(true)} style={{padding:"8px 16px",borderRadius:8,border:"none",background:`linear-gradient(135deg,${C.cyan},${C.purple})`,color:C.bg,cursor:"pointer",fontSize:13,fontWeight:700,fontFamily:"inherit"}}>➕ کاربر جدید</button>
          <button onClick={()=>setThemeModal(true)} title={`تم: ${THEMES[theme]?.name}`} style={{padding:"8px 12px",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:13,fontFamily:"inherit"}}>
            {THEMES[theme]?.icon} تم
          </button>
          <button onClick={()=>setBackupModal(true)} style={{padding:"8px 12px",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:13,fontFamily:"inherit"}}>💾 بکاپ</button>
          <button onClick={()=>setChangingPass(true)} style={{padding:"8px 12px",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:13,fontFamily:"inherit"}}>🔑 رمز</button>
          <button onClick={()=>setLoggedIn(false)} style={{padding:"8px 12px",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:13,fontFamily:"inherit"}}>خروج</button>
        </div>
      </div>

      <div style={{maxWidth:1100,margin:"0 auto",padding:"28px 24px"}}>
        {/* Stats */}
        <div style={{display:"grid",gridTemplateColumns:"repeat(4,1fr)",gap:14,marginBottom:28}}>
          <Card label="آنلاین" value={`${activePeers}/${peers.length}`} sub="کاربر فعال" color={C.cyan} icon="👥"/>
          <Card label="مصرف کل" value={fmt.bytes(totalUsed)} sub={totalMax>0?`از ${fmt.bytes(totalMax)}`:"بدون محدودیت"} color={C.text} icon="📊"/>
          <Card label="منقضی شده" value={expiredPeers} sub="نیاز به تمدید" color={expiredPeers>0?C.red:C.textMuted} icon="⏰"/>
          <Card label="مجموع کاربران" value={peers.length} sub="ثبت‌شده" color={C.orange} icon="👤"/>
        </div>

        {/* Tabs */}
        <div style={{display:"flex",gap:4,marginBottom:20,background:C.surface,borderRadius:10,padding:4,width:"fit-content"}}>
          {[["peers","👤 کاربران"],["traffic","📈 ترافیک"]].map(([k,l])=>(
            <button key={k} onClick={()=>setTab(k)} style={{padding:"7px 20px",borderRadius:7,border:"none",cursor:"pointer",fontSize:13,fontFamily:"inherit",background:tab===k?C.cyan:"transparent",color:tab===k?C.bg:C.textMuted,fontWeight:tab===k?700:400,transition:"all .2s"}}>{l}</button>
          ))}
        </div>

        {tab==="peers"&&(
          <div style={{display:"flex",flexDirection:"column",gap:10}}>
            {loading&&peers.length===0&&<div style={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:14,padding:48,textAlign:"center",color:C.textMuted}}>⏳ بارگذاری...</div>}
            {!loading&&peers.length===0&&(
              <div style={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:14,padding:48,textAlign:"center",color:C.textMuted}}>
                <div style={{fontSize:40,marginBottom:12}}>👤</div><div style={{marginBottom:16}}>هیچ کاربری وجود ندارد</div>
                <button onClick={()=>setAddingUser(true)} style={{padding:"10px 24px",borderRadius:8,border:"none",background:C.cyan,color:C.bg,cursor:"pointer",fontSize:13,fontWeight:700,fontFamily:"inherit"}}>➕ افزودن اولین کاربر</button>
              </div>
            )}
            {peers.map(p=>{
              const isBlocked=!p.active&&p.maxBytes>0&&(p.usedBytes||0)>=p.maxBytes;
              const isExpired=p.expired;
              const daysLeft=fmt.daysLeft(p.expiresAt);
              const nearExp=p.expiresAt>0&&!isExpired&&Date.now()>p.expiresAt-7*86400000;
              const statusColor=isExpired?C.red:isBlocked?C.red:p.active?C.green:C.textMuted;
              const isSel=selected===p.id;
              return(
                <div key={p.id} style={{background:isSel?C.surfaceHover:C.surface,border:`1px solid ${isSel?C.cyan+"55":isExpired?C.red+"44":C.border}`,borderRadius:14,overflow:"hidden",transition:"all .2s"}}>
                  <div onClick={()=>setSelected(isSel?null:p.id)} style={{padding:"14px 20px",cursor:"pointer",display:"grid",alignItems:"center",gridTemplateColumns:"26px 1fr 80px 140px 130px 80px 170px",gap:10}}>
                    <PulseRing active={p.active} blocked={isBlocked} expired={isExpired}/>
                    <div>
                      <div style={{display:"flex",alignItems:"center",gap:6,marginBottom:2}}>
                        <span style={{fontWeight:700,fontSize:14}}>{p.name}</span>
                        <PriorityBadge priority={p.priority||"normal"} small onClick={e=>{e.stopPropagation();setPriorityPeer(p);}}/>
                      </div>
                      <div style={{fontSize:11,color:C.textMuted,fontFamily:"monospace"}}>{p.ip}</div>
                    </div>
                    <div style={{textAlign:"center"}}>
                      <div style={{fontSize:10,color:C.textMuted,marginBottom:2}}>مصرف</div>
                      <div style={{fontSize:12,fontFamily:"monospace",color:C.cyan}}>{fmt.bytes(p.usedBytes||0)}</div>
                    </div>
                    <div>
                      <UsageBar used={p.usedBytes||0} max={p.maxBytes||0} compact/>
                      <div style={{fontSize:10,color:C.textMuted,marginTop:3,textAlign:"center"}}>{fmt.vol(p.maxBytes||0)}</div>
                    </div>
                    {/* تاریخ انقضا */}
                    <div style={{textAlign:"center"}}>
                      {p.expiresAt>0?(
                        <div>
                          <div style={{fontSize:10,color:isExpired?C.red:nearExp?C.orange:C.textMuted,marginBottom:2}}>📅 انقضا</div>
                          <div style={{fontSize:11,color:isExpired?C.red:nearExp?C.orange:C.textMuted,fontWeight:isExpired||nearExp?700:400}}>{daysLeft||fmt.date(p.expiresAt)}</div>
                        </div>
                      ):(
                        <div style={{fontSize:11,color:C.textDim}}>∞ بدون انقضا</div>
                      )}
                    </div>
                    <div style={{textAlign:"center"}}>
                      <span style={{display:"inline-block",padding:"3px 8px",borderRadius:99,fontSize:11,fontWeight:700,background:statusColor+"22",color:statusColor}}>
                        {isExpired?"منقضی":isBlocked?"مسدود":p.active?"آنلاین":"آفلاین"}
                      </span>
                    </div>
                    <div style={{display:"flex",gap:4,justifyContent:"flex-end"}}>
                      <Btn onClick={e=>{e.stopPropagation();setPingPeer(p);}} color={C.cyan} title="نمودار پینگ">📡</Btn>
                      <Btn onClick={e=>{e.stopPropagation();setConfigPeer(p);}} color={C.purple} title="QR / کانفیگ">📱</Btn>
                      <Btn onClick={e=>{e.stopPropagation();togglePeer(p.id);}} color={p.active?C.orange:C.green} title={p.active?"قطع":"وصل"}>{p.active?"⏸":"▶"}</Btn>
                      <Btn onClick={e=>{e.stopPropagation();setEditing(p);}} color={C.textMuted} title="ویرایش">✏️</Btn>
                      <Btn onClick={e=>{e.stopPropagation();resetPeer(p.id);}} color={C.textDim} title="ریست مصرف">↺</Btn>
                      <Btn onClick={e=>{e.stopPropagation();setConfirmDel(p.id);}} color={C.red} title="حذف">🗑</Btn>
                    </div>
                  </div>
                  {isSel&&(
                    <div style={{borderTop:`1px solid ${C.border}`,padding:"12px 20px",display:"grid",gridTemplateColumns:"repeat(7,1fr)",gap:10,background:C.bg+"44"}}>
                      <div><div style={{fontSize:10,color:C.textMuted,marginBottom:4}}>آخرین اتصال</div><div style={{fontSize:12,fontFamily:"monospace",color:C.text}}>{fmt.time(p.lastSeen)}</div></div>
                      <div><div style={{fontSize:10,color:C.textMuted,marginBottom:4}}>حجم مجاز</div><div style={{fontSize:12,fontFamily:"monospace",color:C.text}}>{fmt.vol(p.maxBytes||0)}</div></div>
                      <div><div style={{fontSize:10,color:C.textMuted,marginBottom:4}}>سرعت مجاز</div><div style={{fontSize:12,fontFamily:"monospace",color:C.text}}>{fmt.speed(p.speedKbps||0)}</div></div>
                      <div><div style={{fontSize:10,color:C.textMuted,marginBottom:4}}>تاریخ انقضا</div><div style={{fontSize:12,color:isExpired?C.red:nearExp?C.orange:C.text}}>{fmt.date(p.expiresAt)}</div></div>
                      <div><div style={{fontSize:10,color:C.textMuted,marginBottom:6}}>کانفیگ</div><button onClick={()=>setConfigPeer(p)} style={{padding:"5px 12px",borderRadius:8,border:`1px solid ${C.cyan}55`,background:C.cyan+"18",color:C.cyan,cursor:"pointer",fontSize:11,fontFamily:"inherit",fontWeight:600}}>📱 QR / دانلود</button></div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}

        {tab==="traffic"&&(
          <div style={{display:"grid",gridTemplateColumns:"2fr 1fr",gap:16}}>
            <div style={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:14,padding:24}}>
              <div style={{fontSize:13,color:C.textMuted,marginBottom:20}}>ترافیک ۲۴ ساعت گذشته (MB)</div>
              <ResponsiveContainer width="100%" height={240}>
                <AreaChart data={history}>
                  <defs>
                    <linearGradient id="rx" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor={C.cyan} stopOpacity={0.3}/><stop offset="95%" stopColor={C.cyan} stopOpacity={0}/></linearGradient>
                    <linearGradient id="tx" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor={C.purple} stopOpacity={0.3}/><stop offset="95%" stopColor={C.purple} stopOpacity={0}/></linearGradient>
                  </defs>
                  <XAxis dataKey="t" tick={{fill:C.textDim,fontSize:10}} axisLine={false} tickLine={false}/>
                  <YAxis tick={{fill:C.textDim,fontSize:10}} axisLine={false} tickLine={false}/>
                  <Tooltip contentStyle={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:8,color:C.text}}/>
                  <Area type="monotone" dataKey="rx" stroke={C.cyan} fill="url(#rx)" strokeWidth={2} name="دریافت"/>
                  <Area type="monotone" dataKey="tx" stroke={C.purple} fill="url(#tx)" strokeWidth={2} name="ارسال"/>
                </AreaChart>
              </ResponsiveContainer>
            </div>
            <div style={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:14,padding:24}}>
              <div style={{fontSize:13,color:C.textMuted,marginBottom:16}}>سهم مصرف</div>
              <ResponsiveContainer width="100%" height={180}>
                <PieChart><Pie data={pieData} dataKey="value" innerRadius={50} outerRadius={80} paddingAngle={3}>{pieData.map((_,i)=><Cell key={i} fill={PIE_COLORS[i%PIE_COLORS.length]}/>)}</Pie><Tooltip formatter={v=>fmt.bytes(v)} contentStyle={{background:C.surface,border:`1px solid ${C.border}`,borderRadius:8,color:C.text}}/></PieChart>
              </ResponsiveContainer>
              <div style={{display:"flex",flexDirection:"column",gap:8,marginTop:8}}>
                {peers.map((p,i)=>(<div key={p.id} style={{display:"flex",alignItems:"center",gap:8}}><div style={{width:8,height:8,borderRadius:"50%",background:PIE_COLORS[i%PIE_COLORS.length],flexShrink:0}}/><span style={{fontSize:12,color:C.textMuted,flex:1}}>{p.name}</span><span style={{fontSize:12,fontFamily:"monospace",color:C.text}}>{fmt.bytes(p.usedBytes||0)}</span></div>))}
              </div>
            </div>
            <div style={{gridColumn:"1/-1",background:C.surface,border:`1px solid ${C.border}`,borderRadius:14,padding:24}}>
              <div style={{fontSize:13,color:C.textMuted,marginBottom:20}}>وضعیت حجم و انقضا</div>
              <div style={{display:"flex",flexDirection:"column",gap:16}}>
                {peers.map(p=>{
                  const isExp=p.expired;const near=p.expiresAt>0&&!isExp&&Date.now()>p.expiresAt-7*86400000;
                  return(<div key={p.id} style={{display:"grid",gridTemplateColumns:"130px 1fr 130px 140px",gap:14,alignItems:"center"}}>
                    <div style={{fontSize:13,fontWeight:600}}>{p.name}</div>
                    <UsageBar used={p.usedBytes||0} max={p.maxBytes||0}/>
                    <div style={{fontSize:11,color:C.textMuted,fontFamily:"monospace"}}>{p.maxBytes>0?`${fmt.bytes(p.maxBytes-(p.usedBytes||0))} مانده`:"∞ بینهایت"}</div>
                    <div style={{fontSize:11,color:isExp?C.red:near?C.orange:C.textMuted,fontWeight:isExp||near?700:400}}>📅 {fmt.date(p.expiresAt)}</div>
                  </div>);
                })}
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Delete confirm */}
      {confirmDel&&(
        <div style={{position:"fixed",inset:0,background:"#000c",zIndex:400,display:"flex",alignItems:"center",justifyContent:"center"}}>
          <div style={{background:C.surface,border:`1px solid ${C.red}55`,borderRadius:16,padding:32,width:300,textAlign:"center"}}>
            <div style={{fontSize:36,marginBottom:12}}>🗑</div>
            <div style={{fontSize:17,fontWeight:700,color:C.text,marginBottom:8}}>حذف کاربر؟</div>
            <div style={{fontSize:13,color:C.textMuted,marginBottom:24}}>این عمل قابل بازگشت نیست</div>
            <div style={{display:"flex",gap:10}}>
              <button onClick={()=>setConfirmDel(null)} style={{flex:1,padding:"11px 0",borderRadius:8,border:`1px solid ${C.border}`,background:"transparent",color:C.textMuted,cursor:"pointer",fontSize:14,fontFamily:"inherit"}}>انصراف</button>
              <button onClick={()=>deletePeer(confirmDel)} style={{flex:1,padding:"11px 0",borderRadius:8,border:"none",background:C.red,color:"#fff",cursor:"pointer",fontSize:14,fontWeight:700,fontFamily:"inherit"}}>حذف</button>
            </div>
          </div>
        </div>
      )}

      {configPeer&&<ConfigModal peer={configPeer} serverInfo={serverInfo} onClose={()=>setConfigPeer(null)}/>}
      {editing&&<EditModal peer={editing} onClose={()=>setEditing(null)} onSave={(d)=>{setPeers(p=>p.map(x=>x.id===d.id?{...x,...d}:x));showToast("تنظیمات ذخیره شد");}}/>}
      {addingUser&&<AddUserModal onClose={()=>setAddingUser(false)} onAdd={(p)=>{setPeers(prev=>[...prev,{...p,usedBytes:0,active:false}]);showToast(`${p.name} اضافه شد`);}}/>}
      {priorityPeer&&<PriorityModal peer={priorityPeer} onClose={()=>setPriorityPeer(null)} onSave={(prio)=>{setPeers(prev=>prev.map(x=>x.id===priorityPeer.id?{...x,priority:prio}:x));showToast(`اولویت ${priorityPeer.name} تغییر کرد`);}}/>}
      {pingPeer&&<PingModal peer={pingPeer} onClose={()=>setPingPeer(null)}/>}
      {themeModal&&<ThemeModal onClose={()=>setThemeModal(false)} currentTheme={theme} onThemeChange={applyTheme}/>}
      {backupModal&&<BackupModal onClose={()=>setBackupModal(false)} showToast={showToast} onRestore={fetchPeers}/>}
      {changingPass&&<ChangePassModal onClose={()=>setChangingPass(false)} showToast={showToast}/>}
      {toast&&<div style={{position:"fixed",bottom:28,left:"50%",transform:"translateX(-50%)",background:toast.color,color:C.bg,padding:"10px 24px",borderRadius:99,fontWeight:700,fontSize:13,zIndex:500,boxShadow:"0 4px 20px #0006"}}>{toast.msg}</div>}
    </div>
  );
}
APPEOF

ok "App.jsx نوشته شد"

cat > src/index.js << 'EOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(<App />);
EOF

info "بیلد React..."
CI=false npm run build 2>&1 | tail -5
ok "بیلد موفق"

info "تنظیم Nginx..."
cp -r build/* /var/www/html/
cat > /etc/nginx/sites-available/wg-panel << 'NGEOF'
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.html;
    location /api/ {
        proxy_pass         http://127.0.0.1:5000/api/;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_read_timeout 60s;
    }
    location / { try_files $uri $uri/ /index.html; }
}
NGEOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/wg-panel /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx
ok "Nginx آماده"

ufw allow 22/tcp >/dev/null 2>&1; ufw allow 80/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1; ufw allow 51820/udp >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
ok "فایروال تنظیم شد"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  نصب با موفقیت انجام شد!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "  🌐 پنل:       ${CYAN}http://${SERVER_IP}${NC}"
echo -e "  🔑 رمز پنل:  ${CYAN}admin123${NC}  (از پنل قابل تغییر)"
echo -e ""
echo -e "  بررسی وضعیت:"
echo -e "  ${CYAN}systemctl status wg-api${NC}"
echo -e "  ${CYAN}journalctl -u wg-api -f${NC}"
echo ""
