#!/usr/bin/env bash
# freemind-setup/modules/vpn.sh — WireGuard (wg-easy) + защита сервера
# Подключается через install.sh, использует функции из lib/common.sh

run_module() {
    step "Свой VPN (WireGuard) — установка"

    require_root
    ensure_swap 4

    step "Docker"
    if ! command -v docker >/dev/null 2>&1; then
        log "Ставим Docker..."
        curl -fsSL https://get.docker.com | sh
    else
        ok "Docker уже стоит"
    fi

    step "WireGuard (wg-easy)"
    if docker ps -a --format '{{.Names}}' | grep -qx wg-easy; then
        ok "Контейнер wg-easy уже есть — пропускаем установку, идём к клиенту"
    else
        local server_ip wg_password
        server_ip="$(curl -fsSL ifconfig.me || hostname -I | awk '{print $1}')"
        log "IP сервера: $server_ip"
        wg_password="$(ask_secret "Придумай пароль для веб-панели WireGuard")"

        ufw allow 51820/udp >/dev/null 2>&1 || true
        ufw allow 51821/tcp >/dev/null 2>&1 || true

        docker run -d \
            --name=wg-easy \
            -e WG_HOST="$server_ip" \
            -e PASSWORD="$wg_password" \
            -v ~/.wg-easy:/etc/wireguard \
            -p 51820:51820/udp \
            -p 51821:51821/tcp \
            --cap-add=NET_ADMIN \
            --cap-add=SYS_MODULE \
            --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
            --sysctl="net.ipv4.ip_forward=1" \
            --restart unless-stopped \
            weejewel/wg-easy

        sleep 3
        if docker ps --format '{{.Names}}' | grep -qx wg-easy; then
            ok "wg-easy запущен — http://$server_ip:51821"
        else
            die "Контейнер не поднялся, смотри: docker logs wg-easy"
        fi
    fi

    echo ""
    warn "Создание клиента (профиля) делается только через веб-панель — у wg-easy нет публичного API для этого."
    echo "  1. Открой панель в браузере"
    echo "  2. Кнопка + New → назови клиента"
    echo "  3. Скачай .conf или отсканируй QR в приложении WireGuard"
    echo "  Правило гигиены: временный профиль — удаляй сразу после использования, не оставляй висеть."
    confirm "Клиент создан, продолжаем?" || warn "Ладно, продолжаем дальше — вернёшься к этому шагу позже"

    step "Домен для панели (опционально)"
    if confirm "Привязать панель к домену (https вместо http:IP:порт)?"; then
        local domain email
        domain="$(ask "Домен (например vpn.твой-домен.ru)")"
        email="$(ask "Email для Let's Encrypt (уведомления об истечении сертификата)")"
        setup_nginx_site "vpn" "$domain" "51821" "$email"
        if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
            ufw delete allow 51821/tcp >/dev/null 2>&1 || true
            ok "Прямой доступ к 51821 закрыт — только через https://$domain"
        fi
    else
        log "Пропускаем домен, панель остаётся на http://IP:51821"
    fi

    step "Защита сервера — firewall"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 51820/udp
    yes | ufw enable >/dev/null 2>&1 || ufw --force enable
    ok "ufw включён"
    ufw status verbose

    step "Блокировка торрентов — уровень 1 (iptables по портам)"
    iptables -C FORWARD -i wg0 -p tcp --dport 6881:6889 -j DROP 2>/dev/null || \
        iptables -I FORWARD -i wg0 -p tcp --dport 6881:6889 -j DROP
    iptables -C FORWARD -i wg0 -p udp --dport 6881:6889 -j DROP 2>/dev/null || \
        iptables -I FORWARD -i wg0 -p udp --dport 6881:6889 -j DROP
    iptables -C FORWARD -i wg0 -p udp --dport 6969 -j DROP 2>/dev/null || \
        iptables -I FORWARD -i wg0 -p udp --dport 6969 -j DROP
    iptables -C FORWARD -i wg0 -m connlimit --connlimit-above 50 -j DROP 2>/dev/null || \
        iptables -I FORWARD -i wg0 -m connlimit --connlimit-above 50 -j DROP
    apt_ensure iptables-persistent
    netfilter-persistent save
    ok "Правила iptables сохранены"

    step "Блокировка торрентов — уровень 2 (Suricata IPS, ловит по протоколу)"
    if confirm "Поставить Suricata? (грузит CPU, но по портам одним торренты не остановить)"; then
        apt_ensure suricata suricata-update

        sed -i 's/^LISTENMODE=af-packet/LISTENMODE=nfqueue/' /etc/default/suricata
        grep -q "LISTENMODE=nfqueue" /etc/default/suricata || echo "LISTENMODE=nfqueue" >> /etc/default/suricata

        iptables -C FORWARD -j NFQUEUE --queue-num 0 2>/dev/null || \
            iptables -I FORWARD -j NFQUEUE --queue-num 0
        netfilter-persistent save

        suricata-update enable-source et/open || true
        suricata-update

        cat > /etc/suricata/modify.conf << 'EOF'
group:emerging-p2p.rules "^alert" "drop"
EOF
        suricata-update

        systemctl enable suricata
        systemctl restart suricata

        if systemctl is-active --quiet suricata; then
            ok "Suricata активна и режет торренты по протоколу"
        else
            warn "Suricata не запустилась — смотри: journalctl -u suricata -n 50"
        fi
    else
        warn "Suricata пропущена — торренты режутся только по портам (уровень 1), обходится нестандартным портом"
    fi

    step "Готово"
    echo "WireGuard установлен, клиент(ы) создан(ы), firewall и защита от торрентов настроены."
    echo "Проверка с телефона/компьютера: подключись через .conf/QR → curl ifconfig.me должен показать IP сервера."
}
