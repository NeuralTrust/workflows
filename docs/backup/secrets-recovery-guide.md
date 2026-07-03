# Guía para dummies: secretos y el backup de git

## La regla de oro

**GitHub nunca te deja descargar el valor de un secret** (ni con Actions, ni con API, ni con App).  
El backup semanal guarda **código** + un **inventario de nombres** (`secrets-inventory.json`).  
Los **valores** los tenéis que guardar vosotros en otro sitio.

---

## Qué hace el workflow automáticamente

Cada backup sube a GCS:

| Archivo | Qué contiene |
|---------|----------------|
| `*.bundle` | Código git |
| `secrets-inventory.json` | **Nombres** de secrets (org, repo, environment) — **sin valores** |
| `manifest.json` | SHA-256, tamaños, anomalías |

Sirve para saber **qué secretos recrear** tras un desastre, no para restaurarlos solos.

---

## Opción A — Manual (la más simple para empezar)

### 1. Inventario en una hoja (recomendado)

Crea una tabla (Numbers, Google Sheet **privado**, o CSV en `.dmg`):

| Secret name | Dónde vive | Cómo rotarlo / dónde está el valor |
|-------------|------------|-------------------------------------|
| `GH_TOKEN` | GitHub org secret | Creado en github.com → Settings → Secrets; valor en Apple Passwords entrada "GitHub PAT prod" |
| `DATABASE_URL` | GCP Secret Manager `projects/.../secrets/db-url` | `gcloud secrets versions access latest --secret=db-url` |
| `STRIPE_KEY` | Panel Stripe | dashboard.stripe.com → API keys |

**No pegues el valor en la hoja** si podéis evitarlo — solo la **ruta** para encontrarlo.

### 2. Guardar la hoja en el mismo `.dmg` que el restore

```bash
# Tras crear el vault de restore:
hdiutil attach ~/Secure/neuraltrust-git-backup-vault.dmg
cp secrets-inventory.xlsx "/Volumes/NeuralTrust Git Backup/"
hdiutil detach "/Volumes/NeuralTrust Git Backup"
```

Contraseña del `.dmg` → **Apple Passwords** (nota compartida, 2+ personas).

### 3. Cuando pasa un incidente

1. Restauráis código desde un `.bundle` (semana limpia).
2. Abrís `secrets-inventory.json` del mismo día en GCS → lista de nombres.
3. Abrís la hoja / `.dmg` → sabéis dónde está cada valor.
4. Recreáis secrets en GitHub (Settings → Secrets → New) **a mano**.
5. Rotáis todo lo que pudiera estar comprometido.

---

## Opción B — Semi-automático (valores en GCP Secret Manager)

Si ya usáis **Google Secret Manager** como fuente de verdad:

### Backup automático de GSM al mismo bucket DR

```bash
# Ejemplo manual (luego podéis cron en Cloud Scheduler)
PROJECT=neuraltrust-git-backup
for s in $(gcloud secrets list --project=prod-project --format='value(name)'); do
  gcloud secrets versions access latest --secret="$s" --project=prod-project \
    | gcloud storage cp - "gs://nt-git-backups/gsm-backups/$(date +%F)/${s##*/}.txt"
done
```

Mejor con **cifrado CMEK** y bucket separado `gsm-backups/`.  
Esto **sí** guarda valores — proteged el bucket como joya de la corona.

### Flujo mental

```
Desarrollador → guarda valor en GSM (no solo en GitHub UI)
     ↓
GitHub secret = referencia o sync manual periódico
     ↓
Backup GSM → bucket aislado (automático)
Backup git  → mismo bucket, otra carpeta (workflow semanal)
```

---

## Opción C — Solo Apple Passwords (equipos pequeños)

Para pocos secretos críticos:

1. En **Contraseñas** → carpeta compartida `NeuralTrust Infra`.
2. Una entrada por secret: título = nombre (`GH_TOKEN`), campo = valor.
3. En el backup `.dmg` solo guardáis el **runbook** (esta guía + enlaces).

Tras restore: abrís Contraseñas y copiáis cada valor a GitHub.

---

## Checklist mínimo (hacedlo una vez)

- [ ] GitHub App de backup con **Secrets: Read** (solo nombres en CI)
- [ ] Primer backup → descargar `secrets-inventory.json` y revisar que lista todo
- [ ] Hoja o `.dmg` con "dónde está cada valor"
- [ ] 2 personas saben abrir Apple Passwords + `.dmg`
- [ ] Drill anual: restaurar 1 repo + recrear 2 secrets de prueba

---

## Lo que NO hacer

- Poner valores de secrets en git (ni en repos privados)
- Mandar secrets por Slack / email
- Asumir que el backup de código incluye `DATABASE_URL`
- Dejar solo una persona con acceso al `.dmg`
