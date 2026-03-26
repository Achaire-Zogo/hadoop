# Cas Pratique : Analyse de logs web avec Hadoop

## Objectif

Analyser des **logs d'accès d'un serveur web** avec un cluster Hadoop Docker pour :

- Compter les requêtes par **code HTTP** (200, 301, 404, 500…)
- Identifier les **pages les plus visitées**
- Répartir le trafic par **méthode HTTP** et par **heure**

> **Prérequis** : le cluster doit être démarré (`docker compose up -d`).
> Consultez le fichier `README.md` pour l'installation.

---

## Partie 1 — Prise en main de HDFS

### 1.1 — Se connecter au namenode

Toutes les commandes HDFS s'exécutent depuis le conteneur **namenode** :

```bash
docker exec -it namenode bash
```

### 1.2 — Vérifier l'état du cluster

```bash
hdfs dfsadmin -report
```

**Résultat attendu :**

```
Configured Capacity: 51221196800 (47.71 GB)
DFS Used: 4096 (4 KB)
DFS Remaining: 42697302016 (39.77 GB)
...
Live datanodes (1):

Name: 172.x.x.x:9866 (datanode.hadoop_default)
```

> Vous devez voir **1 Live datanode**. Si c'est 0, patientez ~30 secondes que le datanode s'enregistre.

### 1.3 — Créer des répertoires

```bash
hdfs dfs -mkdir -p /user/root/input
hdfs dfs -mkdir -p /user/root/output
```

**Vérification :**

```bash
hdfs dfs -ls /user/root/
```

```
Found 2 items
drwxr-xr-x   - root supergroup   0 ...  /user/root/input
drwxr-xr-x   - root supergroup   0 ...  /user/root/output
```

---

## Partie 2 — Charger des données dans HDFS

### 2.1 — Créer un fichier de logs simulés

```bash
cat > /tmp/access.log << 'EOF'
192.168.1.10 - - [25/Mar/2026:10:00:01] "GET /index.html HTTP/1.1" 200 1024
192.168.1.11 - - [25/Mar/2026:10:00:02] "GET /about.html HTTP/1.1" 200 2048
192.168.1.12 - - [25/Mar/2026:10:00:03] "GET /missing.html HTTP/1.1" 404 512
192.168.1.10 - - [25/Mar/2026:10:00:04] "POST /login HTTP/1.1" 200 128
192.168.1.13 - - [25/Mar/2026:10:00:05] "GET /index.html HTTP/1.1" 200 1024
192.168.1.14 - - [25/Mar/2026:10:00:06] "GET /admin HTTP/1.1" 403 256
192.168.1.15 - - [25/Mar/2026:10:00:07] "GET /api/data HTTP/1.1" 500 64
192.168.1.10 - - [25/Mar/2026:10:00:08] "GET /index.html HTTP/1.1" 200 1024
192.168.1.16 - - [25/Mar/2026:10:00:09] "GET /old-page HTTP/1.1" 404 512
192.168.1.17 - - [25/Mar/2026:10:00:10] "GET /contact.html HTTP/1.1" 200 768
192.168.1.18 - - [25/Mar/2026:10:00:11] "GET /api/crash HTTP/1.1" 500 64
192.168.1.19 - - [25/Mar/2026:10:00:12] "GET /dashboard HTTP/1.1" 200 4096
EOF
```

Chaque ligne suit le format **Apache Combined Log** :

```
IP - - [DATE:HEURE] "MÉTHODE PAGE PROTOCOLE" CODE TAILLE
$1  $2 $3 $4        $5       $6   $7         $8   $9
```

> Les champs `$1` à `$9` sont séparés par des espaces. Le **code HTTP** est en `$8` et la **taille** en `$9`.

### 2.2 — Envoyer le fichier dans HDFS

```bash
hdfs dfs -put /tmp/access.log /user/root/input/
```

**Vérification :**

```bash
hdfs dfs -ls /user/root/input/
```

```
Found 1 items
-rw-r--r--   3 root supergroup   756 ...  /user/root/input/access.log
```

### 2.3 — Lire le fichier depuis HDFS

```bash
hdfs dfs -cat /user/root/input/access.log
```

> Les 12 lignes de logs doivent s'afficher.

---

## Partie 3 — Manipulations HDFS courantes

### 3.1 — Copier un fichier

```bash
hdfs dfs -cp /user/root/input/access.log /user/root/input/access_backup.log
```

### 3.2 — Voir la taille des fichiers

```bash
hdfs dfs -du -h /user/root/input/
```

```
756  2.2 K  /user/root/input/access.log
756  2.2 K  /user/root/input/access_backup.log
```

### 3.3 — Compter les lignes

```bash
hdfs dfs -cat /user/root/input/access.log | wc -l
```

```
12
```

### 3.4 — Supprimer un fichier

```bash
hdfs dfs -rm /user/root/input/access_backup.log
```

```
Deleted /user/root/input/access_backup.log
```

---

## Partie 4 — Job MapReduce avec Hadoop Streaming

**Hadoop Streaming** permet d'écrire des jobs MapReduce dans n'importe quel langage
(shell, Python, awk…). Le principe :

1. Le **Mapper** lit chaque ligne en entrée et émet des paires `clé<TAB>valeur`
2. Hadoop **trie** automatiquement les paires par clé
3. Le **Reducer** reçoit les paires triées et agrège les valeurs par clé

### 4.1 — Créer le Mapper (awk)

Le mapper extrait le code HTTP (champ `$8`) de chaque ligne de log :

```bash
cat > /tmp/mapper.awk << 'MAPPER'
BEGIN { OFS = "\t" }
{
    code = $8
    if (code ~ /^[0-9]+$/) {
        print code, 1
    }
}
MAPPER
```

**Test local :**

```bash
awk -f /tmp/mapper.awk /tmp/access.log
```

```
200	1
200	1
404	1
200	1
200	1
403	1
500	1
200	1
404	1
200	1
500	1
200	1
```

> Chaque ligne de log produit une paire `CODE<TAB>1`.

### 4.2 — Créer le Reducer (awk)

Le reducer reçoit les paires triées par Hadoop et additionne les compteurs :

```bash
cat > /tmp/reducer.awk << 'REDUCER'
BEGIN { FS = "\t"; OFS = "\t" }
{
    if ($1 == prev) {
        count += $2
    } else {
        if (prev != "") print prev, count
        prev = $1
        count = $2
    }
}
END {
    if (prev != "") print prev, count
}
REDUCER
```

### 4.3 — Tester le pipeline complet en local

```bash
awk -f /tmp/mapper.awk /tmp/access.log | sort | awk -f /tmp/reducer.awk
```

**Résultat attendu :**

```
200	6
403	1
404	2
500	2
```

> **6** requêtes `200 OK`, **1** requête `403 Forbidden`, **2** requêtes `404 Not Found`, **2** requêtes `500 Internal Server Error`.

### 4.4 — Lancer le job sur le cluster Hadoop

```bash
hdfs dfs -rm -r -f /user/root/output/http-codes

hadoop jar /opt/hadoop-3.2.1/share/hadoop/tools/lib/hadoop-streaming-3.2.1.jar \
    -files /tmp/mapper.awk,/tmp/reducer.awk \
    -mapper "awk -f /tmp/mapper.awk" \
    -reducer "awk -f /tmp/reducer.awk" \
    -input /user/root/input/access.log \
    -output /user/root/output/http-codes
```

**Résultat attendu dans les logs :**

```
INFO mapreduce.Job: Running job: job_local...
INFO mapreduce.Job:  map 100% reduce 100%
INFO mapreduce.Job: Job job_local... completed successfully
```

### 4.5 — Lire les résultats du job

```bash
hdfs dfs -cat /user/root/output/http-codes/part-00000
```

```
200	6
403	1
404	2
500	2
```

---

## Partie 5 — Explorer les résultats

### 5.1 — Lister les fichiers de sortie

```bash
hdfs dfs -ls /user/root/output/http-codes/
```

```
Found 2 items
-rw-r--r--   3 root supergroup    0 ...  /user/root/output/http-codes/_SUCCESS
-rw-r--r--   3 root supergroup   24 ...  /user/root/output/http-codes/part-00000
```

- `_SUCCESS` : confirme que le job s'est terminé correctement
- `part-00000` : contient les résultats agrégés

### 5.2 — Récupérer les résultats en local

```bash
hdfs dfs -get /user/root/output/http-codes/part-00000 /tmp/resultats.txt
cat /tmp/resultats.txt
```

---

## Partie 6 — Interfaces de monitoring web

### HDFS NameNode — http://localhost:9870

| Onglet                             | Ce qu'on y voit                                |
|------------------------------------|------------------------------------------------|
| **Overview**                       | État du cluster, capacité, datanodes actifs     |
| **Utilities > Browse the file system** | Naviguer dans HDFS, voir les fichiers      |

> Naviguez vers `/user/root/input/` et `/user/root/output/http-codes/` pour voir vos données.

### YARN ResourceManager — http://localhost:8088

| Section                            | Ce qu'on y voit                                |
|------------------------------------|------------------------------------------------|
| **Applications**                   | Liste des jobs MapReduce exécutés              |
| **Détail d'une application**       | Statut, nombre de mappers/reducers, durée, logs|

---

## Partie 7 — Exécution automatisée (script batch)

Pour aller plus loin avec **10 000 lignes de logs** et un **dashboard visuel** dans le navigateur :

```bash
# Depuis la machine hôte (pas dans le conteneur)
bash run-cas-pratique.sh
```

Ce script automatise toutes les étapes :
1. Vérifie que le cluster est actif
2. Génère 10 000 lignes de logs simulés (codes 200/301/403/404/500/502)
3. Charge les données dans HDFS
4. Exécute un job MapReduce multi-dimensions (codes, pages, méthodes, heures, tailles)
5. Génère un **dashboard HTML interactif** avec des graphiques (Chart.js)
6. Lance un serveur web local sur http://localhost:8888/dashboard.html

---

## Partie 8 — Nettoyage

```bash
# Dans le conteneur namenode
hdfs dfs -rm -r /user/root/input
hdfs dfs -rm -r /user/root/output
exit

# Depuis la machine hôte
docker compose down
```

Pour supprimer aussi les **volumes** (données HDFS persistées) :

```bash
docker compose down -v
```

---

## Récapitulatif des commandes HDFS

| Commande                          | Description                           |
|-----------------------------------|---------------------------------------|
| `hdfs dfs -ls <path>`            | Lister les fichiers                   |
| `hdfs dfs -mkdir -p <path>`      | Créer un répertoire                   |
| `hdfs dfs -put <local> <hdfs>`   | Envoyer un fichier vers HDFS          |
| `hdfs dfs -get <hdfs> <local>`   | Télécharger un fichier depuis HDFS    |
| `hdfs dfs -cat <path>`           | Afficher le contenu d'un fichier      |
| `hdfs dfs -cp <src> <dst>`       | Copier un fichier dans HDFS           |
| `hdfs dfs -mv <src> <dst>`       | Déplacer / renommer un fichier        |
| `hdfs dfs -rm <path>`            | Supprimer un fichier                  |
| `hdfs dfs -rm -r <path>`         | Supprimer un répertoire               |
| `hdfs dfs -du -h <path>`         | Taille des fichiers                   |
| `hdfs dfs -chmod <mode> <path>`  | Changer les permissions               |
| `hdfs dfsadmin -report`          | Rapport d'état du cluster             |
