Выявленные проблемы
 1. Критическая проблема: Недоступность удаленного Docker хоста
Симптомы:
- Тесты зависают в статусе "Initializing"
- В логах test_runner ошибка: Failed to connect to /192.168.14.201:2375
Причина:
- Сервис test_runner настроен на использование удаленной нагрузочной станции (192.168.14.201) для запуска тестовых Docker-контейнеров
- Docker daemon на нагрузочной станции не был настроен для прослушивания TCP-порта 2375
- Docker работал только через unix socket, test_runner не мог создать контейнеры для тестов
Решение: На сервере 192.168.14.201 (нагрузочная станция) настроен Docker daemon для TCP API

2. Проблема производительности: Исчерпание пула соединений к PostgreSQL
Симптомы: 
- project_srv потребляет 200% CPU 
- Ошибки в логах: HikariPool-1 - Connection is not available, request timed out after 30-40 секунд
- PostgreSQL нагружен до 135% CPU 
- 81-83 активных подключения к БД
Причина: 
- При нагрузке происходят массовые запросы списков проектов через API getTestProjects()
- Каждый запрос возвращает 999 проектов в памяти 
- Пул соединений HikariCP (дефолтный размер ~10) быстро исчерпывается 
- project_srv не может получить новые соединения из-за этого запросы тормозят, соответсвенно CPU растет из-за retry логики
Решение:
Оптимизация PostgreSQL – изменение конфигурационного файла
max_connections = 200           # было 100
shared_buffers = 1GB           # было 128MB
work_mem = 16MB                # было 4MB
maintenance_work_mem = 256MB   # для vacuum/analyze

3. Проблема памяти: OutOfMemoryError в project_srv
Симптомы:
- java.lang.OutOfMemoryError: GC overhead limit exceeded
- Сборщик мусора тратит >98% времени, освобождая <2% памяти
Причина:
- При высокой нагрузке множество параллельных запросов загружают по 999 проектов каждый
- Объекты накапливаются в heap быстрее, чем GC успевает их очищать
- Heap memory: MaxHeapSize = 4GB (достаточно), но утечка памяти из-за неэффективного использования
Решение: Добавлена оптимизация GC через переменную JAVA_OPTS.
environment: - SPRING_PROFILES_ACTIVE=docker - SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE=30 - SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE=10 - SPRING_DATASOURCE_HIKARI_CONNECTION_TIMEOUT=30000 - SPRING_DATASOURCE_HIKARI_IDLE_TIMEOUT=600000 - SPRING_DATASOURCE_HIKARI_MAX_LIFETIME=1800000 - JAVA_OPTS=-Xms512m -Xmx2g -XX:+UseG1GC
Результат: Частичное улучшение, но требуется оптимизация кода.


4. Мониторинг и алерты

Настроить алерты в Grafana на:

- CPU project_srv > 150%
- PostgreSQL connections > 80
- HikariPool connection timeout
- OutOfMemoryError