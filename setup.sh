#!/bin/bash

if [ $# -ne 2 ]; then
    echo "Uso: $0 <machine_id> <api_key>"
    echo "Exemplo: $0 servidor-01 sua-chave-api"
    exit 1
fi

MACHINE_ID="$1"
API_KEY="$2"

# Diretório para os scripts e logs
SCRIPT_DIR="/opt/monitoring"
LOG_DIR="/var/log/monitoring"


# Instalar cron
sudo apt-get update
sudo apt-get install cron

sudo systemctl start cron
sudo systemctl enable cron

# Criar diretórios necessários
sudo mkdir -p $SCRIPT_DIR
sudo mkdir -p $LOG_DIR

# Script Python para coletar e enviar métricas
cat << EOF | sudo tee $SCRIPT_DIR/collect_metrics.py
import psutil
import json
import datetime
import socket
import requests
import os
import time
import random
import uuid

API_URL = "http://44.201.198.38:80/services/machine-status/$MACHINE_ID"
API_KEY = "$API_KEY"

def collect_system_metrics():
    # Converter bytes para GB
    def bytes_to_gb(bytes_value):
        return round(bytes_value / (1024 ** 3), 2)

    metrics = {
        "timestamp": datetime.datetime.now().isoformat(),
        "hostname": socket.gethostname(),
        "system_capacity": {
            "cpu_cores": {
                "physical": psutil.cpu_count(logical=False),
                "total": psutil.cpu_count(logical=True)
            },
            "memory_total_gb": bytes_to_gb(psutil.virtual_memory().total),
            "disk_total_gb": bytes_to_gb(psutil.disk_usage('/').total)
        },
        "cpu": {
            "percent": psutil.cpu_percent(interval=1),
            "count": psutil.cpu_count(),
            "load_avg": psutil.getloadavg()
        },
        "memory": {
            "total": psutil.virtual_memory().total,
            "available": psutil.virtual_memory().available,
            "percent": psutil.virtual_memory().percent,
            "used": psutil.virtual_memory().used
        },
        "disk": {
            "total": psutil.disk_usage('/').total,
            "used": psutil.disk_usage('/').used,
            "free": psutil.disk_usage('/').free,
            "percent": psutil.disk_usage('/').percent
        },
        "network": {
            "bytes_sent": psutil.net_io_counters().bytes_sent,
            "bytes_recv": psutil.net_io_counters().bytes_recv,
            "packets_sent": psutil.net_io_counters().packets_sent,
            "packets_recv": psutil.net_io_counters().packets_recv
        },
        "processes": len(list(psutil.process_iter())),
        "boot_time": psutil.boot_time()
    }
    return metrics

def send_metrics_to_api(metrics):
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'{API_KEY}',
        'User-Agent': f'MonitoringScript/$MACHINE_ID',
        'X-Request-From': str(uuid.uuid4()),
        'Accept': 'application/json',
        'Connection': 'keep-alive',
        'Cache-Control': 'no-cache'
    }
    
    try:
        # Adicionar um pequeno atraso aleatório para evitar requisições simultâneas
        time.sleep(random.uniform(0, 2))
        print("Enviando métricas para API:", metrics)
        response = requests.post(API_URL, json=metrics, headers=headers, timeout=10,  allow_redirects=False, verify=False)
        
        # Verificar se recebemos código 429 (Too Many Requests)
        if response.status_code == 429:
            # Esperar o tempo sugerido pelo header Retry-After ou 60 segundos por padrão
            retry_after = int(response.headers.get('Retry-After', 60))
            time.sleep(retry_after)
            # Tentar novamente a requisição
            response = requests.post(API_URL, json=metrics, headers=headers, timeout=10)
            
        response.raise_for_status()
        return True
    except requests.exceptions.RequestException as e:
        raise Exception(f"Erro ao enviar métricas para API: {str(e)}")

def main():
    try:
        metrics = collect_system_metrics()
        success = send_metrics_to_api(metrics)
        
        if success:
            print(f"{datetime.datetime.now()}: Métricas enviadas com sucesso")
        
    except Exception as e:
        error_msg = f"{datetime.datetime.now()}: {str(e)}\n"
        print(error_msg)
        with open("/var/log/monitoring/error.log", "a") as f:
            f.write(error_msg)

if __name__ == "__main__":
    main()
EOF

# Script para instalar dependências
cat << 'EOF' | sudo tee $SCRIPT_DIR/install_dependencies.sh
#!/bin/bash

# Instalar pip se não estiver instalado
if ! command -v pip &> /dev/null; then
    apt-get update
    apt-get install -y python3-pip
fi

# Instalar dependências Python
pip install psutil requests

# Verificar se as dependências foram instaladas corretamente
if [ $? -eq 0 ]; then
    echo "Dependências instaladas com sucesso"
else
    echo "Erro ao instalar dependências"
    exit 1
fi
EOF

# Tornar os scripts executáveis
sudo chmod +x $SCRIPT_DIR/install_dependencies.sh

# Instalar dependências
sudo $SCRIPT_DIR/install_dependencies.sh

# Configurar o cron
CURRENT_USER=$(whoami)
CRON_CMD="*/5 * * * * /usr/bin/python3 $SCRIPT_DIR/collect_metrics.py >> $LOG_DIR/metrics.log 2>&1"

if [ "$CURRENT_USER" = "root" ]; then
    # Se executando como root, adicionar ao crontab do root
    (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
else
    # Se não for root, adicionar ao crontab do usuário atual
    # e garantir que o usuário tenha permissões necessárias
    sudo chown -R $CURRENT_USER:$CURRENT_USER $LOG_DIR
    sudo chown -R $CURRENT_USER:$CURRENT_USER $SCRIPT_DIR
    (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
fi

echo "Cron configurado para o usuário: $CURRENT_USER"

# Criar arquivo de log e definir permissões
sudo touch $LOG_DIR/metrics.log
sudo touch $LOG_DIR/error.log
sudo chmod 644 $LOG_DIR/metrics.log
sudo chmod 644 $LOG_DIR/error.log

echo "Configuração do monitoramento concluída!"
echo "Logs disponíveis em: $LOG_DIR"
echo "Scripts instalados em: $SCRIPT_DIR"
