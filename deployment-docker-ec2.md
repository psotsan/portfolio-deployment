# Docker Deployment on AWS EC2

This document describes how to deploy the **portfolio** Django application
on an AWS EC2 instance using Docker. The deployment pipeline uses GitHub
Container Registry (GHCR) as the image registry, nginx as a reverse proxy,
Let's Encrypt (Certbot) for TLS, and UFW for firewall management.

---

## Architecture Overview

```
                         Internet
                            |
                       [UFW Firewall]
                     (22, 80, 443/tcp)
                            |
                       [nginx:80/443]
                      (reverse proxy)
                            |
                   [Docker container:8000]
                  (Gunicorn + Django app)
                            |
                    [AWS S3 (static files)]
```

- **Docker container** runs the Django application with Gunicorn on port
  `8000`.
- **nginx** terminates TLS (via Let's Encrypt) and proxies requests to
  the container.
- **Static files** are served directly from AWS S3.
- **UFW** restricts inbound traffic to ports 22 (SSH), 80 (HTTP), and
  443 (HTTPS).

---

## Prerequisites

- An **AWS EC2 instance** running **Ubuntu 26.04 LTS** with:
  - A public IP address and a registered domain name pointing to it.
  - SSH access (port 22) as the `ubuntu` user.
- A **GitHub Personal Access Token** (classic) with `read:packages`
  scope to authenticate with GHCR.
- An **IAM role** attached to the EC2 instance with permissions to
  read from and write to the S3 bucket used for static files.
  No explicit AWS credentials are needed — the SDK (boto3) obtains
  them automatically from the instance metadata service via the
  attached IAM role.
- The following security group rules on your EC2 instance:
  - `22/tcp` (SSH)
  - `80/tcp` (HTTP)
  - `443/tcp` (HTTPS)

---

## Deployment Steps

### Step 1 — Clone the repository

Connect to your EC2 instance via SSH and clone the project:

```bash
ssh ubuntu@your-domain.com
git clone https://github.com/psotsan/portfolio.git
cd portfolio
```

### Step 2 — Configure environment variables

Run the interactive environment setup script:

```bash
./docker-setup-env.sh
```

You will be prompted for the following variables:

| Variable                    | Description                                        |
|-----------------------------|----------------------------------------------------|
| `DJANGO_ALLOWED_HOSTS`      | Domain names, comma-separated (max 2).<br/>Example: `example.com,www.example.com` |
| `PERSONAL_NAME`             | Your full name.                                    |
| `PERSONAL_EMAIL`            | Your email address (used by Certbot).              |
| `PERSONAL_GITHUB`           | Your GitHub profile URL.                           |
| `PERSONAL_LINKEDIN`         | Your LinkedIn profile URL.                         |
| `AWS_STORAGE_BUCKET_NAME`   | Name of the S3 bucket for static files.            |
| `AWS_S3_REGION_NAME`        | AWS region of the S3 bucket (e.g., `eu-south-2`).   |

> **Note:** No AWS access key or secret key variables are required.
> The Docker container inherits the IAM role from the EC2 instance.
> The boto3 SDK inside the container automatically retrieves
> temporary credentials from the instance metadata service
> (`169.254.169.254`).
| `DJANGO_SUPERUSER_USERNAME` | Admin username for the Django admin panel.         |
| `DJANGO_SUPERUSER_EMAIL`    | Admin email address.                               |
| `DJANGO_SUPERUSER_PASSWORD` | Admin password.                                    |

The script also:

- Generates a strong random `DJANGO_SECRET_KEY` automatically.
- Sets production-ready security defaults (`DEBUG=False`, HSTS, SSL
  redirect, secure cookies).
- Writes the resulting environment to `~/.env`.

After completion the file `~/.env` is created and automatically symlinked
into the project directory.

### Step 3 — Bootstrap the instance (Phase 1)

Run the bootstrap script to install system dependencies:

```bash
./docker-bootstrap-instance.sh
```

This phase installs:

- **Docker** (`docker.io`) — container runtime.
- **nginx** — reverse proxy web server.
- **Certbot** + **python3-certbot-nginx** — Let's Encrypt TLS
  certificates.
- **UFW** — firewall.

It also adds the `ubuntu` user to the `docker` group and exits.



### Step 4 — Log out and log back in

The Docker group membership only takes effect after a new login session. You must log out and log back in (or reboot) before proceeding.

```bash
exit
ssh ubuntu@your-domain.com
cd portfolio
```

Alternatively, reboot the instance:

```bash
sudo reboot
# wait, then reconnect
```

### Step 5 — Bootstrap the instance (Phase 2)

Configure nginx, the firewall, and SSL certificates:

```bash
./docker-bootstrap-instance.sh --phase-2
```

This phase performs the following:

1. **nginx configuration** — creates an `nginx` site that:
   - Listens on port `80` with your domain names as `server_name`.
   - Proxies requests for `/static/` to AWS S3 via an HTTP 301
     redirect.
   - Proxies all other requests to the Docker container at
     `http://127.0.0.1:8000`.

2. **Firewall setup** — enables UFW and allows ports `22/tcp`,
   `80/tcp`, and `443/tcp`.

3. **SSL/TLS certificate** — obtains a Let's Encrypt certificate via
   Certbot, configures automatic HTTP-to-HTTPS redirect, and schedules
   automatic renewal.

At this point your instance is fully provisioned and ready to run the
application container.

### Step 6 — Deploy the application

Authenticate with GHCR and deploy the Docker container:

```bash
# Authenticate with GitHub Container Registry
echo YOUR_GITHUB_TOKEN | docker login ghcr.io -u YOUR_GITHUB_USERNAME \
  --password-stdin

# Deploy the application
./docker-deploy.sh
```

The deploy script performs the following actions:

1. **Pulls** the latest image from `ghcr.io/psotsan/portfolio:latest`.
2. **Stops and removes** any existing container with the same name.
3. **Starts** a new container:
   - Name: `portfolio`
   - Port mapping: `8000:8000` (host:container)
   - Restart policy: `unless-stopped`
   - Environment variables loaded from `~/.env`
4. **Waits** for the container to become healthy (Django ready).
5. **Runs** Django management commands:
   - `migrate` — applies database migrations.
   - `createsuperuser` — creates the admin superuser (skips if
     already exists).
   - `collectstatic` — uploads static files to S3.
6. **Performs a smoke test** with `curl` to verify the application is
   responding.

After completion, visit `https://your-domain.com` to verify the site is
live.

---

## Docker Configuration Reference

### Container image

Built from `Dockerfile` (base: `python:3.14-slim-bookworm`):

```dockerfile
FROM python:3.14-slim-bookworm

ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

EXPOSE 8000

WORKDIR /portfolio

COPY ./portfolio/requirements.txt .
RUN pip install -r requirements.txt

COPY . .
RUN chmod +x entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
```

### Entrypoint (`entrypoint.sh`)

The container runs Gunicorn directly on port `8000`:

```bash
#!/bin/sh
set -e
python manage.py migrate --noinput
exec gunicorn --bind 0.0.0.0:8000 --workers 3 portfolio.wsgi:application
```

### Container startup

Managed by `docker-deploy.sh` with:

```bash
docker run -d \
  --name portfolio \
  -p 8000:8000 \
  --restart unless-stopped \
  --env-file ~/.env \
  ghcr.io/psotsan/portfolio:latest
```

---

## Managing Updates

To deploy a new version of the application after updating the image on
GHCR:

```bash
cd ~/portfolio
git pull
./docker-deploy.sh
```

This will pull the latest image, replace the running container with zero
downtime (the old container is stopped after the new one is ready), and
re-run migrations and static file collection.

### Passing flags to the deploy script

```bash
# Skip migrations if no schema changes
./docker-deploy.sh --skip-migrations

# Skip static file collection
./docker-deploy.sh --skip-collectstatic

# Use a custom image tag
./docker-deploy.sh --tag ghcr.io/psotsan/portfolio:v2.1.0

# Use a different host port
./docker-deploy.sh --port 8080
```

---

## Post-Deployment Verification

```bash
# Check the container is running
docker ps --filter name=portfolio

# View container logs
docker logs portfolio

# Run a health check
curl -I https://your-domain.com

# Verify SSL certificate
curl -vI https://your-domain.com 2>&1 | grep -i "ssl\|certificate"
```