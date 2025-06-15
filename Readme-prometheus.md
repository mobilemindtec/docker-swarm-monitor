# Configuração do Prometheus para Métricas Docker Swarm

## Visão Geral

Este documento descreve como configurar o Prometheus para coletar métricas de um cluster Docker Swarm através de um endpoint personalizado que expõe métricas de sistema e containers.

## Métricas Disponíveis

O endpoint fornece as seguintes métricas:

| Métrica | Descrição | Tipo |
|---------|-----------|------|
| `swarm_cpu_usage_percent` | Percentual de uso de CPU do host | Gauge |
| `swarm_memory_usage_percent` | Percentual de uso de memória do host | Gauge |
| `swarm_disk_usage_percent` | Percentual de uso de disco do host | Gauge |
| `swarm_load_average` | Load average do sistema | Gauge |
| `swarm_containers_total` | Número total de containers | Counter |
| `swarm_services_total` | Número total de serviços | Counter |

Todas as métricas incluem o label `hostname` que identifica o host do cluster.

## Pré-requisitos

- Prometheus instalado e funcionando
- Acesso de rede ao endpoint de métricas
- Permissões para editar o arquivo `prometheus.yml`

## Configuração

### 1. Configuração do prometheus.yml

Adicione o seguinte job ao seu arquivo `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'docker-swarm-metrics'
    static_configs:
      - targets: ['server:PORT']
    scrape_interval: 30s
    scrape_timeout: 10s
    metrics_path: '/metrics'
    scheme: http
```

### 2. Parâmetros de Configuração

#### Parâmetros Obrigatórios

- **job_name**: Nome identificador do job (use um nome descritivo)
- **targets**: Lista de endpoints no formato `hostname:porta`
- **metrics_path**: Caminho para o endpoint de métricas (padrão: `/metrics`)

#### Parâmetros Opcionais

- **scrape_interval**: Intervalo entre coletas (padrão: global scrape_interval)
- **scrape_timeout**: Timeout para cada coleta (padrão: 10s)
- **scheme**: Protocolo utilizado (`http` ou `https`)

### 3. Configurações Avançadas

#### Autenticação Básica

```yaml
basic_auth:
  username: 'seu_usuario'
  password: 'sua_senha'
```

#### Headers Customizados

```yaml
headers:
  X-Custom-Header: 'valor'
```

#### Labels Estáticos

```yaml
static_configs:
  - targets: ['server:PORT']
    labels:
      environment: 'production'
      cluster: 'swarm-prod'
```

## Exemplo de Configuração Completa

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'docker-swarm-metrics'
    static_configs:
      - targets: ['server:9323']
    scrape_interval: 30s
    scrape_timeout: 10s
    metrics_path: '/metrics'
    scheme: http
    static_configs:
      - targets: ['server:9323']
        labels:
          environment: 'production'
          service: 'docker-swarm'
```

## Implementação

### 1. Editar Configuração

```bash
# Backup do arquivo atual
sudo cp /etc/prometheus/prometheus.yml /etc/prometheus/prometheus.yml.backup

# Editar o arquivo
sudo nano /etc/prometheus/prometheus.yml
```

### 2. Validar Configuração

```bash
# Verificar sintaxe
promtool check config /etc/prometheus/prometheus.yml
```

### 3. Aplicar Configuração

#### Opção 1: Restart do Serviço
```bash
sudo systemctl restart prometheus
```

#### Opção 2: Reload sem Restart
```bash
curl -X POST http://localhost:9090/-/reload
```

#### Opção 3: Docker
```bash
docker restart prometheus
```

## Verificação e Monitoramento

### 1. Verificar Targets

Acesse: `http://localhost:9090/targets`

Status esperado: **UP** para o target configurado

### 2. Testar Métricas

Acesse: `http://localhost:9090/graph`

Consultas de exemplo:
```promql
# CPU usage
swarm_cpu_usage_percent{hostname="server"}

# Memory usage
swarm_memory_usage_percent{hostname="server"}

# All metrics from specific host
{hostname="server"}
```

## Consultas PromQL Úteis

### Métricas Básicas
```promql
# CPU usage atual
swarm_cpu_usage_percent

# Memória acima de 80%
swarm_memory_usage_percent > 80

# Disco acima de 90%
swarm_disk_usage_percent > 90
```

### Consultas Avançadas
```promql
# Taxa de crescimento de containers (últimos 5 minutos)
rate(swarm_containers_total[5m])

# Load average médio (última hora)
avg_over_time(swarm_load_average[1h])

# Hosts com maior uso de CPU
topk(5, swarm_cpu_usage_percent)
```

## Alertas Recomendados

### Alertas de Sistema
```yaml
# Alta utilização de CPU
- alert: HighCPUUsage
  expr: swarm_cpu_usage_percent > 80
  for: 5m
  labels:
    severity: warning

# Alta utilização de memória
- alert: HighMemoryUsage
  expr: swarm_memory_usage_percent > 85
  for: 5m
  labels:
    severity: critical

# Disco quase cheio
- alert: DiskSpaceHigh
  expr: swarm_disk_usage_percent > 90
  for: 1m
  labels:
    severity: critical
```

## Troubleshooting

### Problemas Comuns

#### Target DOWN
- Verificar conectividade de rede
- Confirmar porta e protocolo
- Verificar firewall

#### Métricas não aparecem
- Verificar formato das métricas no endpoint
- Confirmar o `metrics_path`
- Verificar logs do Prometheus

#### Timeout
- Aumentar `scrape_timeout`
- Reduzir `scrape_interval`
- Verificar performance do endpoint

### Logs do Prometheus

```bash
# SystemD
sudo journalctl -u prometheus -f

# Docker
docker logs prometheus -f
```

### Comandos de Diagnóstico

```bash
# Testar endpoint manualmente
curl http://server:PORT/metrics

# Verificar configuração
promtool check config prometheus.yml

# Verificar regras
promtool check rules rules.yml
```

## Considerações de Performance

### Otimizações Recomendadas

1. **Intervalo de Coleta**: Ajustar `scrape_interval` conforme necessário
2. **Retenção**: Configurar período de retenção adequado
3. **Agregação**: Usar recording rules para métricas complexas
4. **Indexação**: Otimizar labels para consultas frequentes

### Monitoramento do Prometheus

```promql
# Status dos targets
up{job="docker-swarm-metrics"}

# Duração das coletas
prometheus_target_scrape_duration_seconds

# Métricas por segundo
rate(prometheus_tsdb_symbol_table_size_bytes[5m])
```

## Segurança

### Recomendações

1. **HTTPS**: Use sempre que possível
2. **Autenticação**: Configure basic auth ou certificados
3. **Firewall**: Restrinja acesso às portas necessárias
4. **Monitoramento**: Monitore acessos e tentativas de conexão

### Exemplo com HTTPS
```yaml
scheme: https
tls_config:
  ca_file: /path/to/ca.pem
  cert_file: /path/to/cert.pem
  key_file: /path/to/key.pem
  insecure_skip_verify: false
```

## Backup e Disaster Recovery

### Backup da Configuração
```bash
# Backup automático
tar -czf prometheus-config-$(date +%Y%m%d).tar.gz /etc/prometheus/
```

### Backup dos Dados
```bash
# Backup do diretório de dados
tar -czf prometheus-data-$(date +%Y%m%d).tar.gz /var/lib/prometheus/
```

## Referências

- [Documentação Oficial do Prometheus](https://prometheus.io/docs/)
- [PromQL Query Language](https://prometheus.io/docs/prometheus/latest/querying/)
- [Docker Swarm Monitoring](https://docs.docker.com/engine/swarm/)
- [Best Practices](https://prometheus.io/docs/practices/)