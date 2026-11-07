# Step-by-step Guide (Docker + GitHub + Azure)

Order important hai: **Local test -> GitHub push (images ban-ne do) -> Azure infra -> CI/CD -> Screenshots -> Delete**

---
## PART A: Docker setup (apne laptop par)

Haan, Docker install karna hoga. Sirf local testing aur screenshots ke liye. Azure VMs par Docker apne aap cloud-init se install hota hai.

**Windows**
1. Docker Desktop download karo: https://www.docker.com/products/docker-desktop
2. Install ke waqt "Use WSL 2" tick rakho. Restart karo.
3. Docker Desktop kholo, "Engine running" hone tak ruko.
4. PowerShell mein check:
   ```
   docker --version
   docker compose version
   ```
(Mac: Docker Desktop. Linux: `sudo apt install docker.io docker-compose-v2`)

**Local run**
```
cd notes-app
copy .env.example .env        (Mac/Linux: cp .env.example .env)
docker compose up --build
```
- Browser: http://localhost:8080 -> note add karo, list mein aana chahiye.
- Health: http://localhost:8080/api/health -> `{"db":"up","status":"ok"}`
- Band karna: `Ctrl+C`, phir `docker compose down` (data bhi hatana ho: `docker compose down -v`)

**Screenshots lo:** (1) `docker compose ps` (3 containers), (2) browser mein app, (3) /api/health.

**Security proof (report ke liye):** web container db tak nahi pahunch sakta:
```
docker compose exec web sh -c "nc -zv db 5432"     # fail hona chahiye (alag network)
```

---
## PART B: GitHub

1. GitHub par naya repo banao (e.g. `notes-app`), **public** rakho (simple rehta hai).
2. Code push karo:
   ```
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/<USERNAME>/notes-app.git
   git push -u origin main
   ```
   (`.env` push nahi hoga, `.gitignore` mein hai. Check karna.)
3. Repo -> **Actions** tab: workflow chalega. Pehli baar `deploy` job fail hoga (Azure creds abhi nahi): theek hai. `build-and-push` green hona chahiye.
4. **Images public karo (zaroori):** GitHub profile -> Packages -> `notes-app` -> Package settings -> Change visibility -> **Public**. Phir `notes-web` ke liye bhi. Warna VMs image pull nahi kar sakengi.

---
## PART C: Azure tayyari

1. https://portal.azure.com par Azure for Students account se login.
2. Upar `>_` icon -> **Cloud Shell -> Bash**. (Az CLI pehle se installed hota hai, kuch install nahi karna.)
3. Allowed region dekho: Subscription -> Policies, ya error aaye to region badal do. Pakistan se `centralindia` ya `southeastasia` aam taur par theek rehte hain.
4. Repo Cloud Shell mein lo:
   ```
   git clone https://github.com/<USERNAME>/notes-app.git
   cd notes-app
   ```

---
## PART D: Infrastructure banana (ek script)

```
export GH_USER=<github-username-lowercase>
export DB_PASSWORD=<12+ chars, sirf letters/numbers, e.g. NotesDb2026Strong>
export LOC=centralindia
export ALERT_EMAIL=<tumhari email>
bash infra/azure-setup.sh
```
Script yeh banati hai: Resource Group, VNet + 3 subnets, 3 NSGs, NAT Gateway, PostgreSQL (private), Public LB, Internal LB, 2 VMSS, autoscale rules, monitoring alerts.
Time: 15-20 min. Aakhir mein App URL print hoga.

**Verify:**
```
curl http://<LB_IP>/api/health
```
VMs boot + Docker install mein 3-5 min lagte hain; pehle fail ho to thora ruk ke dobara try karo.

**Quota/capacity error aaye** (e.g. `Standard_B1s` not available): `export VM_SKU=Standard_B1ls` ya `Standard_B2ats_v2`, ya region badlo. Dobara chalane se pehle `bash infra/teardown.sh` se purana RG delete karo.

---
## PART E: CI/CD ka Azure connection

Cloud Shell mein:
```
SUB=$(az account show --query id -o tsv)
az ad sp create-for-rbac --name sp-notes-gh --role Contributor \
  --scopes /subscriptions/$SUB/resourceGroups/rg-notes-cea --sdk-auth
```
Jo JSON output aaye usay poora copy karo -> GitHub repo -> Settings -> Secrets and variables -> Actions -> **New repository secret** -> name `AZURE_CREDENTIALS`, value = woh JSON.

Phir code mein koi chhoti tabdeeli (e.g. index.html ka title) push karo. Actions mein `build-and-push` aur `deploy` dono green honge, aur site par change dikhega.

**Agar `az ad sp create-for-rbac` permission error de** (university tenants mein aksar hota hai): Student accounts par service principal ki ijazat nahi hoti. Us surat mein CI (build + push) automatic rahega aur deploy Cloud Shell se `bash infra/redeploy.sh` se hoga. Report mein honestly likh do. Ya mujhe batao, main Watchtower-based auto-deploy bana dunga jisko Azure credentials ki zaroorat nahi.

---
## PART F: Screenshots checklist

1. `docker compose ps` + local app
2. GitHub Actions run (green) + GHCR packages page
3. Azure portal: Resource group overview (saare resources)
4. VNet -> Subnets (3 subnets), NSG rules ke teeno tables
5. Postgres -> Networking (Private access, public access disabled)
6. Load balancers (public + internal) + backend health
7. VMSS -> Scaling (autoscale rules, min 1 max 3)
8. Browser mein live app (public IP) with notes
9. Monitor -> Alerts + CPU metric graph
10. Pricing Calculator ka monthly cost table (item 9 ke liye)
11. (Optional) scale test: VMSS ko load do ya manually capacity 2 karke 2 instances dikhao

---
## PART G: Kaam khatam hone par (credit bachao)

```
bash infra/teardown.sh
```
NAT Gateway, Load Balancers aur Postgres chalte rehte to credit khate hain. Screenshots lene ke foran baad delete karo. Service principal bhi: `az ad sp delete --id <appId>`.

---
## Report mein likhne ke points

**NFR mapping**
- Scalability: VMSS autoscale (CPU 70/30), stateless containers
- Availability: Load Balancer + health probes, multiple instances, `--restart always`
- Security: 3 NSGs (least privilege), private DB, no public IP on VMs, secrets env/GitHub Secrets, parameterized SQL, non-root container, XSS-safe frontend
- Performance: gunicorn 2 workers, LB distribution, Nginx
- Maintainability: Docker, IaC script, CI/CD, GHCR versioned tags (`:sha`)

**Limitations (honestly likho, marks milte hain)**
- DB password VM ke cloud-init custom data mein hai. Production mein Azure Key Vault + Managed Identity use hoga.
- App DB admin user use karta hai. Production mein alag least-privilege DB role banta hai.
- HTTP only (port 80). Production mein HTTPS (Application Gateway / certificate).
- Postgres HA aur read replicas cost ki wajah se off.

**Item 9:** Monitoring (Azure Monitor alerts) + Cost estimate (Pricing Calculator).

---
## Common errors

| Error | Hal |
|---|---|
| `curl` timeout / 502 | 5 min ruko; VM par Docker install ho raha hota hai |
| 502 Bad Gateway | App tier unhealthy: LB -> Backend health dekho; DB password/host check karo |
| VM image pull fail (denied) | GHCR packages public nahi kiye (Part B step 4), phir `bash infra/redeploy.sh` |
| Region/SKU not available | `LOC` ya `VM_SKU` badlo, RG delete karke dobara |
| Postgres create fail | Region badlo (kuch regions student subscriptions par Postgres allow nahi karte) |
| Deploy job `Login failed` | `AZURE_CREDENTIALS` secret poora JSON hona chahiye |
