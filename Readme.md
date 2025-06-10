
# Docker Swarm Monitor



## Dependecies

	sudo apt-get install \
		libsqlite3-dev \
		libsqlite3-tcl \
		tclx \
		tclib

## Install 

	$ sudo ./install.sh


## After installation

* Configure o Telegram: /opt/swarm-monitor/setup-telegram.sh

* Ajuste os thresholds em: /etc/swarm-monitor/config.tcl

* Inicie o serviço: systemctl start swarm-monitor

* Verifique os logs: /opt/swarm-monitor/show-logs.sh

* Verifique o status: /opt/swarm-monitor/status.sh


### Endpoints disponíveis:"

* Métricas: http://localhost:9090/metrics"
* Health: http://localhost:9090/health"


### Para configurar no Grafana:"

- URL: http://localhost:9090/metrics"


## Grafana

# Dashboard Grafana - Monitoramento Docker Swarm

Este documento descreve o dashboard completo para monitoramento do cluster Docker Swarm no Grafana.

## Estrutura do Dashboard

### 1. **Visão Geral do Cluster** (Topo)
- Número total de servidores ativos
- Total de containers no cluster
- Total de services no cluster

### 2. **Gráficos de Monitoramento em Tempo Real**
- **CPU Usage**: Gráfico de linhas mostrando uso de CPU por servidor
- **Memory Usage**: Gráfico de linhas mostrando uso de memória por servidor
- **Load Average**: Monitoramento da carga do sistema por servidor

### 3. **Tabela de Status Detalhado**
- Visão consolidada de todos os servidores com:
  - CPU, Memória e Disco (com cores baseadas em thresholds)
  - Load Average
  - Número de containers e services por servidor

### 4. **Visualizações Complementares**
- **Disk Usage**: Gráfico de barras horizontal
- **Distribuição de Containers**: Gráfico de pizza
- **Distribuição de Services**: Gráfico de pizza

### 5. **Métricas Agregadas**
- Médias do cluster para CPU, Memória, Disco e Load Average

## Configuração Necessária

### 1. **Data Source do Prometheus**
Configure o Prometheus como data source no Grafana apontando para o seu endpoint:
```
URL: http://server:port/metrics
```

### 2. **Thresholds de Alerta**
O dashboard já vem configurado com thresholds:
- **CPU**: Verde (0-70%), Amarelo (70-90%), Vermelho (90%+)
- **Memória**: Verde (0-80%), Amarelo (80-95%), Vermelho (95%+)
- **Disco**: Verde (0-80%), Amarelo (80-95%), Vermelho (95%+)
- **Load Average**: Verde (0-2), Amarelo (2-4), Vermelho (4+)

### 3. **Template Variable**
Incluí uma variável `$hostname` que permite filtrar por servidor específico, facilitando o troubleshooting.

### 4. **Refresh Automático**
Configurado para atualizar a cada 30 segundos automaticamente.

## Como Importar

1. No Grafana, vá em **Dashboards** → **Import**
2. Cole o JSON do dashboard
3. Configure o data source do Prometheus
4. Salve o dashboard

## Métricas Monitoradas

O dashboard monitora as seguintes métricas do Prometheus:

### CPU Usage
```prometheus
swarm_cpu_usage_percent{hostname="zeus"} 12.0
```

### Memory Usage
```prometheus
swarm_memory_usage_percent{hostname="zeus"} 32.64749782126372
```

### Disk Usage
```prometheus
swarm_disk_usage_percent{hostname="zeus"} 68
```

### Load Average
```prometheus
swarm_load_average{hostname="zeus"} 1.83
```

### Container Count
```prometheus
swarm_containers_total{hostname="zeus"} 1
```

### Service Count
```prometheus
swarm_services_total{hostname="zeus"} 1
```

## Funcionalidades Principais

### Alertas Visuais
- Cores automáticas baseadas em thresholds
- Indicadores visuais de problemas de performance
- Destaque para servidores com alta utilização

### Filtragem
- Filtro por hostname usando template variables
- Possibilidade de visualizar servidores específicos
- Opção "All" para ver todos os servidores

### Agregações
- Médias do cluster
- Totais consolidados
- Distribuição proporcional de recursos

### Histórico
- Gráficos de linha com histórico temporal
- Configuração de intervalo de tempo personalizável
- Zoom e navegação temporal

## Benefícios

- **Visibilidade Completa**: Monitora todos os aspectos críticos dos servidores
- **Alertas Proativos**: Identifica problemas antes que afetem o serviço
- **Análise de Tendências**: Histórico para análise de padrões de uso
- **Facilidade de Uso**: Interface intuitiva e navegação simples
- **Escalabilidade**: Suporta múltiplos servidores automaticamente

O dashboard fornece uma visão completa tanto individual quanto agregada dos seus servidores Docker Swarm, facilitando o monitoramento e identificação de problemas de performance.