#!/bin/bash
set -e

# =============================================================================
# Script automatisé — Cas pratique Hadoop : Analyse de logs web
# Génère des données, exécute un job MapReduce, et crée un dashboard HTML
# =============================================================================

NAMENODE="namenode"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'
DASHBOARD_PORT=8888

info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ─── Vérifications ───────────────────────────────────────────────────────────
info "Vérification que le cluster Hadoop est actif..."
if ! docker ps --format '{{.Names}}' | grep -q "^${NAMENODE}$"; then
    error "Le conteneur '${NAMENODE}' n'est pas actif. Lancez d'abord : docker compose up -d"
fi
ok "Conteneur namenode trouvé."

# Attendre que le namenode soit prêt (safemode off)
info "Attente que le namenode quitte le safe mode..."
for i in $(seq 1 30); do
    if docker exec $NAMENODE hdfs dfsadmin -safemode get 2>/dev/null | grep -q "OFF"; then
        break
    fi
    sleep 2
    echo -n "."
done
echo ""
ok "NameNode prêt."

# Attendre qu'au moins 1 datanode soit actif
info "Attente qu'un datanode soit disponible..."
for i in $(seq 1 60); do
    LIVE=$(docker exec $NAMENODE hdfs dfsadmin -report 2>/dev/null | grep -c "^Name:" || true)
    if [ "$LIVE" -ge 1 ]; then
        break
    fi
    sleep 3
    echo -n "."
done
echo ""
if [ "$LIVE" -lt 1 ]; then
    error "Aucun datanode disponible après 3 minutes. Vérifiez 'docker logs datanode'."
fi
ok "${LIVE} datanode(s) actif(s)."

# ─── Étape 1 : Créer les répertoires HDFS ───────────────────────────────────
info "Création des répertoires HDFS..."
docker exec $NAMENODE hdfs dfs -rm -r -f /user/root/input /user/root/output 2>/dev/null || true
docker exec $NAMENODE hdfs dfs -mkdir -p /user/root/input
docker exec $NAMENODE hdfs dfs -mkdir -p /user/root/output
ok "Répertoires HDFS créés."

# ─── Étape 2 : Générer un large dataset de logs ─────────────────────────────
info "Génération de 10 000 lignes de logs web..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_SCRIPTS="${SCRIPT_DIR}/.tmp_scripts"
mkdir -p "$TMP_SCRIPTS"

cat > "$TMP_SCRIPTS/generate_logs.sh" << 'GENSCRIPT'
#!/bin/bash
PAGES=("/index.html" "/about.html" "/contact.html" "/products" "/services"
       "/blog" "/blog/post-1" "/blog/post-2" "/api/data" "/api/users"
       "/api/orders" "/admin" "/admin/settings" "/login" "/logout"
       "/dashboard" "/profile" "/search" "/register" "/404-page"
       "/old-link" "/deprecated" "/api/crash" "/api/timeout" "/health")

METHODS=("GET" "GET" "GET" "GET" "POST" "PUT" "DELETE")

CODES=(200 200 200 200 200 200 200 301 404 403 500 502)

SIZES=(128 256 512 1024 2048 4096 8192 16384)

for i in $(seq 1 10000); do
    IP="192.168.$((RANDOM % 256)).$((RANDOM % 256))"
    HOUR=$((RANDOM % 24))
    MIN=$((RANDOM % 60))
    SEC=$((RANDOM % 60))
    DAY=$((RANDOM % 28 + 1))
    PAGE=${PAGES[$((RANDOM % ${#PAGES[@]}))]}
    METHOD=${METHODS[$((RANDOM % ${#METHODS[@]}))]}
    CODE=${CODES[$((RANDOM % ${#CODES[@]}))]}
    SIZE=${SIZES[$((RANDOM % ${#SIZES[@]}))]}
    printf "%s - - [%02d/Mar/2026:%02d:%02d:%02d] \"%s %s HTTP/1.1\" %d %d\n" \
        "$IP" "$DAY" "$HOUR" "$MIN" "$SEC" "$METHOD" "$PAGE" "$CODE" "$SIZE"
done
GENSCRIPT
chmod +x "$TMP_SCRIPTS/generate_logs.sh"

docker cp "$TMP_SCRIPTS/generate_logs.sh" $NAMENODE:/tmp/generate_logs.sh
docker exec $NAMENODE bash -c 'bash /tmp/generate_logs.sh > /tmp/access.log'

LINES=$(docker exec $NAMENODE wc -l /tmp/access.log | awk '{print $1}')
ok "Fichier généré : ${LINES} lignes de logs."

# ─── Étape 3 : Charger dans HDFS ────────────────────────────────────────────
info "Chargement du fichier dans HDFS..."
docker exec $NAMENODE hdfs dfs -put /tmp/access.log /user/root/input/
ok "Fichier chargé dans HDFS."

docker exec $NAMENODE hdfs dfs -ls -h /user/root/input/
echo ""

# ─── Étape 4 : Créer le Mapper ──────────────────────────────────────────────
info "Création du script Mapper..."
cat > "$TMP_SCRIPTS/mapper.sh" << 'MAPPER'
#!/usr/bin/awk -f
BEGIN { OFS = "\t" }
{
    code = $8
    page = $6
    method = $5
    gsub(/"/, "", method)
    size = $9
    split($4, timeparts, ":")
    hour = timeparts[2]
    if (code ~ /^[0-9]+$/) {
        print "CODE", code, 1
        print "PAGE", page, 1
        print "METHOD", method, 1
        print "HOUR", hour, 1
        print "SIZE", code, size
    }
}
MAPPER
chmod +x "$TMP_SCRIPTS/mapper.sh"
docker cp "$TMP_SCRIPTS/mapper.sh" $NAMENODE:/tmp/mapper.sh
ok "Mapper créé."

# ─── Étape 5 : Créer le Reducer ─────────────────────────────────────────────
info "Création du script Reducer..."
cat > "$TMP_SCRIPTS/reducer.sh" << 'REDUCER'
#!/usr/bin/awk -f
BEGIN { FS = "\t"; OFS = "\t" }
{
    key = $1 OFS $2
    if (key == prev_key) {
        count += $3
    } else {
        if (prev_key != "") print prev_key, count
        prev_key = key
        count = $3
    }
}
END {
    if (prev_key != "") print prev_key, count
}
REDUCER
chmod +x "$TMP_SCRIPTS/reducer.sh"
docker cp "$TMP_SCRIPTS/reducer.sh" $NAMENODE:/tmp/reducer.sh
ok "Reducer créé."

# ─── Étape 6 : Lancer le job MapReduce ──────────────────────────────────────
info "Lancement du job MapReduce (Hadoop Streaming)..."
echo ""

docker exec $NAMENODE hdfs dfs -rm -r -f /user/root/output/results 2>/dev/null || true

docker exec $NAMENODE hadoop jar \
    /opt/hadoop-3.2.1/share/hadoop/tools/lib/hadoop-streaming-3.2.1.jar \
    -D stream.num.map.output.key.fields=2 \
    -files /tmp/mapper.sh,/tmp/reducer.sh \
    -mapper "awk -f /tmp/mapper.sh" \
    -reducer "awk -f /tmp/reducer.sh" \
    -input /user/root/input/access.log \
    -output /user/root/output/results

echo ""
ok "Job MapReduce terminé avec succès !"

# ─── Étape 7 : Récupérer les résultats ──────────────────────────────────────
info "Récupération des résultats..."
RESULTS_DIR="$(cd "$(dirname "$0")" && pwd)/results"
mkdir -p "$RESULTS_DIR"

docker exec $NAMENODE hdfs dfs -cat /user/root/output/results/part-00000 > "$RESULTS_DIR/raw_results.tsv"
ok "Résultats sauvegardés dans $RESULTS_DIR/raw_results.tsv"

# ─── Étape 8 : Parser et afficher les résultats ─────────────────────────────
info "Résumé des résultats :"
echo ""
echo -e "${CYAN}═══ Codes HTTP ═══${NC}"
grep "^CODE" "$RESULTS_DIR/raw_results.tsv" | awk -F'\t' '{printf "  %-8s %s requêtes\n", $2, $3}' | sort
echo ""
echo -e "${CYAN}═══ Top 10 Pages ═══${NC}"
grep "^PAGE" "$RESULTS_DIR/raw_results.tsv" | awk -F'\t' '{print $3"\t"$2}' | sort -rn | head -10 | awk -F'\t' '{printf "  %-30s %s requêtes\n", $2, $1}'
echo ""
echo -e "${CYAN}═══ Méthodes HTTP ═══${NC}"
grep "^METHOD" "$RESULTS_DIR/raw_results.tsv" | awk -F'\t' '{printf "  %-8s %s requêtes\n", $2, $3}' | sort
echo ""
echo -e "${CYAN}═══ Trafic par heure ═══${NC}"
grep "^HOUR" "$RESULTS_DIR/raw_results.tsv" | awk -F'\t' '{print $2"\t"$3}' | sort | awk -F'\t' '{printf "  %sh  %s requêtes\n", $1, $2}'
echo ""

# ─── Étape 9 : Générer le dashboard HTML ────────────────────────────────────
info "Génération du dashboard HTML..."

# Extraire les données en JSON
CODES_JSON=$(grep "^CODE" "$RESULTS_DIR/raw_results.tsv" | awk -F'\t' 'BEGIN{first=1}{if(!first)printf ","; printf "{\"code\":\"%s\",\"count\":%s}", $2, $3; first=0}')
PAGES_JSON=$(grep "^PAGE" "$RESULTS_DIR/raw_results.tsv" | awk -F'\t' '{print $3"\t"$2}' | sort -rn | head -15 | awk -F'\t' 'BEGIN{first=1}{if(!first)printf ","; printf "{\"page\":\"%s\",\"count\":%s}", $2, $1; first=0}')
METHODS_JSON=$(grep "^METHOD" "$RESULTS_DIR/raw_results.tsv" | awk -F'\t' 'BEGIN{first=1}{if(!first)printf ","; printf "{\"method\":\"%s\",\"count\":%s}", $2, $3; first=0}')
HOURS_JSON=$(grep "^HOUR" "$RESULTS_DIR/raw_results.tsv" | awk -F'\t' '{print $2"\t"$3}' | sort | awk -F'\t' 'BEGIN{first=1}{if(!first)printf ","; printf "{\"hour\":\"%s\",\"count\":%s}", $1, $2; first=0}')
SIZES_JSON=$(grep "^SIZE" "$RESULTS_DIR/raw_results.tsv" | awk -F'\t' 'BEGIN{first=1}{if(!first)printf ","; printf "{\"code\":\"%s\",\"total_bytes\":%s}", $2, $3; first=0}')

cat > "$RESULTS_DIR/dashboard.html" << HTMLEOF
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hadoop MapReduce — Dashboard Logs Web</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.4/dist/chart.umd.min.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
            background: #0f172a;
            color: #e2e8f0;
            min-height: 100vh;
        }
        .header {
            background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
            border-bottom: 1px solid #334155;
            padding: 1.5rem 2rem;
            display: flex;
            align-items: center;
            gap: 1rem;
        }
        .header svg { width: 40px; height: 40px; }
        .header h1 { font-size: 1.5rem; font-weight: 600; }
        .header .subtitle { color: #94a3b8; font-size: 0.875rem; margin-top: 0.25rem; }
        .stats-bar {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1rem;
            padding: 1.5rem 2rem;
        }
        .stat-card {
            background: #1e293b;
            border: 1px solid #334155;
            border-radius: 12px;
            padding: 1.25rem;
            text-align: center;
        }
        .stat-card .value {
            font-size: 2rem;
            font-weight: 700;
            background: linear-gradient(135deg, #38bdf8, #818cf8);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .stat-card .label { color: #94a3b8; font-size: 0.8rem; margin-top: 0.25rem; text-transform: uppercase; letter-spacing: 0.05em; }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(500px, 1fr));
            gap: 1.5rem;
            padding: 0 2rem 2rem;
        }
        .card {
            background: #1e293b;
            border: 1px solid #334155;
            border-radius: 12px;
            padding: 1.5rem;
        }
        .card h2 {
            font-size: 1rem;
            font-weight: 600;
            margin-bottom: 1rem;
            color: #f1f5f9;
        }
        .card canvas { max-height: 300px; }
        .table-wrap { overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; font-size: 0.875rem; }
        th { text-align: left; padding: 0.6rem 0.75rem; border-bottom: 1px solid #334155; color: #94a3b8; font-weight: 500; }
        td { padding: 0.6rem 0.75rem; border-bottom: 1px solid #1e293b; }
        tr:hover td { background: #334155; }
        .badge {
            display: inline-block;
            padding: 0.15rem 0.5rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 600;
        }
        .badge-green  { background: #064e3b; color: #34d399; }
        .badge-blue   { background: #1e3a5f; color: #60a5fa; }
        .badge-yellow { background: #713f12; color: #fbbf24; }
        .badge-red    { background: #7f1d1d; color: #f87171; }
        .footer {
            text-align: center;
            padding: 1.5rem;
            color: #475569;
            font-size: 0.8rem;
            border-top: 1px solid #1e293b;
        }
        @media (max-width: 600px) {
            .grid { grid-template-columns: 1fr; padding: 0 1rem 1rem; }
            .stats-bar { padding: 1rem; }
        }
    </style>
</head>
<body>

<div class="header">
    <svg viewBox="0 0 40 40" fill="none"><rect rx="8" width="40" height="40" fill="#3b82f6"/><text x="50%" y="55%" dominant-baseline="middle" text-anchor="middle" fill="white" font-size="18" font-weight="bold">H</text></svg>
    <div>
        <h1>Hadoop MapReduce — Analyse de Logs Web</h1>
        <div class="subtitle">10 000 requêtes analysées via HDFS + Hadoop Streaming</div>
    </div>
</div>

<div class="stats-bar" id="stats-bar"></div>

<div class="grid">
    <div class="card">
        <h2>Répartition des codes HTTP</h2>
        <canvas id="codesChart"></canvas>
    </div>
    <div class="card">
        <h2>Méthodes HTTP</h2>
        <canvas id="methodsChart"></canvas>
    </div>
    <div class="card">
        <h2>Trafic par heure</h2>
        <canvas id="hoursChart"></canvas>
    </div>
    <div class="card">
        <h2>Volume transféré par code HTTP (octets)</h2>
        <canvas id="sizesChart"></canvas>
    </div>
    <div class="card" style="grid-column: 1 / -1;">
        <h2>Top 15 des pages les plus visitées</h2>
        <canvas id="pagesChart"></canvas>
    </div>
    <div class="card" style="grid-column: 1 / -1;">
        <h2>Détail complet des résultats</h2>
        <div class="table-wrap">
            <table id="detail-table">
                <thead><tr><th>Catégorie</th><th>Clé</th><th>Valeur</th></tr></thead>
                <tbody></tbody>
            </table>
        </div>
    </div>
</div>

<div class="footer">
    Généré automatiquement par <strong>run-cas-pratique.sh</strong> — Hadoop 3.2.1 / Docker Compose
</div>

<script>
const codes = [${CODES_JSON}];
const pages = [${PAGES_JSON}];
const methods = [${METHODS_JSON}];
const hours = [${HOURS_JSON}];
const sizes = [${SIZES_JSON}];

Chart.defaults.color = '#94a3b8';
Chart.defaults.borderColor = '#334155';

// Stats bar
const totalRequests = codes.reduce((s, c) => s + c.count, 0);
const successRate = codes.filter(c => c.code.startsWith('2')).reduce((s, c) => s + c.count, 0);
const errorRate = codes.filter(c => c.code.startsWith('5')).reduce((s, c) => s + c.count, 0);
const totalBytes = sizes.reduce((s, c) => s + c.total_bytes, 0);

const statsBar = document.getElementById('stats-bar');
[
    { value: totalRequests.toLocaleString(), label: 'Total requêtes' },
    { value: (successRate / totalRequests * 100).toFixed(1) + '%', label: 'Taux de succès (2xx)' },
    { value: errorRate.toLocaleString(), label: 'Erreurs serveur (5xx)' },
    { value: (totalBytes / 1048576).toFixed(1) + ' Mo', label: 'Volume total transféré' },
    { value: codes.length, label: 'Codes HTTP distincts' },
    { value: pages.length, label: 'Pages analysées (top)' }
].forEach(s => {
    statsBar.innerHTML += '<div class="stat-card"><div class="value">' + s.value + '</div><div class="label">' + s.label + '</div></div>';
});

// Codes chart
const codeColors = codes.map(c => {
    if (c.code.startsWith('2')) return '#34d399';
    if (c.code.startsWith('3')) return '#60a5fa';
    if (c.code.startsWith('4')) return '#fbbf24';
    return '#f87171';
});
new Chart(document.getElementById('codesChart'), {
    type: 'doughnut',
    data: { labels: codes.map(c => c.code), datasets: [{ data: codes.map(c => c.count), backgroundColor: codeColors, borderWidth: 0 }] },
    options: { plugins: { legend: { position: 'bottom' } } }
});

// Methods chart
const methodColors = ['#38bdf8', '#818cf8', '#f472b6', '#fb923c', '#a3e635', '#e879f9', '#facc15'];
new Chart(document.getElementById('methodsChart'), {
    type: 'pie',
    data: { labels: methods.map(m => m.method), datasets: [{ data: methods.map(m => m.count), backgroundColor: methodColors.slice(0, methods.length), borderWidth: 0 }] },
    options: { plugins: { legend: { position: 'bottom' } } }
});

// Hours chart
new Chart(document.getElementById('hoursChart'), {
    type: 'bar',
    data: { labels: hours.map(h => h.hour + 'h'), datasets: [{ label: 'Requêtes', data: hours.map(h => h.count), backgroundColor: '#3b82f6', borderRadius: 4 }] },
    options: { plugins: { legend: { display: false } }, scales: { y: { beginAtZero: true } } }
});

// Sizes chart
const sizeColors = sizes.map(c => {
    if (c.code.startsWith('2')) return '#34d399';
    if (c.code.startsWith('3')) return '#60a5fa';
    if (c.code.startsWith('4')) return '#fbbf24';
    return '#f87171';
});
new Chart(document.getElementById('sizesChart'), {
    type: 'bar',
    data: { labels: sizes.map(s => s.code), datasets: [{ label: 'Octets', data: sizes.map(s => s.total_bytes), backgroundColor: sizeColors, borderRadius: 4 }] },
    options: { plugins: { legend: { display: false } }, scales: { y: { beginAtZero: true } } }
});

// Pages chart
new Chart(document.getElementById('pagesChart'), {
    type: 'bar',
    data: { labels: pages.map(p => p.page), datasets: [{ label: 'Requêtes', data: pages.map(p => p.count), backgroundColor: '#818cf8', borderRadius: 4 }] },
    options: { indexAxis: 'y', plugins: { legend: { display: false } }, scales: { x: { beginAtZero: true } } }
});

// Detail table
const tbody = document.querySelector('#detail-table tbody');
function badgeClass(cat, key) {
    if (cat === 'CODE') {
        if (key.startsWith('2')) return 'badge-green';
        if (key.startsWith('3')) return 'badge-blue';
        if (key.startsWith('4')) return 'badge-yellow';
        return 'badge-red';
    }
    return 'badge-blue';
}
function addRows(data, cat, keyField, valField) {
    data.forEach(d => {
        const key = d[keyField];
        const val = d[valField];
        tbody.innerHTML += '<tr><td>' + cat + '</td><td><span class="badge ' + badgeClass(cat, String(key)) + '">' + key + '</span></td><td>' + Number(val).toLocaleString() + '</td></tr>';
    });
}
addRows(codes, 'Code HTTP', 'code', 'count');
addRows(methods, 'Méthode', 'method', 'count');
addRows(pages, 'Page (Top 15)', 'page', 'count');
addRows(sizes, 'Volume (octets)', 'code', 'total_bytes');
</script>
</body>
</html>
HTMLEOF

ok "Dashboard HTML généré : $RESULTS_DIR/dashboard.html"

# ─── Étape 10 : Servir le dashboard ─────────────────────────────────────────
info "Démarrage du serveur web sur le port ${DASHBOARD_PORT}..."
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║   Dashboard disponible sur :                                 ║${NC}"
echo -e "${GREEN}║   ${CYAN}http://localhost:${DASHBOARD_PORT}/dashboard.html${GREEN}                 ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║   Appuyez sur Ctrl+C pour arrêter le serveur                 ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

rm -rf "$TMP_SCRIPTS"

cd "$RESULTS_DIR"
python3 -m http.server $DASHBOARD_PORT
