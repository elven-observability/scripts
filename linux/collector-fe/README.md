# Collector FE – Faro (Linux) – Elven Observability

Installs the **Faro Collector** (frontend instrumentation) as a systemd service. Receives browser logs from your frontend and forwards them to Loki.

## 🚀 Quick Installation

### Option 1: One-liner (direct execution)

Run as **root or with sudo**:

```bash
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/collector-fe/install.sh | sudo bash
```

### Option 2: Download and run (recommended for production)

```bash
# Download
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/collector-fe/install.sh -o install.sh

# Make executable and run
chmod +x install.sh
sudo ./install.sh
```

### Option 3: With environment variables (CI / non-interactive)

```bash
sudo SECRET_KEY="your-key-min-32-chars" \
     LOKI_URL="https://logs-prod-xxx.grafana.net" \
     LOKI_API_TOKEN="your-token" \
     ALLOW_ORIGINS="https://app.example.com,https://*.example.com" \
     ./install.sh
```

### Option 4: From local binary (air-gap / manual release)

```bash
sudo LOCAL_BINARY=/path/to/collector-fe-instrumentation-linux-amd64 ./install.sh
```

## 📋 Prerequisites

- Linux with systemd (Ubuntu/Debian, RHEL/CentOS/Rocky/AlmaLinux/Fedora, Amazon Linux)
- Root or sudo
- curl (script will try to install if missing)

## 📝 Configuration

### Required variables

| Variable         | Required | Description |
|------------------|----------|-------------|
| `SECRET_KEY`     | Yes      | Key for JWT validation (min. 32 characters) |
| `LOKI_URL`       | Yes      | Loki URL (e.g. `https://logs-prod-xxx.grafana.net`) |
| `LOKI_API_TOKEN` | Yes     | Loki API token |
| `ALLOW_ORIGINS`  | Yes      | CORS allowed origins (comma-separated) |

### Optional variables

| Variable       | Default       | Description |
|----------------|---------------|-------------|
| `PORT`         | 3000          | HTTP port |
| `JWT_ISSUER`   | trusted-issuer | Expected JWT issuer |
| `JWT_VALIDATE_EXP` | false     | Validate JWT expiration: true/false |

### Installer variables

| Variable           | Description |
|--------------------|-------------|
| `LOCAL_BINARY`     | Path to local binary (install without download) |
| `GITHUB_REPO`      | GitHub repo (default: elven/collector-fe-instrumentation) |
| `COLLECTOR_VERSION`| Release tag (default: latest) |

## 📂 Installed files

- **Binary**: `/opt/collector-fe-instrumentation/collector-fe-instrumentation`
- **Config (env)**: `/etc/collector-fe-instrumentation/env`
- **Systemd service**: `collector-fe-instrumentation`

## ⚡ Quick Reference

| Task            | Command |
|-----------------|---------|
| **Install**     | `curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/collector-fe/install.sh \| sudo bash` |
| **Check Status**| `systemctl status collector-fe-instrumentation` |
| **Restart**     | `sudo systemctl restart collector-fe-instrumentation` |
| **Logs**        | `journalctl -u collector-fe-instrumentation -f` |
| **Health**      | `curl http://localhost:3000/health` |

## 🛠️ Useful commands

```bash
# Status
systemctl status collector-fe-instrumentation

# Restart
sudo systemctl restart collector-fe-instrumentation

# Logs (follow)
journalctl -u collector-fe-instrumentation -f

# Health check
curl http://localhost:3000/health
```

## 🔒 Security

- Installs from official GitHub releases (or local binary)
- API token and secret stored in `/etc/collector-fe-instrumentation/env` (root only)
- Service runs as dedicated user when configured

## 🔄 Updating

Re-run the installation script; it will update the existing installation.

```bash
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/collector-fe/install.sh | sudo bash
```

## 🗑️ Uninstallation

```bash
sudo systemctl stop collector-fe-instrumentation
sudo systemctl disable collector-fe-instrumentation
sudo rm /etc/systemd/system/collector-fe-instrumentation.service
sudo systemctl daemon-reload
sudo rm -rf /opt/collector-fe-instrumentation
sudo rm -rf /etc/collector-fe-instrumentation
```

## 📞 Support

- 📧 Email: support@elvenobservability.com
- 🐛 Issues: [GitHub Issues](https://github.com/elven-observability/scripts/issues)
- 📚 Documentation: [docs.elvenobservability.com](https://docs.elvenobservability.com)

---

**Elven Observability** – LGTM Stack as a Service
