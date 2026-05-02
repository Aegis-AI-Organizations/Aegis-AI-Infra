# Aegis AI - Local Development Stack

This directory contains the Docker Compose configuration for running the full Aegis AI microservices stack locally. This setup is intended for **development purposes only** and provides hot-reloading for the Gateway, Brain, and Dashboard services.

## Prerequisites

- **Docker & Docker Compose** installed.
- **Microservices Cloned**: Ensure the following repositories are cloned in the same parent directory as `Aegis-AI-Infra`:
  - `Aegis-AI-Brain`
  - `Aegis-AI-Api-Gateway`
  - `Aegis-AI-Dashboard`

Expected folder structure:
```text
parent-directory/
├── Aegis-AI-Infra/
├── Aegis-AI-Brain/
├── Aegis-AI-Api-Gateway/
└── Aegis-AI-Dashboard/
```

## Setup Instructions

1.  **Prepare Environment Variables**:
    Copy the example environment file:
    ```bash
    cp .env.example .env
    ```

2.  **Start the Stack**:
    Run the following command from this directory:
    ```bash
    docker compose up -d
    ```

3.  **Access the Services**:
    - **Dashboard**: [http://localhost:3000](http://localhost:3000)
    - **API Gateway**: [http://localhost:8080](http://localhost:8080)
    - **Temporal UI**: [http://localhost:8233](http://localhost:8233)

## Default Credentials

The database is pre-seeded with a superadmin user:
- **Email**: `admin@aegis-ai.com`
- **Password**: `admin_password`

## Development Workflow

### Hot-Reloading
- **Dashboard**: Fully automated. The setup uses Vite polling to detect changes even on networked or synchronized filesystems.
- **Gateway & Brain**: Files are updated inside the containers via bind mounts, but the processes do not auto-restart. To apply changes, restart the specific service:
  ```bash
  docker compose restart gateway
  docker compose restart brain
  ```

## Troubleshooting

### Filesystem Locks (Synology Drive / macOS)
If you encounter "resource deadlock" or slow reloads on macOS (especially if using Synology Drive), the stack is pre-configured with Vite polling to mitigate these issues.

### Resetting the Database
To clear all data and re-run the initialization scripts:
```bash
docker compose down -v
docker compose up -d
```
