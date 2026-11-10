#!/usr/bin/env bash
# Notes App - Azure infrastructure (Azure Cloud Shell, Bash)
# Usage:
#   export GH_USER=<github-username-lowercase>
#   export DB_PASSWORD=<strong alphanumeric password, 12+ chars>
#   export LOC=<allowed region>        (optional, default eastasia)
#   export VM_SKU=<size>               (optional, default Standard_B2ats_v2)
#   export ALERT_EMAIL=<your email>    (optional, monitoring alert)
#   bash infra/azure-setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GH_USER:?export GH_USER=<github-username-lowercase>}"
: "${DB_PASSWORD:?export DB_PASSWORD=<strong alphanumeric password>}"

RG="${RG:-rg-notes-cea}"
LOC="${LOC:-eastasia}"
VNET=vnet-notes
PG_NAME="${PG_NAME:-notes-pg-$RANDOM$RANDOM}"
DB_ADMIN=notesadmin
DB_NAME=notesdb
APP_ILB_IP=10.0.2.10
VM_SKU="${VM_SKU:-Standard_B2ats_v2}"

echo "== 0. Resource providers register"
for p in Microsoft.Network Microsoft.Compute Microsoft.DBforPostgreSQL Microsoft.Insights; do
  az provider register --namespace "$p" --wait
done

echo "== 1. Resource group + VNet"
az group create -n "$RG" -l "$LOC" -o none
az network vnet create -g "$RG" -n "$VNET" --address-prefix 10.0.0.0/16 -o none

echo "== 2. NSGs (least privilege; baaki sab default DenyAllInBound se block)"
az network nsg create -g "$RG" -n nsg-web -o none
az network nsg rule create -g "$RG" --nsg-name nsg-web -n allow-http-internet \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes Internet --destination-port-ranges 80 -o none

az network nsg create -g "$RG" -n nsg-app -o none
az network nsg rule create -g "$RG" --nsg-name nsg-app -n allow-5000-from-web \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes 10.0.1.0/24 --destination-port-ranges 5000 -o none

az network nsg create -g "$RG" -n nsg-db -o none
az network nsg rule create -g "$RG" --nsg-name nsg-db -n allow-5432-from-app \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes 10.0.2.0/24 --destination-port-ranges 5432 -o none

echo "== 3. NAT Gateway (private VMs ko outbound internet: GHCR pull, apt)"
az network public-ip create -g "$RG" -n pip-nat --sku Standard --allocation-method Static -o none
az network nat gateway create -g "$RG" -n natgw --public-ip-addresses pip-nat --idle-timeout 10 -o none

echo "== 4. Subnets"
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n snet-web \
  --address-prefixes 10.0.1.0/24 --network-security-group nsg-web --nat-gateway natgw -o none
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n snet-app \
  --address-prefixes 10.0.2.0/24 --network-security-group nsg-app --nat-gateway natgw -o none
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n snet-db \
  --address-prefixes 10.0.3.0/24 --network-security-group nsg-db \
  --delegations Microsoft.DBforPostgreSQL/flexibleServers -o none

echo "== 5. PostgreSQL Flexible Server (private access, 5-10 min lagte hain)"
# Private DNS zone khud banate hain (naye CLI mein zaroori); dobara chalane par error ignore
PG_DNS_ZONE=notes-cea.private.postgres.database.azure.com
az network private-dns zone create -g "$RG" -n "$PG_DNS_ZONE" -o none || true
az network private-dns link vnet create -g "$RG" -z "$PG_DNS_ZONE" -n link-vnet-notes \
  -v "$VNET" -e false -o none || true
PG_DNS_ID=$(az network private-dns zone show -g "$RG" -n "$PG_DNS_ZONE" --query id -o tsv)

# Server pehle se maujood ho to dobara nahi banta
az postgres flexible-server show -g "$RG" -n "$PG_NAME" -o none 2>/dev/null || \
az postgres flexible-server create -g "$RG" -n "$PG_NAME" -l "$LOC" \
  --admin-user "$DB_ADMIN" --admin-password "$DB_PASSWORD" \
  --sku-name "${PG_SKU:-Standard_B1ms}" ${PG_ZONE:+--zone $PG_ZONE} \
  --tier Burstable --storage-size 32 --version 16 \
  --vnet "$VNET" --subnet snet-db --private-dns-zone "$PG_DNS_ID" --yes -o none
DB_HOST=$(az postgres flexible-server show -g "$RG" -n "$PG_NAME" --query fullyQualifiedDomainName -o tsv)
echo "DB host: $DB_HOST"
az postgres flexible-server db create -g "$RG" --server-name "$PG_NAME" --name "$DB_NAME" -o none || true

echo "== 6. Load balancers"
# Public LB (web tier)
az network public-ip create -g "$RG" -n pip-lb-web --sku Standard --allocation-method Static -o none
az network lb create -g "$RG" -n lb-web --sku Standard --public-ip-address pip-lb-web \
  --frontend-ip-name fe-web --backend-pool-name be-web -o none
az network lb probe create -g "$RG" --lb-name lb-web -n probe-http --protocol Tcp --port 80 -o none
az network lb rule create -g "$RG" --lb-name lb-web -n rule-http --protocol Tcp \
  --frontend-port 80 --backend-port 80 --frontend-ip-name fe-web \
  --backend-pool-name be-web --probe-name probe-http -o none

# Internal LB (app tier) - static private IP, nginx isi ko call karta hai
az network lb create -g "$RG" -n lb-app --sku Standard --vnet-name "$VNET" --subnet snet-app \
  --private-ip-address "$APP_ILB_IP" --frontend-ip-name fe-app --backend-pool-name be-app -o none
az network lb probe create -g "$RG" --lb-name lb-app -n probe-api --protocol Http \
  --port 5000 --path /api/health -o none
az network lb rule create -g "$RG" --lb-name lb-app -n rule-api --protocol Tcp \
  --frontend-port 5000 --backend-port 5000 --frontend-ip-name fe-app \
  --backend-pool-name be-app --probe-name probe-api -o none

echo "== 7. cloud-init files"
sed -e "s|__GH_USER__|$GH_USER|g" -e "s|__DB_HOST__|$DB_HOST|g" \
    -e "s|__DB_PASSWORD__|$DB_PASSWORD|g" infra/cloud-init-app.yaml > /tmp/ci-app.yaml
sed -e "s|__GH_USER__|$GH_USER|g" -e "s|__APP_UPSTREAM__|$APP_ILB_IP:5000|g" \
    infra/cloud-init-web.yaml > /tmp/ci-web.yaml

echo "== 8. VM Scale Sets (Uniform mode)"
az vmss create -g "$RG" -n vmss-app --orchestration-mode Uniform --image Ubuntu2204 \
  --vm-sku "$VM_SKU" --instance-count 1 --admin-username azureuser --generate-ssh-keys \
  --vnet-name "$VNET" --subnet snet-app --lb lb-app --backend-pool-name be-app \
  --custom-data /tmp/ci-app.yaml --upgrade-policy-mode Manual --disable-overprovision -o none

az vmss create -g "$RG" -n vmss-web --orchestration-mode Uniform --image Ubuntu2204 \
  --vm-sku "$VM_SKU" --instance-count 1 --admin-username azureuser --generate-ssh-keys \
  --vnet-name "$VNET" --subnet snet-web --lb lb-web --backend-pool-name be-web \
  --custom-data /tmp/ci-web.yaml --upgrade-policy-mode Manual --disable-overprovision -o none

rm -f /tmp/ci-app.yaml /tmp/ci-web.yaml

echo "== 9. Autoscale (CPU>70% out, CPU<30% in, min1 max3)"
for V in vmss-web vmss-app; do
  az monitor autoscale create -g "$RG" --resource "$V" \
    --resource-type Microsoft.Compute/virtualMachineScaleSets \
    -n "autoscale-$V" --min-count 1 --max-count 3 --count 1 -o none
  az monitor autoscale rule create -g "$RG" --autoscale-name "autoscale-$V" \
    --condition "Percentage CPU > 70 avg 5m" --scale out 1 -o none
  az monitor autoscale rule create -g "$RG" --autoscale-name "autoscale-$V" \
    --condition "Percentage CPU < 30 avg 5m" --scale in 1 -o none
done

if [ -n "${ALERT_EMAIL:-}" ]; then
  echo "== 10. Monitoring alerts (enhancement)"
  az monitor action-group create -g "$RG" -n ag-notes --short-name notes \
    --action email admin "$ALERT_EMAIL" -o none
  APP_ID=$(az vmss show -g "$RG" -n vmss-app --query id -o tsv)
  az monitor metrics alert create -g "$RG" -n alert-app-cpu --scopes "$APP_ID" \
    --condition "avg Percentage CPU > 80" --window-size 5m --evaluation-frequency 1m \
    --action ag-notes --description "App tier CPU high" -o none
  DB_ID=$(az postgres flexible-server show -g "$RG" -n "$PG_NAME" --query id -o tsv)
  az monitor metrics alert create -g "$RG" -n alert-db-connections --scopes "$DB_ID" \
    --condition "avg active_connections > 40" --window-size 5m --evaluation-frequency 1m \
    --action ag-notes --description "DB connections high" -o none
fi

LB_IP=$(az network public-ip show -g "$RG" -n pip-lb-web --query ipAddress -o tsv)
echo
echo "DONE. VMs ko boot hone mein 3-5 min lagte hain."
echo "App URL : http://$LB_IP"
echo "Health  : http://$LB_IP/api/health"
echo "PG name : $PG_NAME"
