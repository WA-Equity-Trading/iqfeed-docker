# Architecture & Technical Approach

This document explains how the IQFeed Docker solution works and the technical decisions behind it.

## Overview

IQFeed is a Windows-only application that provides real-time and historical market data. This project enables running IQFeed on Linux/macOS using Docker + Wine, with automated data collection via `qdownload`.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                         Host Machine                         │
│  ┌────────────┐                                              │
│  │ qdownload  │ ─────────┐                                   │
│  │  (Go CLI)  │          │                                   │
│  └────────────┘          │                                   │
│                          │                                   │
│  ┌───────────────────────▼──────────────────────────────┐   │
│  │         Docker Container (Linux amd64)               │   │
│  │                                                       │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │         Supervisor (Process Manager)         │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
│  │           │        │         │         │            │   │
│  │           ▼        ▼         ▼         ▼            │   │
│  │  ┌─────┐ ┌────┐ ┌─────┐ ┌──────────┐ ┌─────────┐  │   │
│  │  │ X11 │ │VNC │ │Flux │ │ Proxy.js │ │Keepalive│  │   │
│  │  │Vfb  │ │    │ │ box │ │(Node.js) │ │ Script  │  │   │
│  │  └─────┘ └────┘ └─────┘ └──────────┘ └─────────┘  │   │
│  │                              │              │        │   │
│  │                              ▼              ▼        │   │
│  │  ┌────────────────────────────────────────────┐    │   │
│  │  │         Wine 64 (Windows Emulation)        │    │   │
│  │  │  ┌──────────────────────────────────────┐ │    │   │
│  │  │  │  IQFeed Client (iqconnect.exe)       │ │    │   │
│  │  │  │  - Connects to DTN servers           │ │    │   │
│  │  │  │  - Authenticates with credentials    │ │    │   │
│  │  │  │  - Serves data on ports 9100/9300    │ │    │   │
│  │  │  └──────────────────────────────────────┘ │    │   │
│  │  └────────────────────────────────────────────┘    │   │
│  │                                                      │   │
│  │  Exposed Ports: 5900 (VNC), 9101, 9301             │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Key Components

### 1. Docker Container (Linux amd64)

**Base Image**: `ubuntu:22.04`
- Uses `--platform=linux/amd64` to force x86 architecture (required for Wine)
- On ARM Macs, runs via QEMU x86 emulation

**Why Ubuntu 22.04?**
- Modern Wine packages (wine64)
- Better compatibility with recent IQFeed versions
- Smaller image size vs older distros

### 2. Wine 64-bit

**Purpose**: Run Windows applications on Linux

**Configuration**:
```bash
WINEARCH=win64
WINEPREFIX=/root/.wine64
```

**Why wine64?**
- ARM Mac compatibility: `wine32` causes `virtual_alloc_first_teb` errors
- Modern IQFeed versions require 64-bit
- Better stability on emulated x86

### 3. Supervisor Process Manager

**Purpose**: Manage multiple services in the container

**Services managed**:
- `X11` (Xvfb): Virtual display
- `x11vnc`: VNC server for remote GUI access
- `fluxbox`: Lightweight window manager
- `iqfeed-startup`: IQFeed launcher with auto-restart
- `iqfeed-proxy`: Node.js connection proxy
- `iqfeed-keepalive`: Prevents idle timeout

### 4. IQFeed Startup Script (`iqfeed_startup.sh`)

**Purpose**: Install and launch IQFeed with automatic recovery

**Logic**:
```bash
if iqconnect.exe exists:
    while true:
        wine64 iqconnect.exe -autoconnect -product $PRODUCT_ID -login $LOGIN -password $PASSWORD
        # If crashes, restart after 3 seconds
        sleep 3
else:
    # First time: run installer
    wine64 iqfeed_client_installer.exe
```

**Why auto-restart loop?**
- IQFeed crashes frequently on ARM Macs (every 30-60 seconds)
- Auto-restart provides ~95% uptime despite crashes
- Critical for reliable data collection

### 5. Keepalive Script (`iqfeed_keepalive.sh`)

**Purpose**: Prevent IQFeed idle timeout disconnection

**How it works**:
```python
while True:
    # Ping admin port
    send("S,STATS\r\n" to port 9300)
    
    # Ping lookup port
    send("SBF,SPY,1\r\n" to port 9100)
    
    sleep(15 seconds)
```

**Why needed?**
- IQFeed disconnects after ~2 minutes of inactivity
- Periodic pings keep the connection alive
- Runs every 15 seconds

### 6. Node.js Proxy (`app/proxy.js`)

**Purpose**: Proxy and auto-authenticate IQFeed connections

**Functionality**:
- Listens on ports 9101, 9301 (exposed to host)
- Forwards to IQFeed ports 9100, 9300 (internal)
- Sends authentication commands on connect:
  ```javascript
  S,REGISTER CLIENT APP,<APP_NAME>,<VERSION>
  S,SET LOGINID,<LOGIN>
  S,SET PASSWORD,<PASSWORD>
  S,CONNECT
  ```

**Why proxy?**
- Simplifies client connections (auto-login)
- Keeps connection alive during restarts
- Abstraction layer for future features

### 7. VNC Access

**Purpose**: Remote GUI access for installation and troubleshooting

**Stack**:
- `Xvfb :0`: Virtual X11 display
- `fluxbox`: Minimal window manager
- `x11vnc`: VNC server on port 5900

**When needed?**
- First-time IQFeed installation (must click through installer)
- Debugging authentication errors
- Viewing IQFeed status dialogs

## Data Flow

### Installation Flow (First Run)

```
1. Container starts
2. supervisord launches iqfeed-startup
3. iqfeed_startup.sh detects no iqconnect.exe
4. Launches installer: wine64 iqfeed_client_6_2_0_25.exe
5. User connects via VNC and completes installation
6. Installer finishes, iqconnect.exe is now installed
7. Script detects iqconnect.exe and launches it
8. IQFeed authenticates and starts serving data
```

### Data Collection Flow (Normal Operation)

```
1. User runs: qdownload -s 20251201 -e 20251210 eod SPY
2. qdownload connects to localhost:9101 (proxy)
3. proxy.js forwards to IQFeed port 9100
4. IQFeed queries DTN servers for historical data
5. IQFeed returns data to proxy
6. proxy forwards data to qdownload
7. qdownload saves to data/eod/SPY.csv
```

### Keepalive Flow (Background)

```
Every 15 seconds:
1. keepalive script sends "S,STATS\r\n" to port 9300
2. IQFeed responds with status
3. IQFeed's idle timer resets
4. Connection stays alive
```

## Technical Challenges & Solutions

### Challenge 1: ARM Mac Compatibility

**Problem**: Wine + IQFeed crashes frequently on ARM (M1/M2/M3) due to x86 emulation

**Solutions**:
1. **Force amd64**: `--platform=linux/amd64` in Dockerfile and docker run
2. **Use wine64**: Avoid wine32 which has virtual memory errors
3. **Auto-restart**: While loop in startup script restarts IQFeed on crash
4. **Quick data collection**: Download immediately after startup before crash

**Trade-off**: ~30-60 second uptime per IQFeed instance, but auto-restart provides continuity

### Challenge 2: Idle Timeout

**Problem**: IQFeed disconnects after 2 minutes of inactivity

**Solution**: Keepalive script pings every 15 seconds

**Why 15 seconds?**
- Safe margin below 2-minute timeout
- Low overhead (4 requests/minute)
- Tested to prevent disconnections

### Challenge 3: Installation Persistence

**Problem**: Docker containers are ephemeral - IQFeed installation lost on recreate

**Solutions Attempted**:
1. ❌ Bake installation into image: Installer requires GUI interaction
2. ❌ Docker volumes: Wine prefix corruption issues
3. ✅ **Current**: Install via VNC on first run, keep container running

**Best Practice**: Build once, run container long-term, only recreate when needed

### Challenge 4: Authentication

**Problem**: IQFeed requires product ID + credentials, errors are cryptic

**Solution**: Environment variables passed at runtime
```bash
-e LOGIN=<id> -e PASSWORD=<pass> -e PRODUCT_ID=<product>
```

**Why runtime vs build-time?**
- Security: Credentials not baked into image
- Flexibility: Same image for multiple accounts
- .env file support for easy management

## Performance Considerations

### Image Size

- Base Ubuntu 22.04: ~200 MB
- Wine + dependencies: ~800 MB
- IQFeed client (installed at runtime): ~100 MB
- **Total**: ~1.1 GB (smaller than original 1.8 GB image)

### Network

- IQFeed → DTN: ~1-10 Mbps (depends on data frequency)
- qdownload → IQFeed: LAN speed (localhost)
- Keepalive: <1 KB/s (negligible)

### CPU/Memory

- Wine + IQFeed: ~200-400 MB RAM
- Idle: 5-10% CPU
- During data download: 20-40% CPU
- ARM Mac: 2-3x CPU overhead due to x86 emulation

## Security

### Credentials Storage

- **Never commit** `.env` file (in `.gitignore`)
- Passed as environment variables at runtime
- Not visible in `docker ps` output (only in container)

### Network Exposure

- Only expose necessary ports (5900, 9101, 9301)
- Bind to `127.0.0.1` in production for local-only access
- VNC has no authentication (use SSH tunnel for remote access)

## Future Improvements

### Potential Enhancements

1. **Pre-installed Image**
   - Create image with IQFeed pre-installed
   - Use Docker commit after manual installation
   - Trade-off: Larger image, not automatable

2. **Better ARM Support**
   - Investigate Rosetta 2 direct integration
   - Consider native ARM Windows builds (if IQFeed releases)

3. **Health Checks**
   - Docker health check endpoint
   - Automatic restart on unhealthy state

4. **Data Persistence**
   - Docker volume for downloaded data
   - Automatic backup/sync to cloud storage

5. **Web UI**
   - Simple web interface for monitoring
   - Data download history and status

## Alternatives Considered

### 1. Native Windows Installation
**Pros**: Most stable, official support  
**Cons**: Requires Windows machine, not automatable

### 2. Windows VM (VirtualBox/VMware)
**Pros**: Better compatibility than Wine  
**Cons**: Large resource overhead, complex setup

### 3. Cloud Windows Instance (AWS/Azure)
**Pros**: Stable, scalable  
**Cons**: Ongoing cost, more complex networking

### 4. Different Data Provider
**Pros**: May have better Linux support  
**Cons**: Cost, data quality, existing IQFeed integration

**Decision**: Docker + Wine is best balance of automation, portability, and cost for development/testing.

## References

- [IQFeed Documentation](https://www.iqfeed.net/dev/)
- [Wine Documentation](https://wiki.winehq.org/)
- [qdownload GitHub](https://github.com/nhedlund/qdownload)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
