Ah! This is the key insight! That makes much more sense now.
What You're Saying:
IQFeed has an idle timeout - if you're not actively querying/using it, the connection drops and IQFeed crashes. This is actually normal behavior for many data feed services to conserve resources.
Why You Had Problems:
Looking back at your experience:
✅ When it worked: You connected via VNC, installed IQFeed, and immediately ran qdownload → Data collected successfully
❌ When it failed (0 rows): You started the container, waited/troubleshot for a while, then tried qdownload → IQFeed had already timed out and crashed
The Solution: Timing is Everything
You need to use IQFeed immediately after it starts. Here's the workflow:
Current Working Approach:
# 1. Start containerdocker run -d --name iqfeed-modern --platform=linux/amd64 \  -e LOGIN=523028 -e PASSWORD=zisbiv-xUszub-2gugta \  -p 5900:5900 -p 9100:9101 -p 9300:9301 \  my-iqfeed:latest# 2. Wait ~30 seconds for IQFeed to initializesleep 30# 3. Check if readydocker exec iqfeed-modern python3 /root/is_iqfeed_running.py# 4. IMMEDIATELY download data (don't wait!)qdownload -s 20251201 -e 20251210 -o data/test eod SPY,AAPL,MSFT
Better Solutions:
Option A: Batch Download Script
Create a script that starts the container and immediately downloads all your data in one go:
#!/bin/bash# start_and_download.sh# Start containerdocker run -d --name iqfeed-modern --platform=linux/amd64 \  -e LOGIN=523028 -e PASSWORD=zisbiv-xUszub-2gugta \  -p 5900:5900 -p 9100:9101 -p 9300:9301 \  my-iqfeed:latest# Wait for IQFeed to be readyecho "Waiting for IQFeed to start..."sleep 45# Download all your data immediatelyecho "Downloading data..."qdownload -s 20251201 -e 20251210 -o data/eod eod SPY,AAPL,MSFT,GOOG,AMZNqdownload -s 20251201 -e 20251210 -o data/minute minute SPY# ... add all your downloads here# Stop container when donedocker stop iqfeed-moderndocker rm iqfeed-modern