# Portfolio Django Manual Deployment

## Architecture diagram

```
┌──────────┐     ┌───────────┐     ┌────────────┐     ┌──────────┐
│  User    │────▶│   Nginx   │────▶│  Gunicorn  │────▶│  Django  │
│ (HTTPS)  │     │  (proxy)  │     │  (socket)  │     │  (app)   │
└──────────┘     └─────┬─────┘     └────────────┘     └──────────┘
                       │
                       ▼
                ┌──────────────────┐
                │ S3 (static files)│
                └──────────────────┘
```

- Launch EC2
- Assign Elastic IP
- Open ports 80 (HTTP) and 443 (HTTPS) in the Security Group
- Update:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install python3-pip python3-dev python3-venv nginx curl git -y
```

## S3 — Create bucket for static files

- AWS Console → S3 → **Create bucket**

- **Bucket name**: `portfolio-static-2024` (choose a globally unique name)

- **AWS Region**: `eu-south-2` (Spain)

- **Object Ownership**: ACLs disabled (recommended)

- **Block Public Access settings**: uncheck *Block all public access*

- Check only *Block public access to buckets and objects granted through new public bucket or access point policies*

- **Bucket Versioning**: Disable

- **Create bucket**

- Bucket created → **Permissions** tab → **Bucket Policy** → Paste:

```json
{
"Version": "2012-10-17",
"Statement": [
{
"Effect": "Allow",
"Principal": "*",
"Action": "s3:GetObject",
"Resource": "arn:aws:s3:::portfolio-static-2024/*"
}
]
}
```

- **Save changes**

- Clone repo:

```bash
cd ~
git clone https://github.com/YOUR_USERNAME/portfolio
cd portfolio
```

- Create virtual environment:

```bash
python3 -m venv venv
source venv/bin/activate
```

- Install dependencies:

```bash
pip install --upgrade pip
pip install -r portfolio/requirements.txt
```

- Configure environment variables:

```bash
# .env is kept outside the repo (~/.env) so it is not lost
# when deleting or re-cloning the portfolio directory.
cp .env.example ~/.env
vim ~/.env
# Create a symbolic link inside the project so Django can find it
ln -sf ~/.env .env
```

Edit `~/.env`. Use **single quotes** `'` to prevent special characters from being escaped (e.g. `DJANGO_SECRET_KEY='django-insecure-abc(def)ghi'`):

- `DJANGO_SECRET_KEY` → generate with `python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"`

- `DJANGO_ALLOWED_HOSTS=yourdomain.com,www.yourdomain.com`
- `DJANGO_DEBUG=False`

- `PERSONAL_NAME`, `PERSONAL_EMAIL`, `PERSONAL_GITHUB`, `PERSONAL_LINKEDIN`

- `AWS_STORAGE_BUCKET_NAME=portfolio-static-2024`, `AWS_S3_REGION_NAME=eu-south-2`

- `SECURE_HSTS_SECONDS=31536000`, `SECURE_SSL_REDIRECT=True`, `SESSION_COOKIE_SECURE=True`, `CSRF_COOKIE_SECURE=True`

Choose **one** of the following two options for AWS credentials:

**Option A — Access Keys** (project-specific IAM user):

1. AWS Console → IAM → Users → Create user → name `portfolio-s3-user`

2. Attach policy `AmazonS3FullAccess` → Create user

3. Copy Access Key ID and Secret Access Key

4. In `~/.env` uncomment and fill in:

```
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
```

**Option B — Instance Profile** (no keys in the file):

1. AWS Console → IAM → Roles → Create role

2. Trusted entity: AWS service → EC2 → Next

3. Search and select `AmazonS3FullAccess` → Next

4. Name: `portfolio-s3-role` → Create role

5. AWS Console → EC2 → select instance → Actions → Security → Modify IAM role

6. Select `portfolio-s3-role` → Update IAM role

7. In `~/.env` **keep commented or delete** `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`

- Static files:

```bash
# Environment variables are only available in systemd (gunicorn). For manual
# commands you need to load them from .env. They are lost when SSH closes.
set -a && source ~/.env && set +a
python manage.py collectstatic --noinput
# If you add static files (CSS, JS, images) in the future, repeat
# this step and restart gunicorn.
```

## Gunicorn

- Install (should already be installed via requirements.txt)

```bash
pip install gunicorn
```

- The `gunicorn_config.py` config file is already included in the repository.

If you need to customize it, edit it before starting the service.

See the appendix at the end of this guide for its contents.

- Create log directory:

```bash
sudo mkdir -p /var/log/gunicorn
sudo chown -R ubuntu:www-data /var/log/gunicorn
```

- systemd service (the `EnvironmentFile` points to `~/.env`):

```bash
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
```

- Start service:

```bash
sudo systemctl enable --now gunicorn
sudo systemctl status gunicorn
```

- Verify:

```bash
# Test HTTP response against the socket (replace yourdomain.com with the real one)
curl --unix-socket /home/ubuntu/portfolio/portfolio.sock -H "Host: yourdomain.com" http://localhost/
# Check logs for errors
sudo journalctl -u gunicorn --no-pager -n 50
sudo tail -f /var/log/gunicorn/error.log
```

## NGINX

- Configure:

```bash
sudo tee /etc/nginx/sites-available/portfolio << 'EOF'
server {
	listen 80;
	server_name yourdomain.com www.yourdomain.com;
	location /static/ {
		proxy_pass https://portfolio-static-2024.s3.eu-south-2.amazonaws.com/;
}
location / {
	include proxy_params;
	proxy_pass http://unix:/home/ubuntu/portfolio/portfolio.sock;
	}
}
EOF
```

- Enable:

```bash
# Add www-data to the ubuntu group so nginx can read the socket
sudo usermod -a -G ubuntu www-data
sudo ln -s /etc/nginx/sites-available/portfolio /etc/nginx/sites-enabled
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
```

- Verify:

```bash
curl -I http://yourdomain.com
```

## DNS

- Change the A record to point to your server IP: YOUR_ELASTIC_IP

- If it exists, delete the AAAA record

- Create records for both `yourdomain.com` and `www.yourdomain.com`

- Recommended TTL: 300 seconds (5 minutes) during development

- After some time (minutes or hours) the domain will point to the server

- **Before moving to HTTPS**, verify that HTTP works:

```bash
curl -I http://yourdomain.com
curl -I http://www.yourdomain.com
```

## HTTPS with Let's Encrypt

```bash
# Open ports in the system firewall
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
# Also verify firewall rules in the EC2 Security Group
```

```bash
sudo apt install certbot python3-certbot-nginx -y
# you can add the --staging flag for test certificates. There is a limit of 5 certificates per week
sudo certbot --nginx -d yourdomain.com -d www.yourdomain.com
```

- Certbot will automatically modify the nginx configuration by adding the SSL certificates and HTTP → HTTPS redirect

- Verify the generated file:

```bash
sudo cat /etc/nginx/sites-available/portfolio
```

- Verify automatic renewal:

```bash
sudo certbot renew --dry-run
```

## Final verification

```bash
curl -I https://yourdomain.com
curl -I https://www.yourdomain.com
```

## Re-cloning the project (if needed)

If you need to delete the `portfolio` directory and re-clone:

```bash
cd ~
rm -rf portfolio
git clone https://github.com/YOUR_USERNAME/portfolio
cd portfolio
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r portfolio/requirements.txt
# Restore the symbolic link to .env
# No need to create .env again, just restore the link
ln -sf ~/.env .env
# Static files
set -a && source ~/.env && set +a
python manage.py collectstatic --noinput
# Restart gunicorn
sudo systemctl restart gunicorn
```

## Appendix: gunicorn_config.py

```python
bind = 'unix:/home/ubuntu/portfolio/portfolio.sock'
workers = 3 # (2 * num_cores) + 1
worker_class = 'sync'
timeout = 120
keepalive = 5
max_requests = 1000
max_requests_jitter = 50
accesslog = '/var/log/gunicorn/access.log'
errorlog = '/var/log/gunicorn/error.log'
loglevel = 'info'
```
