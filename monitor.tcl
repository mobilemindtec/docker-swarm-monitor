#!/usr/bin/tclsh

# ==============================================================================
# Docker Swarm Monitor - Sistema de Monitoramento e Auto-Recovery
# ==============================================================================

package require http
package require tls
package require json
package require sqlite3
package require Tclx

http::register https 443 [list ::tls::socket -autoservername true]

proc log_message {level message} {
    set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    puts "\[$timestamp\] \[$level\] $message"
    
    # Log crítico também vai para syslog
    if {$level eq "CRITICAL" || $level eq "ERROR"} {
        exec logger -t swarm_monitor "$level: $message"
    }
}


if { [file exists ./config.tcl] } {
    log_message "INFO" "Load local configs: ./config.tcl"
    source ./config.tcl
} elseif { [file exists /etc/swarm-monitor/config.tcl] } {
    log_message "INFO" "Load configs at /etc/swarm-monitor/config.tcl"
    source /etc/swarm-monitor/config.tcl
} else {

    log_message "CRITICAL" "File configs not found. Use in-memory configs"

    # Configurações
    array set CONFIG {
        telegram_bot_token "SEU_BOT_TOKEN_AQUI"
        telegram_chat_id "SEU_CHAT_ID_AQUI"
        metrics_db "/var/log/swarm_metrics.db"
        http_port 9090
        collect_interval 10
        analysis_window 300
        memory_threshold_warning 80
        memory_threshold_critical 90
        cpu_threshold_warning 80
        cpu_threshold_critical 90
        disk_threshold_warning 85
        disk_threshold_critical 95
    }
}

# Variáveis globais
set metrics_history {}
set last_notification {}
set http_server_socket ""

# ==============================================================================
# Funções de Configuração e Inicialização
# ==============================================================================

proc init_database {} {
    global CONFIG
    
    sqlite3 db $CONFIG(metrics_db)
    
    db eval {
        CREATE TABLE IF NOT EXISTS metrics (
            timestamp INTEGER PRIMARY KEY,
            hostname TEXT,
            cpu_usage REAL,
            memory_usage REAL,
            memory_total INTEGER,
            memory_available INTEGER,
            disk_usage REAL,
            load_avg REAL,
            docker_containers INTEGER,
            docker_services INTEGER,
            action_taken TEXT
        );
        
        CREATE INDEX IF NOT EXISTS idx_timestamp ON metrics(timestamp);
        CREATE INDEX IF NOT EXISTS idx_hostname ON metrics(hostname);
    }
}



# ==============================================================================
# Funções de Coleta de Métricas
# ==============================================================================

proc get_system_metrics {} {
    set metrics {}
    
    # Hostname
    set hostname [exec hostname]
    dict set metrics hostname $hostname
    
    # CPU Usage
    set cpu_usage [get_cpu_usage]
    dict set metrics cpu_usage $cpu_usage
    
    # Memory Usage
    set memory_info [get_memory_info]
    dict set metrics memory_usage [dict get $memory_info usage_percent]
    dict set metrics memory_total [dict get $memory_info total]
    dict set metrics memory_available [dict get $memory_info available]
    
    # Disk Usage
    set disk_usage [get_disk_usage]
    dict set metrics disk_usage $disk_usage
    
    # Load Average
    set load_avg [get_load_average]
    dict set metrics load_avg $load_avg
    
    # Docker Info
    set docker_info [get_docker_info]
    dict set metrics docker_containers [dict get $docker_info containers]
    dict set metrics docker_services [dict get $docker_info services]
    
    # Docker containers stats
    dict set metrics docker_containers_stats [get_containers_stats]

    # Timestamp
    dict set metrics timestamp [clock seconds]
    
    return $metrics
}

proc get_cpu_usage {} {
    # Usa vmstat para obter uso de CPU
    set output [exec vmstat 1 2]
    set lines [split $output "\n"]
    set last_line [lindex $lines end]
    set fields [regexp -all -inline {\S+} $last_line]
    
    # Campo 'id' (idle) é o último campo relevante
    if {[llength $fields] >= 15} {
        set idle [lindex $fields 14]
        return [expr {100.0 - $idle}]
    }
    return 0.0
}

proc get_memory_info {} {
    set meminfo [exec cat /proc/meminfo]
    set memory_data {}
    
    foreach line [split $meminfo "\n"] {
        if {[regexp {^(\w+):\s*(\d+)\s*kB} $line -> key value]} {
            dict set memory_data $key [expr {$value * 1024}]
        }
    }
    
    set total [dict get $memory_data MemTotal]
    set available [dict get $memory_data MemAvailable]
    set used [expr {$total - $available}]
    set usage_percent [expr {($used * 100.0) / $total}]
    
    return [dict create \
        total $total \
        available $available \
        used $used \
        usage_percent $usage_percent]
}

proc get_disk_usage {} {
    set output [exec df -h /]
    set lines [split $output "\n"]
    set data_line [lindex $lines 1]
    set fields [regexp -all -inline {\S+} $data_line]
    
    if {[llength $fields] >= 5} {
        set usage_str [lindex $fields 4]
        return [string trimright $usage_str "%"]
    }
    return 0
}

proc get_load_average {} {
    set loadavg [exec cat /proc/loadavg]
    set fields [split $loadavg]
    return [lindex $fields 0]
}

proc get_docker_info {} {
    set containers 0
    set services 0
    
    if {![catch {exec docker ps -q} container_ids]} {
        set containers [llength [split $container_ids "\n"]]
    }
    
    if {![catch {exec docker service ls -q} service_ids]} {
        set services [llength [split $service_ids "\n"]]
    }
    
    return [dict create containers $containers services $services]
}

# Função para obter estatísticas de CPU dos containers
proc get_containers_stats {} {
    
    if {[catch {exec docker stats --no-stream --format "table {{.Container}} {{.CPUPerc}} {{.MemPerc}} {{.Name}}"} result]} {
        log_message "ERROR" "Falha ao executar docker stats: $result"
        return {}
    }
    
    set lines [split $result "\n"]
    set containers {}
    
    # Pular a primeira linha (cabeçalho)
    foreach line [lrange $lines 1 end] {
        if {$line eq ""} continue
        
        lassign $line container_id cpu_percent mem_percent container_name
        
        # Remover o símbolo % e converter para número
        set cpu_value [string trimright $cpu_percent "%"]
        set mem_value [string trimright $mem_percent "%"]

        set container [dict create \
                                id $container_id \
                                cpu_usage $cpu_value \
                                memory_usage $mem_value \
                                name $container_name]

        

        lappend containers $container
        
    }
    
    return $containers
}

# ==============================================================================
# Funções de Análise e Decisão
# ==============================================================================

proc analyze_metrics {metrics_list} {
    global CONFIG
    
    if {[llength $metrics_list] == 0} {
        return [dict create action "none" severity "info"]
    }
    
    # Calcular médias dos últimos 5 minutos
    set cpu_sum 0.0
    set memory_sum 0.0
    set disk_sum 0.0
    set count 0
    set stats {}
    
    foreach metrics $metrics_list {
        set cpu_sum [expr {$cpu_sum + [dict get $metrics cpu_usage]}]
        set memory_sum [expr {$memory_sum + [dict get $metrics memory_usage]}]
        set disk_sum [expr {$disk_sum + [dict get $metrics disk_usage]}]

        set containers_stats [dict get $metrics docker_containers_stats]

        foreach container $containers_stats {

            set stat {}
            set id [dict get $container id]

            if {[dict exists $stats $id]} {
                set stat [dict get $stats $id]
                dict set stat cpu_usage [expr {[dict get $stat cpu_usage] + [dict get $container cpu_usage]}] 
                dict set stat memory_usage [expr {[dict get $stat memory_usage] + [dict get $container memory_usage]}] 
                dict set stat count [expr {[dict get $stat count] + 1}] 

            } else {
                dict set stat id $id
                dict set stat name [dict get $container name]
                dict set stat cpu_usage [dict get $container cpu_usage]
                dict set stat memory_usage [dict get $container memory_usage]                
                dict set stat count 1
            }

            dict set stats $id $stat

        }

        incr count
    }
    
    if {$count == 0} {
        return [dict create action "none" severity "info"]
    }

    set containers_to_down {}

    foreach stat [dict values $stats] {
        set id [dict get $stat id]
        set name [dict get $stat name]
        set cpu_usage [dict get $stat cpu_usage]
        set memory_usage [dict get $stat memory_usage]
        set n [dict get $stat count]

        if {$n < $count} {
            log_message "INFO" "Ainda não há informações suficientes para analisar o container $name"
            continue
        }

        set avg_cpu [expr { $cpu_usage / $n }]
        set avg_memory [expr { $memory_usage / $n }]

        if { $avg_cpu >= $CONFIG(cpu_threshold_critical) } {
            lappend containers_to_down [dict create \
                                            name $name \
                                            id $id \
                                            reason "$name - CPU crítico: ${avg_cpu}%"]
        }

        if { $avg_memory >= $CONFIG(memory_threshold_critical) } {
            lappend containers_to_down [dict create \
                                            name $name \
                                            id $id \
                                            reason "$name - Memória crítica: ${avg_memory}%"]
        }

        log_message "INFO" "Média $name - CPU: ${avg_cpu}% | Memory: ${avg_memory}%"
    }
    
    set avg_cpu [expr {$cpu_sum / $count}]
    set avg_memory [expr {$memory_sum / $count}]
    set avg_disk [expr {$disk_sum / $count}]
    
    log_message "INFO" "Médias 5min - CPU: ${avg_cpu}% | Memory: ${avg_memory}% | Disk: ${avg_disk}%"

    
    # Determinar ação necessária
    set action "none"
    set severity "info"
    set reason ""

    
    # Verificar condições críticas
    if {$avg_memory >= $CONFIG(memory_threshold_critical)} {
        set action "restart_docker"
        set severity "critical"
        set reason "Memória crítica: ${avg_memory}%"
    } elseif {$avg_cpu >= $CONFIG(cpu_threshold_critical)} {
        set action "scale_down_services"
        set severity "critical"
        set reason "CPU crítico: ${avg_cpu}%"
    } elseif {$avg_disk >= $CONFIG(disk_threshold_critical)} {
        set action "cleanup_docker"
        set severity "critical"
        set reason "Disco crítico: ${avg_disk}%"
    } elseif {$avg_memory >= $CONFIG(memory_threshold_warning)} {
        set action "scale_down_services"
        set severity "warning"
        set reason "Memória alta: ${avg_memory}%"
    } elseif {$avg_cpu >= $CONFIG(cpu_threshold_warning)} {
        set action "scale_down_services"
        set severity "warning"
        set reason "CPU alto: ${avg_cpu}%"
    } elseif {$avg_disk >= $CONFIG(disk_threshold_warning)} {
        set action "cleanup_docker"
        set severity "warning"
        set reason "Disco alto: ${avg_disk}%"
    }
    
    return [dict create \
        action $action \
        severity $severity \
        reason $reason \
        avg_cpu $avg_cpu \
        avg_memory $avg_memory \
        avg_disk $avg_disk \
        containers_to_down $containers_to_down]
}

# ==============================================================================
# Funções de Ação Corretiva
# ==============================================================================

proc execute_action {analysis} {
    set action [dict get $analysis action]
    set severity [dict get $analysis severity]
    set reason [dict get $analysis reason]
    set containers_to_down [dict get $analysis containers_to_down]
    set action_executed false

    if {[llength $containers_to_down] > 0} {
        foreach container $containers_to_down {
            set creason [dict get $container reason]
            set cname [dict get $container name]
            set cid [dict get $container id]
            log_message "ACTION" "Container removido - $reason"
            send_telegram_notification "critical" "stop_container" $creason
            set action_executed true
        }
    }
    
    switch $action {
        "scale_down_services" {
            #scale_down_services
            log_message "ACTION" "Serviços redimensionados - $reason"
            set action_executed true
        }
        "restart_docker" {
            #restart_docker_service
            log_message "ACTION" "Docker reiniciado - $reason"
            set action_executed true
        }
        "cleanup_docker" {
            #cleanup_docker_resources
            log_message "ACTION" "Limpeza do Docker executada - $reason"
            set action_executed true
        }
        "none" {
            return false
        }
    }
    
    # Notificar via Telegram
    send_telegram_notification $severity $action $reason

    return $action_executed
}

proc scale_down_services {} {
    log_message "INFO" "Iniciando redimensionamento de serviços..."
    
    # Listar serviços com múltiplas réplicas
    if {![catch {exec docker service ls --format "{{.Name}} {{.Replicas}}"} services_output]} {
        foreach line [split $services_output "\n"] {
            if {[regexp {^(\S+)\s+(\d+)/\d+} $line -> service_name current_replicas]} {
                if {$current_replicas > 1} {
                    set new_replicas [expr {$current_replicas - 1}]
                    log_message "INFO" "Reduzindo $service_name de $current_replicas para $new_replicas réplicas"
                    catch {exec docker service scale ${service_name}=${new_replicas}}
                }
            }
        }
    }
}

# Função para parar um container
proc stop_container {container_id container_name cpu_usage} {
    log_message "AÇÃO: Parando container $container_name ($container_id) - CPU: ${cpu_usage}%"
    
    if {[catch {exec docker stop $container_id} result]} {
        log_message "ERRO: Falha ao parar container $container_name: $result"
        return 0
    } else {
        log_message "SUCESSO: Container $container_name parado com sucesso"
        return 1
    }
}

proc restart_docker_service {} {
    log_message "CRITICAL" "Reiniciando serviço Docker..."
    catch {exec systemctl restart docker}
    after 10000  ;# Aguarda 10 segundos
    
    # Verificar se o Docker está rodando
    if {[catch {exec docker info}]} {
        log_message "ERROR" "Falha ao reiniciar Docker, tentando novamente..."
        catch {exec systemctl start docker}
    }
}

proc cleanup_docker_resources {} {
    log_message "INFO" "Iniciando limpeza de recursos Docker..."
    
    # Remover containers parados
    catch {exec docker container prune -f}
    
    # Remover imagens não utilizadas
    catch {exec docker image prune -f}
    
    # Remover volumes não utilizados
    catch {exec docker volume prune -f}
    
    # Remover redes não utilizadas
    catch {exec docker network prune -f}
    
    log_message "INFO" "Limpeza concluída"
}

# ==============================================================================
# Funções de Notificação
# ==============================================================================

proc send_telegram_notification {severity action reason} {
    global CONFIG last_notification
    
    set current_time [clock seconds]
    set notification_key "${severity}_${action}"
    
    # Evitar spam - não enviar a mesma notificação em menos de 5 minutos
    if {[dict exists $last_notification $notification_key]} {
        set last_time [dict get $last_notification $notification_key]
        if {($current_time - $last_time) < 300} {
            return
        }
    }
    
    set hostname [exec hostname]
    set timestamp [clock format $current_time -format "%Y/%m/%d %H:%M:%S"]
    
    # Emojis baseados na severidade
    switch $severity {
        "critical" { set emoji "🚨" }
        "warning" { set emoji "⚠️" }
        "info" { set emoji "ℹ️" }
        default { set emoji "📊" }
    }
    
    # telegram markdown cannot have - or _
    set message "${emoji} *Docker Swarm Monitor*\n\n"
    append message "*Host:* $hostname\n"
    append message "*Timestamp:* $timestamp\n"
    append message "*Severidade:* [string toupper $severity]\n"
    append message "*Acao:* [regsub -all {_} $action { }]\n"
    append message "*Motivo:* $reason"

    puts $message
    

    # Enviar para Telegram
    set url "https://api.telegram.org/bot$CONFIG(telegram_bot_token)/sendMessage"
    set data [http::formatQuery chat_id $CONFIG(telegram_chat_id) parse_mode MarkdownV2 text $message]
    

    try {
        set token [http::geturl $url -query $data -timeout 10000]
        dict set last_notification $notification_key $current_time
        log_message "INFO" "Notificação Telegram enviada \[[::http::status $token]\]: $action"
        http::cleanup $token
    } on error err {
        log_message "ERROR" "Falha ao enviar notificação Telegram: $err"
    }

}

# ==============================================================================
# Servidor HTTP para Métricas (Grafana)
# ==============================================================================

proc start_http_server {} {
    global CONFIG http_server_socket
    
    set http_server_socket [socket -server http_request_accept $CONFIG(http_port)]
    log_message "INFO" "Servidor HTTP iniciado na porta $CONFIG(http_port)"
}

proc http_request_accept {sock host port} {
    chan configure $sock -blocking 0 -buffering line    
    chan event $sock readable [list handle_http_request $sock]
}

proc handle_http_request {sock} {
    #fconfigure $sock -buffering line

    set request [gets $sock]
    
    # Ler headers (ignora o conteúdo por simplicidade)
    while {[gets $sock line] > 0} {}

    
    if {[regexp {^GET (/\w+)} $request -> path]} {
        log_message "INFO" "Web app: GET $path"
        switch $path {
            "/metrics" {
                send_prometheus_metrics $sock
            }
            "/health" {
                send_health_check $sock
            }
            default {
                send_http_response $sock "404 Not Found" "Endpoint não encontrado"
            }
        }
    } else {
        send_http_response $sock "400 Bad Request" "Requisição inválida"
    }
    
    catch { close $sock }
}

proc send_prometheus_metrics {sock} {
    global CONFIG
    
    # Obter métricas atuais
    set current_metrics [get_system_metrics]
    set hostname [dict get $current_metrics hostname]
    
    set response "HTTP/1.1 200 OK\n"
    append response "Content-Type: text/plain\n"
    append response "Connection: close\n\n"
    
    # Métricas no formato Prometheus
    append response "# HELP swarm_cpu_usage_percent CPU usage percentage\n"
    append response "# TYPE swarm_cpu_usage_percent gauge\n"
    append response "swarm_cpu_usage_percent{hostname=\"$hostname\"} [dict get $current_metrics cpu_usage]\n\n"
    
    append response "# HELP swarm_memory_usage_percent Memory usage percentage\n"
    append response "# TYPE swarm_memory_usage_percent gauge\n"
    append response "swarm_memory_usage_percent{hostname=\"$hostname\"} [dict get $current_metrics memory_usage]\n\n"
    
    append response "# HELP swarm_disk_usage_percent Disk usage percentage\n"
    append response "# TYPE swarm_disk_usage_percent gauge\n"
    append response "swarm_disk_usage_percent{hostname=\"$hostname\"} [dict get $current_metrics disk_usage]\n\n"
    
    append response "# HELP swarm_load_average System load average\n"
    append response "# TYPE swarm_load_average gauge\n"
    append response "swarm_load_average{hostname=\"$hostname\"} [dict get $current_metrics load_avg]\n\n"
    
    append response "# HELP swarm_containers_total Total number of containers\n"
    append response "# TYPE swarm_containers_total gauge\n"
    append response "swarm_containers_total{hostname=\"$hostname\"} [dict get $current_metrics docker_containers]\n\n"
    
    append response "# HELP swarm_services_total Total number of services\n"
    append response "# TYPE swarm_services_total gauge\n"
    append response "swarm_services_total{hostname=\"$hostname\"} [dict get $current_metrics docker_services]\n\n"
    
    puts -nonewline $sock $response
}

proc send_health_check {sock} {
    set response "HTTP/1.1 200 OK\n"
    append response "Content-Type: application/json\n"
    append response "Connection: close\n\n"
    append response "{\"status\":\"healthy\",\"timestamp\":[clock seconds]}\n"
    
    puts -nonewline $sock $response
}

proc send_http_response {sock status message} {
    set response "HTTP/1.1 $status\n"
    append response "Content-Type: text/plain\n"
    append response "Connection: close\n\n"
    append response "$message\n"
    
    puts -nonewline $sock $response
}

# ==============================================================================
# Funções de Armazenamento
# ==============================================================================

proc store_metrics {metrics action_taken} {
    set timestamp [dict get $metrics timestamp]
    set hostname [dict get $metrics hostname]
    set cpu_usage [dict get $metrics cpu_usage]
    set memory_usage [dict get $metrics memory_usage]
    set memory_total [dict get $metrics memory_total]
    set memory_available [dict get $metrics memory_available]
    set disk_usage [dict get $metrics disk_usage]
    set load_avg [dict get $metrics load_avg]
    set docker_containers [dict get $metrics docker_containers]
    set docker_services [dict get $metrics docker_services]
    
    db eval {
        INSERT INTO metrics (
            timestamp, hostname, cpu_usage, memory_usage, memory_total,
            memory_available, disk_usage, load_avg, docker_containers,
            docker_services, action_taken
        ) VALUES (
            $timestamp, $hostname, $cpu_usage, $memory_usage, $memory_total,
            $memory_available, $disk_usage, $load_avg, $docker_containers,
            $docker_services, $action_taken
        )
    }
    
    # Limpar dados antigos (manter apenas 7 dias)
    set week_ago [expr {[clock seconds] - 604800}]
    db eval {DELETE FROM metrics WHERE timestamp < $week_ago}
}

# ==============================================================================
# Loop Principal
# ==============================================================================

proc main_loop {} {

    global CONFIG metrics_history
    set start_time [clock seconds]
    
    # Coletar métricas
    set current_metrics [get_system_metrics]
    
    # Adicionar à história
    lappend metrics_history $current_metrics
    
    # Manter apenas os últimos 5 minutos de dados
    set window_start [expr {$start_time - $CONFIG(analysis_window)}]
    set filtered_history {}
    foreach metrics $metrics_history {
        if {[dict get $metrics timestamp] >= $window_start} {
            lappend filtered_history $metrics
        }
    }
    set metrics_history $filtered_history

    set metrics_count [llength $filtered_history]
    set min_metrics_to_analyze [expr { $CONFIG(analysis_window) / $CONFIG(collect_interval) }]

    if { $metrics_count < $min_metrics_to_analyze } {
        log_message "INFO" "Metricas insuficiêntes para analise. Coletas: ${metrics_count}X Necessário: ${min_metrics_to_analyze}X"
        schedule_next $start_time
        return
    }
    
    # Analisar métricas se temos dados suficientes
    set analysis [analyze_metrics $metrics_history]
    set action_taken [dict get $analysis action]
    
    # Executar ação se necessário
    if {$action_taken ne "none"} {
        if {[execute_action $analysis]} {
            # reset metrics if execute action
            set metrics_history {}   
        }
    }
    
    # Armazenar métricas
    #store_metrics $current_metrics $action_taken
    
    schedule_next $start_time
}

proc schedule_next {start_time} {
    global CONFIG
    # Calcular tempo de espera
    set elapsed [expr {[clock seconds] - $start_time}]
    set sleep_time [expr {$CONFIG(collect_interval) - $elapsed}]
    after [expr {$sleep_time * 1000}] main_loop

}

# ==============================================================================
# Tratamento de Sinais e Cleanup
# ==============================================================================

proc cleanup_and_exit {} {
    global http_server_socket
    
    log_message "INFO" "Finalizando monitor..."
    
    if {$http_server_socket ne ""} {
        catch {close $http_server_socket}
    }
    
    #catch {db close}
    exit 0
}

# Capturar sinais de interrupção
signal trap {SIGINT SIGTERM} cleanup_and_exit

# ==============================================================================
# Inicialização
# ==============================================================================

proc main {} {
    log_message "INFO" "Iniciando Docker Swarm Monitor"
    
    # Verificar se está rodando como root
    if {[exec id -u] != 0} {
        log_message "ERROR" "Este script deve ser executado como root"
        exit 1
    }
    
    # Inicializar componentes
    #init_database
    start_http_server
    
    # Enviar notificação de inicialização
    send_telegram_notification "info" "monitor_started" "Monitor iniciado com sucesso"
    
    # Iniciar loop principal
    log_message "INFO" "Iniciando loop principal de monitoramento"
    main_loop
}

# Executar se chamado diretamente
if {[info exists argv0] && $argv0 eq [info script]} {
    main
    vwait forever
}