# Portfolio Django — Deployment

Website deployed to https://www.psotorrio.click

This directory contains the deployment documentation for the Portfolio Django application on AWS EC2 (Ubuntu 26.04, t3.micro).
Portfolio app repository: https://github.com/psotsan/portfolio

Choose the method that best suits your needs:

## Manual deployment

[`deployment-manual.md`](./deployment-manual.md) — Step-by-step guide to deploy by hand.

Covers: EC2, S3, Gunicorn, Nginx, DNS, Let's Encrypt HTTPS. Each command is provided so you can follow along and understand every piece of the stack.

## Automated deployment

[`deployment-automated.md`](./deployment-automated.md) — Uses the [`deploy.sh`](./deploy.sh) script to automate all steps inside the EC2 instance.

Only the external prerequisites (launching the instance, creating the S3 bucket, configuring DNS) are done manually. Once you SSH in, one command does the rest.

## Prerequisites (both methods)

- An AWS account
- Two domain names
- An SSH key pair to access the EC2 instance
