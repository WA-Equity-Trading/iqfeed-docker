# Force amd64 platform for Wine compatibility
FROM --platform=linux/amd64 ubuntu:22.04

# Set correct environment variables
ENV HOME /root
ENV DEBIAN_FRONTEND noninteractive
ENV LC_ALL C.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
ENV DISPLAY :0
ENV WINE_MONO_VERSION 8.1.0
ENV IQFEED_INSTALLER="iqfeed_client_6_2_0_25.exe"

# Wine64 configuration (critical for ARM Mac compatibility)
ENV WINEARCH win64
ENV WINEPREFIX /root/.wine64

# Install basic dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git curl wget ca-certificates gnupg2 software-properties-common \
        x11vnc xvfb xdotool supervisor fluxbox \
        net-tools cabextract unzip p7zip-full zenity \
        python3 nodejs npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Add i386 architecture and install Wine from Ubuntu repos
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends wine wine32 wine64 winbind && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    # Install winetricks
    curl -SL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -o /usr/local/bin/winetricks && \
    chmod +x /usr/local/bin/winetricks

WORKDIR /root/

# Add supervisor conf
ADD supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Download IQFeed installer
RUN wget -O /root/$IQFEED_INSTALLER http://www.iqfeed.net/$IQFEED_INSTALLER || \
    wget -O /root/$IQFEED_INSTALLER http://www.iqfeed.net/iqfeed_client_6_2_0_25.exe

# Add startup and keepalive scripts
ADD iqfeed_startup.sh /root/iqfeed_startup.sh
ADD iqfeed_keepalive.sh /root/iqfeed_keepalive.sh
RUN chmod +x /root/iqfeed_startup.sh /root/iqfeed_keepalive.sh

# Add iqfeed proxy app
ADD app /root/app

# Pre-initialize Wine64 prefix to avoid runtime issues on ARM
RUN wineboot --init 2>&1 | head -n 10 || true

CMD ["/usr/bin/supervisord"]

# Expose Ports
EXPOSE 5010
EXPOSE 9101
EXPOSE 9301
EXPOSE 5900
