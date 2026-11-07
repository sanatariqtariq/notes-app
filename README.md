# Three-Tier Notes App on Azure (SE-490 CEA)

Web (Nginx) -> App (Flask API) -> Database (PostgreSQL Flexible Server)

- `web/` Nginx container, HTML page, /api reverse proxy
- `app/` Flask REST API (/api/health, /api/notes GET/POST)
- `docker-compose.yml` local testing
- `.github/workflows/deploy.yml` CI/CD (build -> GHCR -> deploy to Azure VMSS)
- `infra/` Azure CLI scripts (network, NSGs, NAT, LBs, VMSS, autoscale, monitoring)

step-by-step guide: `GUIDE.md`
