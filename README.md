# Cluster Hadoop avec Docker

Déploiement d'un cluster Apache Hadoop (HDFS + YARN) via Docker Compose.

## Architecture

| Service            | Image                                                  | Ports exposés        | Rôle                                      |
|--------------------|--------------------------------------------------------|----------------------|-------------------------------------------|
| **namenode**       | bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8       | 9870, 9010→9000      | Gère les métadonnées HDFS                 |
| **datanode**       | bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java8       | 9864 (interne)       | Stocke les blocs de données HDFS          |
| **resourcemanager**| bde2020/hadoop-resourcemanager:2.0.0-hadoop3.2.1-java8| 8088                 | Gère les ressources YARN                  |
| **nodemanager**    | bde2020/hadoop-nodemanager:2.0.0-hadoop3.2.1-java8    | 8042 (interne)       | Exécute les tâches sur les nœuds          |

## Prérequis

- **Docker** ≥ 20.x
- **Docker Compose** (plugin `docker compose` v2)
- ~4 Go de RAM disponible
- Ports **9870**, **9010** et **8088** libres sur la machine hôte

### Vérifier l'installation de Docker

```bash
docker --version
docker compose version
```

## Installation et démarrage

### 1. Cloner le dépôt

```bash
git clone https://github.com/Achaire-Zogo/hadoop.git
cd hadoop
```

### 2. Lancer le cluster

```bash
docker compose up -d
```

### 3. Vérifier que tous les conteneurs tournent

```bash
docker ps
```

Vous devez voir 4 conteneurs avec le statut **Up** :
- `namenode`
- `datanode`
- `resourcemanager`
- `nodemanager`

### 4. Attendre l'initialisation

Les conteneurs passent par un état `(health: starting)` pendant ~30 secondes.
Attendez que le health check passe à `(healthy)` :

```bash
# Vérifier les logs du namenode
docker logs namenode --tail 20
```

## Interfaces Web

| Interface                  | URL                          |
|----------------------------|------------------------------|
| **HDFS NameNode**          | http://localhost:9870        |
| **YARN ResourceManager**   | http://localhost:8088        |

## Commandes utiles

```bash
# Arrêter le cluster
docker compose down

# Arrêter et supprimer les volumes (⚠️ perte de données)
docker compose down -v

# Voir les logs d'un service
docker logs -f namenode
docker logs -f datanode

# Exécuter une commande dans le namenode
docker exec -it namenode bash

# Vérifier l'état de HDFS
docker exec -it namenode hdfs dfsadmin -report
```

## Résolution de problèmes

### Port 9000 déjà utilisé

Si le port 9000 est pris par un autre service (ex : Portainer), le mapping
hôte est configuré sur **9010** → 9000. La communication interne entre
conteneurs n'est pas affectée.

### Le datanode ne se connecte pas au namenode

```bash
docker logs datanode --tail 50
```

Vérifiez que le namenode est bien démarré et que le réseau Docker est créé :

```bash
docker network ls | grep hadoop
```

### Réinitialiser le cluster

```bash
docker compose down -v
docker compose up -d
```
