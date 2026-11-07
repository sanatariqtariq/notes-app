#!/usr/bin/env bash
# Screenshots ke baad sab kuch delete (credit bachane ke liye)
az group delete -n "${RG:-rg-notes-cea}" --yes --no-wait
echo "Delete shuru ho gaya (kuch minutes lagenge)."
