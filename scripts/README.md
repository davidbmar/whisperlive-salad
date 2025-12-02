# WhisperLive Deployment Scripts

## Script Organization

### 0xx: Setup & Deployment
| Script | Purpose |
|--------|---------|
| `000-questions.sh` | Interactive setup - creates `.env` config |
| `020-deploy-gpu-instance.sh` | Create new EC2 GPU instance |
| `030-start-whisperlive.sh` | Start WhisperLive container on GPU |
| `040-stop-whisperlive.sh` | Stop WhisperLive container |

---

### 8xx: Operations & Maintenance
| Script | Purpose |
|--------|---------|
| `810-stop-gpu-instance.sh` | Stop GPU instance (save money) |
| `820-start-gpu-instance.sh` | Start stopped GPU instance |
| `850-status.sh` | Check status of everything |
| `860-ssh.sh` | SSH into GPU instance |
| `870-logs.sh` | View WhisperLive container logs |

---

## Quick Start (Fresh Deploy)

```bash
./scripts/000-questions.sh           # 1. Configure
./scripts/020-deploy-gpu-instance.sh # 2. Create GPU instance
./scripts/030-start-whisperlive.sh   # 3. Start WhisperLive
./scripts/850-status.sh              # 4. Verify
```

## Daily Operations

```bash
# Morning - start everything
./scripts/820-start-gpu-instance.sh
./scripts/030-start-whisperlive.sh

# Evening - stop to save costs
./scripts/810-stop-gpu-instance.sh
```

## Cost Reference

| Instance | Hourly | Daily (24h) | Monthly |
|----------|--------|-------------|---------|
| g4dn.xlarge | $0.526 | $12.62 | $379 |
| g4dn.2xlarge | $0.752 | $18.05 | $542 |
