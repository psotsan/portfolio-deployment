# Portfolio Django — Deployment

This directory contains the deployment documentation for the Portfolio Django application on AWS EC2 (Ubuntu 26.04, t3.micro).

Choose the method that best suits your needs:

## Manual deployment

[`deploy.en.md`](./deploy.en.md) — Step-by-step guide to deploy by hand.

Covers: EC2, S3, Gunicorn, Nginx, DNS, Let's Encrypt HTTPS. Each command is provided so you can follow along and understand every piece of the stack.

## Automated deployment

[`deploy-automated.en.md`](./deploy-automated.en.md) — Uses the [`deploy.sh`](../deploy.sh) script to automate all steps inside the EC2 instance.

Only the external prerequisites (launching the instance, creating the S3 bucket, configuring DNS) are done manually. Once you SSH in, one command does the rest.

## Prerequisites (both methods)

- An AWS account
- Two domain names
- An SSH key pair to access the EC2 instance
