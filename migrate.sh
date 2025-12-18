#!/bin/bash
# Migration script for Ghost JPS (old structure -> new official ghost-docker structure)

TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_DIR="backup_$TIMESTAMP"
GHOST_DIR="/root/ghost"

echo "Starting migration..."

# Verification
if [ ! -f "$GHOST_DIR/docker-compose.yml" ]; then
    echo "Error: Old docker-compose.yml not found in $GHOST_DIR. Are you sure you are in the right place?"
    exit 1
fi

cd "$GHOST_DIR" || exit 1

echo "Backing up database..."

# Dump database from the old 'db' container
container_id=$(docker ps -qf "name=ghost-db" -f "name=db" | head -n 1) # Trying generic name or name in jps

docker compose exec db mysqldump -u root -p${ROOTDB_PASSWORD} --all-databases > "$GHOST_DIR/dump.sql" || {
    echo "Warning: Database dump failed using 'docker compose exec'. Trying 'docker-compose'..."
    docker-compose exec db mysqldump -u root -p${ROOTDB_PASSWORD} --all-databases > "$GHOST_DIR/dump.sql"
}

if [ ! -f "$GHOST_DIR/dump.sql" ]; then
    echo "CRITICAL: Database backup failed. Aborting."
    exit 1
fi

echo "Stopping old containers..."
docker compose down || docker-compose down

# Move contentes of $GHOST_DIR (including dotfiles) to backup directory
cd /root || exit 1
mv "$GHOST_DIR" "$BACKUP_DIR"

# Set up new install
mkdir "$GHOST_DIR"
cd "$GHOST_DIR" || exit 1

# create symlink from $GHOST_DIR to /opt/ghost
ln -s $GHOST_DIR /opt/ghost


echo "Cloning official ghost-docker repo..."
git clone https://github.com/TryGhost/ghost-docker.git .

echo "Restoring content..."
mkdir -p data/ghost
cp -r "$BACKUP_DIR/content/"* data/ghost/

echo "Configuring new environment..."
cp .env.example .env
cp caddy/Caddyfile.example caddy/Caddyfile

# Extract variables from old .env (stored in backup)
OLD_ENV="$BACKUP_DIR/.env"
DOMAIN=$(grep "^URL=" "$OLD_ENV" | cut -d'=' -f2 | sed 's|https://||')
if [ -z "$DOMAIN" ]; then DOMAIN=$(grep "^LETSENCRYPT_DOMAINS=" "$OLD_ENV" | cut -d'=' -f2); fi

# Mail settings
MAIL_HOST=$(grep "^MAIL_HOST=" "$OLD_ENV" | cut -d'=' -f2)
MAIL_USER=$(grep "^MAIL_USER=" "$OLD_ENV" | cut -d'=' -f2)
MAIL_PASS=$(grep "^MAIL_PASS=" "$OLD_ENV" | cut -d'=' -f2)
MAIL_FROM=$(grep "^MAIL_FROM=" "$OLD_ENV" | cut -d'=' -f2)

OLD_GHOST_DB_PASS=$(grep "^GHOSTDB_PASSWORD=" "$OLD_ENV" | cut -d'=' -f2)
OLD_ROOT_DB_PASS=$(grep "^ROOTDB_PASSWORD=" "$OLD_ENV" | cut -d'=' -f2)

# Update new .env
sed -i "s|DOMAIN=example.com|DOMAIN=$DOMAIN|g" .env
sed -i "s|DATABASE_ROOT_PASSWORD=reallysecurerootpassword|DATABASE_ROOT_PASSWORD=$OLD_ROOT_DB_PASS|g" .env
sed -i "s|DATABASE_PASSWORD=ghostpassword|DATABASE_PASSWORD=$OLD_GHOST_DB_PASS|g" .env

# Mail
sed -i "s|mail__options__host=smtp.example.com|mail__options__host=$MAIL_HOST|g" .env
sed -i "s|mail__options__auth__user=support@example.com|mail__options__auth__user=$MAIL_USER|g" .env
sed -i "s|mail__options__auth__pass=1234567890|mail__options__auth__pass=$MAIL_PASS|g" .env
sed -i "s|mail__from=\"'Acme Support' <support@example.com>\"|mail__from=\"$MAIL_FROM\"|g" .env

# Enable ActivityPub
sed -i 's|# COMPOSE_PROFILES=analytics,activitypub|COMPOSE_PROFILES=activitypub|g' .env
sed -i 's|# ACTIVITYPUB_TARGET=activitypub:8080|ACTIVITYPUB_TARGET=activitypub:8080|g' .env

echo "Starting new stack..."
docker compose up -d

echo "Waiting for database to initialize (20s)..."
sleep 20

echo "Importing database dump..."
docker compose exec -T db mysql -u root -p$OLD_ROOT_DB_PASS < "$BACKUP_DIR/dump.sql"

echo "Restarting ghost to ensure it picks up the DB..."
docker compose restart ghost

echo "Migration complete!"
echo "Backup stored in $BACKUP_DIR"
