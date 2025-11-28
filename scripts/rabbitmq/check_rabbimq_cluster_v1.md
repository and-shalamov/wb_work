Использование: 
./check_rabbitmq_cluster.sh <pod_name> <namespace> [port] [password]

Основные команды rabbitmqctl:
bash
# Статус ноды
rabbitmqctl status

# Состояние кластера
rabbitmqctl cluster_status

# Списки объектов
rabbitmqctl list_queues name messages messages_ready messages_unacknowledged consumers
rabbitmqctl list_exchanges name type
rabbitmqctl list_connections state channels
rabbitmqctl list_channels connection consumer_count
rabbitmqctl list_vhosts
rabbitmqctl list_users
rabbitmqctl list_policies

# Мониторинг
rabbitmqctl list_consumers
rabbitmqctl node_health_check
HTTP API команды (management plugin):
bash
# Обзор кластера
curl -s -u guest:guest http://localhost:15672/api/overview

# Информация о нодах
curl -s -u guest:guest http://localhost:15672/api/nodes

# Детальная информация об очередях
curl -s -u guest:guest http://localhost:15672/api/queues

# Информация о подключениях
curl -s -u guest:guest http://localhost:15672/api/connections
Критические метрики для мониторинга:
Memory usage - использование памяти

Disk space - свободное место на диске

File descriptors - использование файловых дескрипторов

Queue lengths - количество сообщений в очередях

Consumer count - количество активных потребителей

Connection count - количество активных подключений

Message rates - скорость обработки сообщений