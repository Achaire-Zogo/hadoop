# Cas Pratique : Analyse de logs web avec Hadoop (HDFS + MapReduce)

Ce guide vous accompagne pas à pas dans un cas d'utilisation réel de Hadoop :
**analyser des logs d'accès d'un serveur web** pour compter le nombre de visites par code HTTP (200, 404, 500…).

---

## Étape 1 — Se connecter au conteneur namenode

Toutes les commandes HDFS s'exécutent depuis le namenode :

```bash
docker exec -it namenode bash
```

---

## Étape 2 — Vérifier l'état du cluster HDFS

```bash
hdfs dfsadmin -report
```

### Résultat attendu

```
Configured Capacity: ...
DFS Used: ...
DFS Remaining: ...
Live datanodes (1):

Name: 172.x.x.x:9866 (datanode.hadoop_default)
...
```

> Vous devez voir **1 Live datanode**. Si c'est 0, le datanode n'est pas encore prêt (attendez quelques secondes).

---

## Étape 3 — Créer la structure de répertoires dans HDFS

```bash
hdfs dfs -mkdir -p /user/root/input
hdfs dfs -mkdir -p /user/root/output
```

### Vérification

```bash
hdfs dfs -ls /user/root/
```

### Résultat attendu

```
Found 2 items
drwxr-xr-x   - root supergroup          0 2026-03-25 04:50 /user/root/input
drwxr-xr-x   - root supergroup          0 2026-03-25 04:50 /user/root/output
```

---

## Étape 4 — Créer un fichier de données (logs web simulés)

On génère un fichier de logs directement dans le conteneur :

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

---

## Étape 5 — Charger le fichier dans HDFS

```bash
hdfs dfs -put /tmp/access.log /user/root/input/
```

### Vérification

```bash
hdfs dfs -ls /user/root/input/
```

### Résultat attendu

```
Found 1 items
-rw-r--r--   3 root supergroup        756 2026-03-25 04:51 /user/root/input/access.log
```

### Lire le contenu du fichier dans HDFS

```bash
hdfs dfs -cat /user/root/input/access.log
```

> Vous devez voir les 12 lignes de logs.

---

## Étape 6 — Manipulations HDFS courantes

### 6.1 — Copier un fichier dans HDFS

```bash
hdfs dfs -cp /user/root/input/access.log /user/root/input/access_backup.log
```

### 6.2 — Voir la taille des fichiers

```bash
hdfs dfs -du -h /user/root/input/
```

### Résultat attendu

```
756  2.2 K  /user/root/input/access.log
756  2.2 K  /user/root/input/access_backup.log
```

### 6.3 — Compter les lignes du fichier

```bash
hdfs dfs -cat /user/root/input/access.log | wc -l
```

### Résultat attendu

```
12
```

### 6.4 — Supprimer un fichier

```bash
hdfs dfs -rm /user/root/input/access_backup.log
```

### Résultat attendu

```
Deleted /user/root/input/access_backup.log
```

---

## Étape 7 — Exécuter un job MapReduce (Hadoop Streaming)

On utilise **Hadoop Streaming** pour lancer un job MapReduce avec des scripts shell simples.

### 7.1 — Créer le script Mapper

```bash
cat > /tmp/mapper.sh << 'MAPPER'
#!/bin/bash
# Mapper : extrait le code HTTP de chaque ligne de log
while read line; do
    # Le code HTTP est le 9e champ (séparé par des espaces)
    code=$(echo "$line" | awk '{print $9}')
    if [ -n "$code" ]; then
        echo -e "${code}\t1"
    fi
done
MAPPER
chmod +x /tmp/mapper.sh
```

### 7.2 — Créer le script Reducer

```bash
cat > /tmp/reducer.sh << 'REDUCER'
#!/bin/bash
# Reducer : additionne les occurrences de chaque code HTTP
current_code=""
count=0

while IFS=$'\t' read -r code val; do
    if [ "$code" = "$current_code" ]; then
        count=$((count + val))
    else
        if [ -n "$current_code" ]; then
            echo -e "${current_code}\t${count}"
        fi
        current_code="$code"
        count=$val
    fi
done

# Dernière clé
if [ -n "$current_code" ]; then
    echo -e "${current_code}\t${count}"
fi
REDUCER
chmod +x /tmp/reducer.sh
```

### 7.3 — Tester localement (sans Hadoop)

```bash
cat /tmp/access.log | /tmp/mapper.sh | sort | /tmp/reducer.sh
```

### Résultat attendu

```
200	6
403	1
404	2
500	2
```

> **6** requêtes 200 OK, **1** requête 403 Forbidden, **2** requêtes 404 Not Found, **2** requêtes 500 Internal Server Error.

### 7.4 — Supprimer le dossier output s'il existe

```bash
hdfs dfs -rm -r /user/root/output
```

### 7.5 — Lancer le job MapReduce

```bash
hadoop jar /opt/hadoop-3.2.1/share/hadoop/tools/lib/hadoop-streaming-3.2.1.jar \
    -files /tmp/mapper.sh,/tmp/reducer.sh \
    -mapper /tmp/mapper.sh \
    -reducer /tmp/reducer.sh \
    -input /user/root/input/access.log \
    -output /user/root/output/http-codes
```

### Résultat attendu (logs du job)

```
...
INFO mapreduce.Job: Running job: job_xxxx
INFO mapreduce.Job: Job job_xxxx completed successfully
INFO mapreduce.Job:  map 100% reduce 100%
...
```

### 7.6 — Lire le résultat du job

```bash
hdfs dfs -cat /user/root/output/http-codes/part-00000
```

### Résultat attendu

```
200	6
403	1
404	2
500	2
```

---

## Étape 8 — Exploration des résultats

### 8.1 — Lister les fichiers de sortie

```bash
hdfs dfs -ls /user/root/output/http-codes/
```

### Résultat attendu

```
Found 2 items
-rw-r--r--   3 root supergroup          0 2026-03-25 ... /user/root/output/http-codes/_SUCCESS
-rw-r--r--   3 root supergroup         24 2026-03-25 ... /user/root/output/http-codes/part-00000
```

> `_SUCCESS` confirme que le job s'est terminé correctement.
> `part-00000` contient les résultats.

### 8.2 — Récupérer les résultats en local

```bash
hdfs dfs -get /user/root/output/http-codes/part-00000 /tmp/resultats.txt
cat /tmp/resultats.txt
```

---

## Étape 9 — Monitorer via les interfaces web

### HDFS NameNode (http://localhost:9870)

- Onglet **Overview** : état du cluster, capacité, datanodes actifs
- Onglet **Utilities > Browse the file system** : naviguer dans HDFS
  - Aller dans `/user/root/input/` pour voir `access.log`
  - Aller dans `/user/root/output/http-codes/` pour voir les résultats

### YARN ResourceManager (http://localhost:8088)

- Voir la liste des **applications** (votre job MapReduce)
- Cliquer sur l'application pour voir :
  - Le statut (**SUCCEEDED**)
  - Le nombre de mappers et reducers
  - Le temps d'exécution
  - Les logs d'exécution

---

## Étape 10 — Nettoyage

```bash
# Supprimer les données dans HDFS
hdfs dfs -rm -r /user/root/input
hdfs dfs -rm -r /user/root/output

# Quitter le conteneur
exit

# Arrêter le cluster (depuis la machine hôte)
docker compose down
```

---

## Récapitulatif des commandes HDFS essentielles

| Commande                              | Description                          |
|---------------------------------------|--------------------------------------|
| `hdfs dfs -ls <path>`                | Lister les fichiers                  |
| `hdfs dfs -mkdir -p <path>`          | Créer un répertoire                  |
| `hdfs dfs -put <local> <hdfs>`       | Envoyer un fichier vers HDFS         |
| `hdfs dfs -get <hdfs> <local>`       | Télécharger un fichier depuis HDFS   |
| `hdfs dfs -cat <path>`              | Afficher le contenu d'un fichier     |
| `hdfs dfs -cp <src> <dst>`          | Copier un fichier dans HDFS          |
| `hdfs dfs -mv <src> <dst>`          | Déplacer/renommer un fichier         |
| `hdfs dfs -rm <path>`               | Supprimer un fichier                 |
| `hdfs dfs -rm -r <path>`            | Supprimer un répertoire              |
| `hdfs dfs -du -h <path>`            | Taille des fichiers                  |
| `hdfs dfs -chmod <mode> <path>`     | Changer les permissions              |
| `hdfs dfsadmin -report`             | Rapport d'état du cluster            |
