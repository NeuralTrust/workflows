# Procedimiento: recuperar backups en un GitHub nuevo (org perdida)

**Clasificación:** Interno — NeuralTrust  
**Cuándo usar:** La organización `NeuralTrust` en GitHub ya no existe, está bloqueada, comprometida o no es fiable. El código sigue en GCS.

**Tiempo estimado:** 2–4 h (pocos repos) / medio día (toda la org).

**Prerrequisitos:**

- Mac con `gcloud` y `git` instalados
- Archivo `.dmg` de emergencia + contraseña (Apple Passwords)
- Cuenta con permiso para crear una **organización nueva** en GitHub
- Inventario de valores de secretos (Apple Passwords, hoja del vault, o GCP Secret Manager)

**Relacionado:** `emergency-restore-procedure.md`, `secrets-recovery-guide.md`

---

## Resumen

```
GCS + .dmg  →  código local verificado  →  org GitHub nueva  →  push ramas/tags  →  recrear secretos  →  reactivar CI y backup
```

Los **secrets de GitHub no son necesarios** para descargar ni restaurar el código. Sí los necesitas **después** para que CI y deploys vuelvan a funcionar.

---

## Fase 0 — Decidir y convocar

1. Confirmar el incidente: no hay acceso fiable a la org antigua.
2. Activar responders (mínimo **2 personas**): uno técnico + uno con acceso a Apple Passwords.
3. Comunicar internamente: **no** intentar “arreglar” la org vieja hasta tener el código en un sitio seguro.
4. Si hay sospecha de compromiso (ransomware, acceso no autorizado), usar una semana de backup **antigua y limpia**, no la más reciente.

---

## Fase 1 — Sacar el código de GCS

### 1.1 Montar el vault

```bash
# Contraseña desde Apple Passwords → nota "NeuralTrust Git Backup Vault"
hdiutil attach ~/Secure/neuraltrust-git-backup-vault.dmg

export VAULT="/Volumes/NeuralTrust Git Backup"
export GOOGLE_APPLICATION_CREDENTIALS="${VAULT}/backup-emergency-reader.json"

gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
gcloud config set project neuraltrust-git-backup
```

### 1.2 Listar fechas de backup disponibles

```bash
gcloud storage ls gs://nt-git-backups/git-backups/ | grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}/'
```

| Situación | Qué fecha elegir |
|-----------|------------------|
| Solo perdiste GitHub | La **última** con heartbeat OK |
| Compromiso / ransomware | La semana **más antigua limpia** dentro de retención (21 días) |

### 1.3 Descargar manifest e inventario de secretos

```bash
export BACKUP_DATE=2026-06-23   # sustituir por la fecha elegida
mkdir -p ~/nt-restore/${BACKUP_DATE}

gcloud storage cp \
  "gs://nt-git-backups/git-backups/${BACKUP_DATE}/manifest.json" \
  ~/nt-restore/${BACKUP_DATE}/

gcloud storage cp \
  "gs://nt-git-backups/git-backups/${BACKUP_DATE}/secrets-inventory.json" \
  ~/nt-restore/${BACKUP_DATE}/

jq '.repo_count, .anomalies' ~/nt-restore/${BACKUP_DATE}/manifest.json
```

Prefiere una fecha con `anomalies: []` y un `repo_count` coherente con lo esperado.

### 1.4 Descargar todos los bundles

```bash
mkdir -p ~/nt-restore/${BACKUP_DATE}/bundles ~/nt-restore/${BACKUP_DATE}/repos

gcloud storage cp \
  "gs://nt-git-backups/git-backups/${BACKUP_DATE}/*.bundle" \
  ~/nt-restore/${BACKUP_DATE}/bundles/

gcloud storage cp \
  "gs://nt-git-backups/git-backups/${BACKUP_DATE}/*.sha256" \
  ~/nt-restore/${BACKUP_DATE}/bundles/
```

### 1.5 Verificar integridad (checksums)

```bash
cd ~/nt-restore/${BACKUP_DATE}/bundles
sha256sum -c *.sha256
```

Si algún checksum **falla**, no uses ese repo; prueba otra fecha de backup o descarga de nuevo.

### 1.6 Clonar desde bundles (copia local del código)

```bash
for bundle in ~/nt-restore/${BACKUP_DATE}/bundles/*.bundle; do
  name=$(basename "$bundle" .bundle)
  git clone "$bundle" ~/nt-restore/${BACKUP_DATE}/repos/"$name"
done
```

Lista de repos restaurados:

```bash
ls ~/nt-restore/${BACKUP_DATE}/repos/
```

### 1.7 Desmontar vault

```bash
hdiutil detach "/Volumes/NeuralTrust Git Backup"
```

---

## Fase 2 — Crear GitHub nuevo

### 2.1 Nueva organización

1. En [github.com](https://github.com): **New organization**.
2. Nombre: `NeuralTrust` si está libre, o `NeuralTrust-recovery` como temporal.
3. Plan adecuado (repos privados si los teníais).
4. Invitar al equipo con roles mínimos al principio.

### 2.2 Seguridad de la org nueva

- Activar **2FA obligatorio** para todos los miembros.
- Crear equipo `admins` con pocos miembros.
- **No** reinvitar a toda la org antigua sin revisar quién tenía acceso.

### 2.3 Crear repos vacíos

Para **cada** carpeta en `~/nt-restore/.../repos/`:

1. GitHub → **New repository** → mismo nombre (`watchdog`, `core-services`, …).
2. **Sin** README, `.gitignore` ni licencia (repo completamente vacío).
3. Repetir para todos los repos del manifest.

---

## Fase 3 — Subir el código

Sustituir `ORG_NEW` por el nombre real de la organización nueva.

```bash
export ORG_NEW=NeuralTrust-recovery
export BACKUP_DATE=2026-06-23
```

Por cada repo:

```bash
export REPO=watchdog
cd ~/nt-restore/${BACKUP_DATE}/repos/${REPO}

# Ver ramas restauradas
git branch -a

# Añadir remoto de la org nueva
git remote add origin "git@github.com:${ORG_NEW}/${REPO}.git"

# Push de todas las ramas
git push origin --all

# Push de todos los tags
git push origin --tags

# Establecer rama por defecto si aplica
git push -u origin main
# o: git push -u origin develop
```

### Orden de prioridad sugerido

| Prioridad | Repos | Motivo |
|-----------|-------|--------|
| 1 | `workflows` | Volver a tener CI de backup |
| 2 | `gitops`, `neuraltrust-platform`, `neuraltrust-helm-charts` | Infra y despliegue |
| 3 | `core-services`, `watchdog`, `trustgate-worker`, … | Servicios críticos |
| 4 | Resto | Cuando lo anterior esté estable |

Script para push masivo (revisar antes de ejecutar):

```bash
export ORG_NEW=NeuralTrust-recovery
export BACKUP_DATE=2026-06-23

for dir in ~/nt-restore/${BACKUP_DATE}/repos/*/; do
  REPO=$(basename "$dir")
  cd "$dir"
  if git remote | grep -q '^origin$'; then
    git remote set-url origin "git@github.com:${ORG_NEW}/${REPO}.git"
  else
    git remote add origin "git@github.com:${ORG_NEW}/${REPO}.git"
  fi
  git push origin --all
  git push origin --tags
  echo "OK: ${REPO}"
done
```

---

## Fase 4 — Secretos y CI

Sin esta fase el código está en GitHub pero **nada despliega ni pasa CI**.

### 4.1 Lista de secretos a recrear

1. Abrir `~/nt-restore/${BACKUP_DATE}/secrets-inventory.json`.
2. Por cada nombre listado, buscar el **valor** en:
   - Apple Passwords (carpeta `NeuralTrust Infra`)
   - GCP Secret Manager
   - Paneles de terceros (Stripe, Vercel, etc.)
3. Ver también `secrets-recovery-guide.md`.

### 4.2 Recrear en la org nueva

| Tipo | Dónde en GitHub |
|------|-----------------|
| Org secrets | Settings → Secrets and variables → Actions |
| Repo secrets | Cada repo → Settings → Secrets and variables → Actions |
| Environment secrets | Settings → Environments → crear `production` / `staging` → Secrets |

GitHub **nunca** devuelve valores antiguos. Hay que recrearlos manualmente o desde vuestro vault.

### 4.3 Reconfigurar el backup en la org nueva

Cuando el repo `workflows` esté subido:

1. Reutilizar el proyecto GCP `neuraltrust-git-backup` (si sigue vivo) o crear uno nuevo.
2. Crear **nueva** GitHub App en la org nueva (Contents Read, Metadata Read, Secrets Read).
3. Configurar secrets en `workflows`: `BACKUP_WIF_PROVIDER`, `BACKUP_WIF_SERVICE_ACCOUNT`, `BACKUP_APP_ID`, `BACKUP_APP_PRIVATE_KEY`.
4. Variable `GCS_BUCKET` = `nt-git-backups`.
5. Si rotaste la SA de emergencia: regenerar `.dmg` con `create-emergency-restore-vault.sh`.

Ver `gcp-isolated-project.md` para el setup completo.

---

## Fase 5 — Verificación

| Check | Cómo comprobarlo |
|-------|------------------|
| Historial completo | Commits y tags visibles en repos clave (`watchdog`, `core-services`) |
| Ramas default | `main` / `develop` correctas en Settings → General de cada repo |
| CI | Disparar un workflow de prueba en un repo no crítico |
| Deploy | Solo **después** de secrets — staging primero, producción al final |
| Backup activo de nuevo | `workflow_dispatch` en Weekly Org Backup → verde + archivos nuevos en GCS |

---

## Fase 6 — Post-incidente (48–72 h)

1. **Rotar** todos los secretos que pudieron estar expuestos (tokens, DB, WIF, deploy keys).
2. Documentar qué semana de backup usasteis y por qué.
3. Si la máquina de restore fue expuesta: rotar clave de `backup-emergency-reader` y regenerar `.dmg`.
4. Retrospectiva: ¿faltó algo? Actualizar este runbook.
5. Cuando la org nueva sea estable: actualizar DNS, Vercel, GCP IAM, webhooks hacia la org nueva.
6. Renombrar org temporal (`NeuralTrust-recovery` → `NeuralTrust`) solo si el nombre está libre y el equipo está de acuerdo.

---

## Qué NO recupera este procedimiento

| No incluido | Alternativa |
|-------------|-------------|
| Issues, PRs, discusiones | Export manual previo o aceptar pérdida |
| Git LFS | Backup LFS aparte si lo usáis |
| GitHub Packages / Container registry | Rebuild desde código |
| Deploy keys (mitad privada) | Generar keys nuevas en cada repo |
| Wiki de GitHub | Solo si el contenido estaba en git |
| Valores de GitHub Actions secrets | Recrear desde Apple Passwords / GSM / proveedores |

---

## Checklist rápido (imprimible)

```
[ ] Vault montado, SA autenticada
[ ] Fecha de backup elegida y manifest sin anomalías
[ ] Todos los sha256 OK
[ ] Repos clonados localmente desde bundles
[ ] Org nueva creada con 2FA
[ ] Repos vacíos creados (mismos nombres)
[ ] Push --all y --tags en todos los repos
[ ] Secretos recreados (org + repo + environments)
[ ] workflows con BACKUP_* configurado
[ ] Backup manual verde
[ ] Rotación post-incidente documentada
[ ] Vault desmontado
```

---

## Contactos y referencias

| Recurso | Ubicación |
|---------|-----------|
| Vault offline | `neuraltrust-git-backup-vault.dmg` + Apple Passwords |
| Bucket GCS | `gs://nt-git-backups/git-backups/` |
| Setup infra | `gcp-isolated-project.md` |
| Restore técnico (un repo) | `emergency-restore-procedure.md` |
| Secretos (valores) | `secrets-recovery-guide.md` |
