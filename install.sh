#!/bin/bash

# ==============================================================================
# Script de Instalação do Docker Swarm Monitor
# ==============================================================================

set -e

echo "🚀 Instalando Docker Swarm Monitor..."

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Este script deve ser executado como root"
   exit 1
fi

# Instalar dependências
#echo "📦 Instalando dependências..."
#apt-get update
#apt-get install -y tcl tcl-dev sqlite3 libsqlite3-tcl

# Verificar se os pacotes TCL necessários estão disponíveis
echo "🔍 Verificando pacotes TCL..."
tclsh << 'EOF'
if {[catch {package require http}]} {
    puts "❌ Pacote http não encontrado"
    exit 1
}
if {[catch {package require json}]} {
    puts "⚠️  Pacote json não encontrado, tentando instalar..."
    # Instalar tcllib se não estiver disponível
    exec apt-get install -y tcllib
}
if {[catch {package require sqlite3}]} {
    puts "❌ Pacote sqlite3 não encontrado"
    exit 1
}
if {[catch {package require Tclx}]} {
    puts "❌ Pacote Tclx não encontrado"
    exit 1
}
puts "✅ Todos os pacotes TCL necessários estão disponíveis"
EOF

# Criar diretórios
echo "📁 Criando estrutura de diretórios..."
mkdir -p /opt/swarm-monitor
mkdir -p /var/log/swarm-monitor
mkdir -p /etc/swarm-monitor

# Copiar script principal
echo "📄 Copiando arquivos..."
cp monitor.tcl /opt/swarm-monitor/monitor.tcl 

# Tornar executável
chmod +x /opt/swarm-monitor/monitor.tcl


if [ -f /etc/swarm-monitor/config.tcl ]; then 
    echo "  Config file already exists: /etc/swarm-monitor/config.tcl"
else

# Criar arquivo de configuração
echo "⚙️  Criando arquivo de configuração..."
cat > /etc/swarm-monitor/config.tcl << 'EOF'
# Configuração do Docker Swarm Monitor
array set CONFIG {
    telegram_bot_token "SEU_BOT_TOKEN_AQUI"
    telegram_chat_id "SEU_CHAT_ID_AQUI"
    metrics_db "/var/log/swarm-monitor/metrics.db"
    http_port 9090
    collect_interval 30
    analysis_window 300
    memory_threshold_warning 80
    memory_threshold_critical 90
    cpu_threshold_warning 80
    cpu_threshold_critical 90
    disk_threshold_warning 85
    disk_threshold_critical 95
}
EOF

fi

# Criar serviço systemd
echo "🔧 Criando serviço systemd..."
cat > /etc/systemd/system/swarm-monitor.service << 'EOF'
[Unit]
Description=Docker Swarm Monitor
After=docker.service
Requires=docker.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
User=root
ExecStart=/usr/bin/tclsh /opt/swarm-monitor/monitor.tcl
ExecReload=/bin/kill -HUP $MAINPID
StandardOutput=journal
StandardError=journal
SyslogIdentifier=swarm-monitor

# Limites de recursos para o próprio monitor
MemoryMax=256M
CPUQuota=10%

[Install]
WantedBy=multi-user.target
EOF

# Criar script de configuração do Telegram
echo "📱 Criando helper para configuração do Telegram..."
cat > /opt/swarm-monitor/setup-telegram.sh << 'EOF'
#!/bin/bash

echo "🤖 Configuração do Bot Telegram"
echo "================================"
echo
echo "Para configurar as notificações do Telegram, você precisa:"
echo "1. Criar um bot no Telegram conversando com @BotFather"
echo "2. Obter o token do bot"
echo "3. Obter seu chat_id"
echo

read -p "Digite o token do bot: " BOT_TOKEN
if [[ -z "$BOT_TOKEN" ]]; then
    echo "❌ Token não pode estar vazio"
    exit 1
fi

echo "Para obter seu chat_id:"
echo "1. Envie uma mensagem para seu bot"
echo "2. Acesse: https://api.telegram.org/bot${BOT_TOKEN}/getUpdates"
echo "3. Procure pelo campo 'chat' -> 'id'"
echo

read -p "Digite seu chat_id: " CHAT_ID
if [[ -z "$CHAT_ID" ]]; then
    echo "❌ Chat ID não pode estar vazio"
    exit 1
fi

# Atualizar arquivo de configuração
sed -i "s/SEU_BOT_TOKEN_AQUI/$BOT_TOKEN/g" /etc/swarm-monitor/config.tcl
sed -i "s/SEU_CHAT_ID_AQUI/$CHAT_ID/g" /etc/swarm-monitor/config.tcl

echo "✅ Configuração do Telegram atualizada!"

# Testar notificação
echo "🧪 Testando notificação..."
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
     -d "chat_id=${CHAT_ID}" \
     -d "text=🚀 Docker Swarm Monitor configurado com sucesso!" \
     -d "parse_mode=Markdown"

if [[ $? -eq 0 ]]; then
    echo "✅ Notificação de teste enviada!"
else
    echo "❌ Falha ao enviar notificação de teste"
fi
EOF

chmod +x /opt/swarm-monitor/setup-telegram.sh

# Criar script de logs
cat > /opt/swarm-monitor/show-logs.sh << 'EOF'
#!/bin/bash
echo "📊 Logs do Docker Swarm Monitor"
echo "==============================="
journalctl -u swarm-monitor -f --no-pager
EOF

chmod +x /opt/swarm-monitor/show-logs.sh

# Criar script de status
cat > /opt/swarm-monitor/status.sh << 'EOF'
#!/bin/bash
echo "📈 Status do Docker Swarm Monitor"
echo "================================="
systemctl status swarm-monitor
echo
echo "📊 Últimas métricas (endpoint HTTP):"
curl -s http://localhost:9090/health | jq . 2>/dev/null || echo "Endpoint não disponível"
echo
echo "💾 Banco de dados:"
ls -lh /var/log/swarm-monitor/metrics.db 2>/dev/null || echo "Banco não encontrado"
EOF

chmod +x /opt/swarm-monitor/status.sh

# Habilitar e iniciar serviço
echo "🚀 Habilitando serviço..."
systemctl daemon-reload
systemctl enable swarm-monitor

echo
echo "✅ Instalação concluída!"
echo
echo "📋 Próximos passos:"
echo "1. Configure o Telegram: /opt/swarm-monitor/setup-telegram.sh"
echo "2. Ajuste os thresholds em: /etc/swarm-monitor/config.tcl"
echo "3. Inicie o serviço: systemctl start swarm-monitor"
echo "4. Verifique os logs: /opt/swarm-monitor/show-logs.sh"
echo "5. Verifique o status: /opt/swarm-monitor/status.sh"
echo
echo "🌐 Endpoints disponíveis:"
echo "  - Métricas: http://localhost:9090/metrics"
echo "  - Health: http://localhost:9090/health"
echo
echo "📊 Para configurar no Grafana:"
echo "  - URL: http://SEU_IP:9090/metrics"
echo "  - Tipo: Prometheus"
echo