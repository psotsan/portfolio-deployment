#!/usr/bin/env bash
set -euo pipefail

# --------------- error handling ---------------
handle_error() {
  local exit_code=$?
  local line_no=$1
  echo "[ERROR] deploy.sh - line ${line_no}: "
  echo "       command ended with code ${exit_code}"
  exit "${exit_code}"
}
trap 'handle_error $LINENO' ERR

# --------------- generate secret key ---------------
generate_secret_key() {
  python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits + string.punctuation
print(''.join(secrets.choice(chars) for _ in range(50)))
"
}

# --------------- prompt & write .env ---------------
declare -a VAR_NAMES=(
  "DJANGO_ALLOWED_HOSTS"
  "PERSONAL_NAME"
  "PERSONAL_EMAIL"
  "PERSONAL_GITHUB"
  "PERSONAL_LINKEDIN"
  "AWS_STORAGE_BUCKET_NAME"
  "AWS_S3_REGION_NAME"
)

declare -a SUPERUSER_VARS=(
  "DJANGO_SUPERUSER_USERNAME"
  "DJANGO_SUPERUSER_EMAIL"
  "DJANGO_SUPERUSER_PASSWORD"
)

write_env() {
  local var val
  local secret_key
  local env_content=""

  secret_key=$(generate_secret_key)
  env_content+="DJANGO_SECRET_KEY='${secret_key}'"$'\n'

  for var in "${VAR_NAMES[@]}"; do
    while true; do
      read -r -p "  ${var}: " val
      [ -n "$val" ] && break
      echo "  [WARN] no puede estar vacio"
    done
    if [ "$var" = "DJANGO_ALLOWED_HOSTS" ]; then
      env_content+="${var}=${val}"$'\n'
    else
      env_content+="${var}='${val}'"$'\n'
    fi
  done
  env_content+="DJANGO_DEBUG=False"$'\n'
  env_content+="SECURE_HSTS_SECONDS=31536000"$'\n'
  env_content+="SECURE_SSL_REDIRECT=True"$'\n'
  env_content+="SESSION_COOKIE_SECURE=True"$'\n'
  env_content+="CSRF_COOKIE_SECURE=True"$'\n'

  echo ""
  echo "--- Superusuario Django ---"
  echo "(se guardara en .env para referencia)"
  for var in "${SUPERUSER_VARS[@]}"; do
    while true; do
      read -r -p "  ${var}: " val
      [ -n "$val" ] && break
      echo "  [WARN] no puede estar vacio"
    done
    env_content+="${var}='${val}'"$'\n'
  done

  printf "%s" "$env_content" > ~/.env
  echo "[OK] .env create in ~/.env"
}

# ------------------ main ------------------

sudo apt update && sudo apt upgrade -y
sudo apt install python3-pip python3-dev python3-venv nginx curl git certbot python3-certbot-nginx -y
cd ~
git clone https://github.com/psotsan/portfolio
write_env
cd portfolio
ln -sf ~/.env .env
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r portfolio/requirements.txt
set -a && source ~/.env && set +a
python manage.py collectstatic --noinput
python manage.py migrate
export DJANGO_SUPERUSER_USERNAME DJANGO_SUPERUSER_EMAIL DJANGO_SUPERUSER_PASSWORD
python manage.py createsuperuser --noinput || true
sudo mkdir -p /var/log/gunicorn
sudo chown -R ubuntu:www-data /var/log/gunicorn
sudo tee /etc/systemd/system/gunicorn.service << 'EOF'
[Unit]
Description=Gunicorn daemon for Django portfolio
After=network.target

[Service]
User=ubuntu
Group=www-data
WorkingDirectory=/home/ubuntu/portfolio
EnvironmentFile=/home/ubuntu/.env
Environment="PATH=/home/ubuntu/portfolio/venv/bin"
ExecStart=/home/ubuntu/portfolio/venv/bin/gunicorn --config /home/ubuntu/portfolio/gunicorn_config.py portfolio.wsgi:application

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now gunicorn
sleep 2

DJANGO_ALLOWED_HOSTS=$(grep "^DJANGO_ALLOWED_HOSTS=" ~/.env | cut -d'=' -f2-)
FIRST_HOST="${DJANGO_ALLOWED_HOSTS%%,*}"
FIRST_HOST="${FIRST_HOST%% *}"
SECOND_HOST="${DJANGO_ALLOWED_HOSTS#*,}"
SECOND_HOST="${SECOND_HOST## }"
SECOND_HOST="${SECOND_HOST%%,*}"
SECOND_HOST="${SECOND_HOST%% *}"
curl --unix-socket /home/ubuntu/portfolio/portfolio.sock -H "Host: ${FIRST_HOST}" http://localhost/

sudo tee /etc/nginx/sites-available/portfolio > /dev/null << EOF
server {
	listen 80;
    server_name "${FIRST_HOST}" "${SECOND_HOST}";
	location /static/ {
        proxy_pass https://$(grep "^AWS_STORAGE_BUCKET_NAME=" ~/.env | cut -d'=' -f2- | tr -d "'").s3.$(grep "^AWS_S3_REGION_NAME=" ~/.env | cut -d'=' -f2- | tr -d "'").amazonaws.com/;
}
location / {
	include proxy_params;
	proxy_pass http://unix:/home/ubuntu/portfolio/portfolio.sock;
	}
}
EOF

sudo usermod -a -G ubuntu www-data
sudo ln -s /etc/nginx/sites-available/portfolio /etc/nginx/sites-enabled
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
curl -I http://midominio.com
curl -I http://psotorrio.click
curl -I http://www.psotorrio.click

sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status

DJANGO_ALLOWED_HOSTS=$(grep "^DJANGO_ALLOWED_HOSTS=" ~/.env | cut -d'=' -f2-)

sudo certbot --nginx -d "${FIRST_HOST}" -d "${SECOND_HOST}" --non-interactive --agree-tos --email "$(grep "^PERSONAL_EMAIL=" ~/.env | cut -d'=' -f2- | tr -d "'")" --redirect
sudo certbot renew --dry-run

curl -I https://"${FIRST_HOST}"
curl -I https://"${SECOND_HOST}"