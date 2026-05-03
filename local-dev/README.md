# Aegis AI - Local Development Stack

This directory contains the Docker Compose configuration for running the full Aegis AI microservices stack locally. This setup is intended for **development purposes only** and provides hot-reloading for the Gateway, Brain, and Dashboard services.

## Prerequisites

- **Docker & Docker Compose** installed.
- **Microservices Cloned**: Ensure the following repositories are cloned in the same parent directory as `Aegis-AI-Infra`:
  - `Aegis-AI-Brain`
  - `Aegis-AI-Api-Gateway`
  - `Aegis-AI-Dashboard`
  - `Aegis-AI-Proto` (required for code generation)

Expected folder structure:
```text
parent-directory/
├── Aegis-AI-Infra/
├── Aegis-AI-Brain/
├── Aegis-AI-Api-Gateway/
├── Aegis-AI-Dashboard/
└── Aegis-AI-Proto/
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
    - **Aegis AI Dashboard**: [http://localhost](http://localhost) (via Proxy)
    - **Direct Dashboard (Vite)**: [http://localhost:3000](http://localhost:3000)
    - **API Gateway**: [http://localhost/api](http://localhost/api) (via Proxy) or [http://localhost:8080](http://localhost:8080) (Direct)
    - **Temporal UI**: [http://localhost:8233](http://localhost:8233)
    - **MinIO Console**: [http://localhost:9001](http://localhost:9001)

## Architecture Parity

To ensure seamless transition between local development and Kubernetes, we use an **Nginx Reverse Proxy** (`aegis-proxy`) that mimics an Ingress Controller:

- Requests to `http://localhost/api/*` are routed to the **Gateway**.
- All other requests are routed to the **Dashboard**.
- The Dashboard uses a relative `VITE_API_URL=/api` to ensure compatibility with both local and production environments without code changes.

## Default Credentials

The database is pre-seeded with a superadmin user:
- **Email**: `admin@aegis-ai.com`
- **Password**: `admin_password`

## Development Workflow

### Hot-Reloading
- **Dashboard**: Fully automated via Vite.
- **Gateway & Brain**: Files are bind-mounted. To apply changes, restart the specific service:
  ```bash
  docker compose restart gateway
  docker compose restart brain
  ```

### Protobuf Synchronization
When modifying gRPC definitions in `Aegis-AI-Proto`, you must generate and synchronize the stubs in the respective services.

## Troubleshooting

### Resetting the Database & Infrastructure
To clear all data and re-run initialization:
```bash
docker compose down -v
docker compose up -d
```

### 404 Errors on /api
Ensure the `aegis-proxy` container is running and that your `.env` has `VITE_API_URL=/api`. If you access via `localhost:3000`, the browser might fail on relative API calls; always use `http://localhost`.
