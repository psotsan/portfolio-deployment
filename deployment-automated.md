# Portfolio Django — Automated deployment

This document covers the deployment of the Django portfolio using `deploy.sh`.
Actions **outside** the EC2 instance must be performed manually.
Once inside the instance, `deploy.sh` automates everything.

---

## 1. Manual pre-requisites (outside EC2)

### 1.1 Launch EC2 instance

- AWS Console → EC2 → Launch instance
- **Name**: `portfolio`
- **AMI**: Ubuntu 26.04
- **Instance type**: `t3.micro`
- **Key pair**: Create or select an existing one (you will need the `.pem` file to SSH)
- **Security Group**: Create a new one with these inbound rules:

| Type | Protocol | Port | Source |
|------|----------|------|--------|
| SSH | TCP | 22 | `0.0.0.0/0` |
| HTTP | TCP | 80 | `0.0.0.0/0` |
| HTTPS | TCP | 443 | `0.0.0.0/0` |

### 1.2 Assign Elastic IP

- AWS Console → EC2 → Elastic IPs → Allocate Elastic IP
- Associate it with the newly launched instance
- Note the IP address (e.g. `YOUR_ELASTIC_IP`)

### 1.3 Create S3 bucket for static files

- AWS Console → S3 → **Create bucket**

- **Bucket name**: `portfolio-static-2024` (choose a globally unique name)

- **AWS Region**: `eu-south-2` (Spain)

- **Object Ownership**: ACLs disabled (recommended)

- **Block Public Access settings**: uncheck *Block all public access*

- Check only *Block public access to buckets and objects granted through new public bucket or access point policies*

- **Bucket Versioning**: Disable → **Create bucket**

- Go to **Permissions** tab → **Bucket Policy** → Paste:

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

### 1.4 Attach IAM role to the instance (required)

`deploy.sh` does **not** prompt for AWS access keys. It relies on an IAM role attached to the EC2 instance (Instance Profile).

1. AWS Console → IAM → Roles → Create role
2. Trusted entity: AWS service → EC2 → Next
3. Search and select `AmazonS3FullAccess` → Next
4. Name: `portfolio-s3-role` → Create role
5. AWS Console → EC2 → select instance → Actions → Security → Modify IAM role
6. Select `portfolio-s3-role` → Update IAM role

### 1.5 Upload `deploy.sh` to the instance

```bash
scp -i /path/to/your-key.pem deploy.sh ubuntu@YOUR_ELASTIC_IP:/home/ubuntu/
```

### 1.6 Configure DNS

- Go to your domain registrar / DNS provider
- **Delete** any existing AAAA record
- **Create** two A records:

| Name | Value |
|------|-------|
| `yourdomain.com` | `YOUR_ELASTIC_IP` |
| `www.yourdomain.com` | `YOUR_ELASTIC_IP` |

- **TTL**: 300 seconds (5 minutes) during development
- Wait for DNS propagation (minutes to hours)

### 1.7 SSH into the instance

```bash
ssh -i /path/to/your-key.pem ubuntu@YOUR_ELASTIC_IP
```

---

## 2. Automated deployment (inside EC2)

Once connected via SSH, run:

```bash
chmod +x deploy.sh
./deploy.sh
```

### 2.1 What `deploy.sh` does

**System preparation**

| Step | Description |
|------|-------------|
| System update | `apt update && apt upgrade -y` |
| Package installation | Installs `python3-pip`, `python3-dev`, `python3-venv`, `nginx`, `curl`, `git`, `certbot`, `python3-certbot-nginx` |
| Clone repository | Clones `https://github.com/YOUR_USERNAME/portfolio` into `/home/ubuntu/` |

**Environment configuration**

| Step | Description |
|------|-------------|
| `.env` generation | Prompts for `DJANGO_ALLOWED_HOSTS`, `PERSONAL_NAME`, `PERSONAL_EMAIL`, `PERSONAL_GITHUB`, `PERSONAL_LINKEDIN`, `AWS_STORAGE_BUCKET_NAME`, `AWS_S3_REGION_NAME`
`DJANGO_ALLOWED_HOSTS` must be **exactly two comma-separated hosts**, e.g. `yourdomain.com,www.yourdomain.com`. The script parses them as `FIRST_HOST` and `SECOND_HOST` for Nginx and Certbot. |
| Secret key | Auto-generates a 50-character `DJANGO_SECRET_KEY` using `secrets` module |
| Security defaults | Writes `DJANGO_DEBUG=False`, `SECURE_HSTS_SECONDS=31536000`, `SECURE_SSL_REDIRECT=True`, `SESSION_COOKIE_SECURE=True`, `CSRF_COOKIE_SECURE=True` |
| Superuser prompts | Prompts for `DJANGO_SUPERUSER_USERNAME`, `DJANGO_SUPERUSER_EMAIL`, `DJANGO_SUPERUSER_PASSWORD` and stores them in `.env` |
| Symlink | Creates `ln -sf ~/.env portfolio/.env` |

**Django setup**

| Step | Description |
|------|-------------|
| Virtual environment | Creates and activates `venv` |
| Dependencies | `pip install --upgrade pip && pip install -r portfolio/requirements.txt` |
| Static files | Loads `.env` and runs `collectstatic --noinput` (uploads to S3) |
| Database | Runs `migrate` |
| Superuser | Creates Django superuser with `createsuperuser --noinput` using the variables from `.env` |

**Gunicorn**

| Step | Description |
|------|-------------|
| Log directory | Creates `/var/log/gunicorn` owned by `ubuntu:www-data` |
| systemd service | Writes `/etc/systemd/system/gunicorn.service` pointing to the `.env` file |
| Start & enable | `systemctl enable --now gunicorn` |
| Verify | Tests the socket with `curl --unix-socket` using the first host from `DJANGO_ALLOWED_HOSTS` |

**Nginx**

| Step | Description |
|------|-------------|
| Configuration | Writes `/etc/nginx/sites-available/portfolio` with `server_name` and S3 proxy URL extracted from `.env` |
| Enable site | Adds `www-data` to `ubuntu` group, enables the site, removes `default`, tests config, restarts Nginx |
| HTTP test | Runs `curl -I http://<first-host>` |

**Firewall**

| Step | Description |
|------|-------------|
| UFW rules | Allows ports 22, 80, 443 and enables the firewall |

**HTTPS (Let's Encrypt)**

| Step | Description |
|------|-------------|
| Certbot | Runs `certbot --nginx -d <first-host> -d <second-host>` non-interactively using the email from `.env` with `--redirect` |
| Renewal test | Runs `certbot renew --dry-run` to verify auto-renewal |

**Final check**

| Step | Description |
|------|-------------|
| HTTPS test | `curl -I https://<first-host>` and `curl -I https://<second-host>` |

---

## 3. Post-deployment notes

- Static files are served from S3 (not from the Django server)
- The Gunicorn service will restart automatically if the instance reboots (`systemd`)
- Certbot auto-renewal is enabled by default via a systemd timer
- The `.env` file lives at `~/.env` (outside the repo) so it survives re-clones
- To update the application after code changes: `git pull`, restart gunicorn (`sudo systemctl restart gunicorn`), and re-run `collectstatic` if static files changed
- AWS credentials come from the IAM role attached to the instance. No keys are stored in `~/.env`
