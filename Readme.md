
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




