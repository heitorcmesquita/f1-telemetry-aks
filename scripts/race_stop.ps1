# ============================================
# STOP EVERYTHING AFTER THE RACE
# ============================================

# This script is intended to be run from the repository root, but it will work
# even if invoked from another directory.
$repoRoot = Split-Path -Parent $PSScriptRoot
$configYaml = Join-Path $repoRoot 'config\race-day.yaml'

Write-Host "Stopping F1 race day infrastructure..." -ForegroundColor Yellow

# Remove deployments from Kubernetes
Write-Host "Removing Kubernetes deployments..."
kubectl delete -f $configYaml
kubectl delete secret f1-secrets

# Stop Stream Analytics
Write-Host "Stopping Stream Analytics..."
az stream-analytics job stop --name openf1-analytics --resource-group openf1-rg

# Stop AKS
Write-Host "Stopping AKS cluster..."
az aks stop --name openf1-aks --resource-group openf1-rg

# Stop Grafana
Write-Host "Stopping Grafana..."
az container stop --name openf1-grafana --resource-group openf1-rg

# SQL auto-pauses after 60 minutes of inactivity (serverless tier)
Write-Host "SQL Database will auto-pause after 60 minutes of inactivity."

Write-Host ""
Write-Host "✅ All systems stopped. See you next race!" -ForegroundColor Yellow
