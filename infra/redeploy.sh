#!/usr/bin/env bash
# Har VMSS instance par naya image pull karke container restart karta hai.
# CI/CD isi ko chalata hai; manual redeploy ke liye Cloud Shell mein bhi chala sakte ho.
set -euo pipefail
RG="${RG:-rg-notes-cea}"

# Pehle app tier, phir web tier
for VMSS in vmss-app vmss-web; do
  for ID in $(az vmss list-instances -g "$RG" -n "$VMSS" --query "[].instanceId" -o tsv); do
    echo ">> $VMSS instance $ID"
    az vmss run-command invoke -g "$RG" -n "$VMSS" --instance-id "$ID" \
      --command-id RunShellScript --scripts "/opt/notes/deploy.sh" \
      --query "value[0].message" -o tsv
  done
done
